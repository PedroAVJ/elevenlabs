#import "HostApplicationCapture.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <os/lock.h>

// PROTECTED COMPATIBILITY PATH — DO NOT REPLACE OR MOVE OUT OF +load.
// iOS 26.4 moved keyboard-host identity into this arbiter callback. Installing
// from +load is intentional: the initial focus event can precede Swift view
// controller initialization. The technique is adapted from the MIT-licensed
// KeyboardHostBundleID project and forms the capture half of the switchback
// recovered from Wispr Flow 1.67/build 1313. Any change requires the physical
// device matrix in docs/ios-keyboard-roundtrip-spec.md.

static NSString *const ELArbiterClientClassName = @"_UIKeyboardArbiterClient";
static NSString *const ELDestinationClassName =
    @"_UIKeyboardArbiterClientInputDestination";
static NSString *const ELEnabledSelectorName = @"enabled";
static NSString *const ELSharedClientSelectorName =
    @"automaticSharedArbiterClient";
static NSString *const ELRefreshSelectorName = @"checkConnection";
static NSString *const ELChangedSelectorName =
    @"queue_keyboardChanged:onComplete:";
static NSString *const ELSourceBundleIdentifierKey =
    @"_sourceBundleIdentifier";

static os_unfair_lock ELHostCaptureLock = OS_UNFAIR_LOCK_INIT;
static NSString *_Nullable ELHostCaptureBundleIdentifier;
static uint64_t ELHostCaptureGeneration;
static NSString *ELHostCaptureInstallStatus = @"not-installed";
static IMP _Nullable ELOriginalKeyboardChangedImplementation;

static BOOL ELIsObjectType(const char *_Nullable type) {
    if (type == NULL) return NO;
    while (*type == 'r' || *type == 'n' || *type == 'N' || *type == 'o' ||
           *type == 'O' || *type == 'R' || *type == 'V') {
        type += 1;
    }
    return *type == '@';
}

static BOOL ELIsAcceptableHostBundleIdentifier(NSString *_Nullable value) {
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *bundleIdentifier = [value
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL hasBundleShape = [bundleIdentifier containsString:@"."] ||
        [bundleIdentifier.lowercaseString isEqualToString:@"pinterest"];
    NSString *ownBundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
    NSString *containingBundleIdentifier = ownBundleIdentifier;
    if ([ownBundleIdentifier hasSuffix:@".Keyboard"]) {
        containingBundleIdentifier = [ownBundleIdentifier
            substringToIndex:ownBundleIdentifier.length - @".Keyboard".length];
    }
    if (bundleIdentifier.length == 0 ||
        !hasBundleShape ||
        [bundleIdentifier isEqualToString:@"<null>"] ||
        [bundleIdentifier isEqualToString:@"(null)"] ||
        [bundleIdentifier isEqualToString:ownBundleIdentifier] ||
        [bundleIdentifier isEqualToString:containingBundleIdentifier]) {
        return NO;
    }

    NSString *lowercased = bundleIdentifier.lowercaseString;
    if ([lowercased isEqualToString:@"com.apple.springboard"] ||
        [lowercased isEqualToString:@"com.apple.spotlight"] ||
        [lowercased isEqualToString:@"com.apple.uikitsystemapp"] ||
        [lowercased hasSuffix:@"viewservice"] ||
        [lowercased hasPrefix:@"com.apple.inputmethod."]) {
        return NO;
    }
    return YES;
}

static void ELSetInstallStatus(NSString *status) {
    os_unfair_lock_lock(&ELHostCaptureLock);
    ELHostCaptureInstallStatus = [status copy];
    os_unfair_lock_unlock(&ELHostCaptureLock);
}

static void ELCommitHostBundleIdentifier(NSString *_Nullable value) {
    if (!ELIsAcceptableHostBundleIdentifier(value)) return;
    os_unfair_lock_lock(&ELHostCaptureLock);
    ELHostCaptureBundleIdentifier = [value copy];
    ELHostCaptureGeneration += 1;
    os_unfair_lock_unlock(&ELHostCaptureLock);
}

static void ELSwizzledKeyboardChanged(
    id self,
    SEL selector,
    id _Nullable change,
    id _Nullable completion
) {
    if (change != nil) {
        @try {
            id value = [change valueForKey:ELSourceBundleIdentifierKey];
            if ([value isKindOfClass:NSString.class]) {
                ELCommitHostBundleIdentifier((NSString *)value);
            }
        } @catch (__unused NSException *exception) {
            // The callback must always reach UIKit's original implementation.
        }
    }

    if (ELOriginalKeyboardChangedImplementation != NULL) {
        ((void (*)(id, SEL, id, id))ELOriginalKeyboardChangedImplementation)(
            self,
            selector,
            change,
            completion
        );
    }
}

static BOOL ELAlwaysEnableKeyboardArbiter(
    __unused id self,
    __unused SEL selector
) {
    return YES;
}

static void ELInstallHostCapture(void) {
    Class clientClass = NSClassFromString(ELArbiterClientClassName);
    if (clientClass == Nil) {
        ELSetInstallStatus(@"client-class-missing");
        return;
    }

    SEL enabledSelector = NSSelectorFromString(ELEnabledSelectorName);
    Method enabledMethod = class_getClassMethod(clientClass, enabledSelector);
    if (enabledMethod != NULL) {
        method_setImplementation(
            enabledMethod,
            (IMP)&ELAlwaysEnableKeyboardArbiter
        );
    }

    Class destinationClass = NSClassFromString(ELDestinationClassName);
    if (destinationClass == Nil) {
        ELSetInstallStatus(@"destination-class-missing");
        return;
    }

    SEL changedSelector = NSSelectorFromString(ELChangedSelectorName);
    Method changedMethod = class_getInstanceMethod(
        destinationClass,
        changedSelector
    );
    if (changedMethod == NULL || method_getNumberOfArguments(changedMethod) != 4) {
        ELSetInstallStatus(@"change-callback-missing");
        return;
    }

    char *returnType = method_copyReturnType(changedMethod);
    char *changeType = method_copyArgumentType(changedMethod, 2);
    char *completionType = method_copyArgumentType(changedMethod, 3);
    BOOL signatureMatches = returnType != NULL && returnType[0] == 'v' &&
        ELIsObjectType(changeType) && ELIsObjectType(completionType);
    free(returnType);
    free(changeType);
    free(completionType);
    if (!signatureMatches) {
        ELSetInstallStatus(@"change-callback-signature-rejected");
        return;
    }

    ELOriginalKeyboardChangedImplementation =
        method_getImplementation(changedMethod);
    method_setImplementation(
        changedMethod,
        (IMP)&ELSwizzledKeyboardChanged
    );
    ELSetInstallStatus(@"installed");
}

@interface ELHostApplicationCaptureInstaller : NSObject
@end

@implementation ELHostApplicationCaptureInstaller

+ (void)load {
    if (@available(iOS 26.4, *)) {
        ELInstallHostCapture();
    } else {
        ELSetInstallStatus(@"legacy-ios");
    }
}

@end

NSString *_Nullable ELHostApplicationCaptureLastBundleIdentifier(void) {
    return ELHostApplicationCaptureCopySnapshot(NULL);
}

NSString *_Nullable ELHostApplicationCaptureCopySnapshot(
    uint64_t *_Nullable generation
) {
    os_unfair_lock_lock(&ELHostCaptureLock);
    NSString *bundleIdentifier = [ELHostCaptureBundleIdentifier copy];
    if (generation != NULL) {
        *generation = ELHostCaptureGeneration;
    }
    os_unfair_lock_unlock(&ELHostCaptureLock);
    return ELIsAcceptableHostBundleIdentifier(bundleIdentifier)
        ? bundleIdentifier
        : nil;
}

uint64_t ELHostApplicationCaptureGeneration(void) {
    os_unfair_lock_lock(&ELHostCaptureLock);
    uint64_t generation = ELHostCaptureGeneration;
    os_unfair_lock_unlock(&ELHostCaptureLock);
    return generation;
}

BOOL ELHostApplicationCaptureRefresh(void) {
    if (@available(iOS 26.4, *)) {
        Class clientClass = NSClassFromString(ELArbiterClientClassName);
        SEL sharedClientSelector =
            NSSelectorFromString(ELSharedClientSelectorName);
        if (clientClass == Nil ||
            ![(id)clientClass respondsToSelector:sharedClientSelector]) {
            return NO;
        }

        id (*getClient)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        id client = getClient((id)clientClass, sharedClientSelector);
        SEL refreshSelector = NSSelectorFromString(ELRefreshSelectorName);
        if (client != nil && [client respondsToSelector:refreshSelector]) {
            void (*refresh)(id, SEL) = (void (*)(id, SEL))objc_msgSend;
            refresh(client, refreshSelector);
            return YES;
        }
    }
    return NO;
}

uint64_t ELHostApplicationCaptureInvalidate(void) {
    os_unfair_lock_lock(&ELHostCaptureLock);
    ELHostCaptureBundleIdentifier = nil;
    ELHostCaptureGeneration += 1;
    uint64_t generation = ELHostCaptureGeneration;
    os_unfair_lock_unlock(&ELHostCaptureLock);
    return generation;
}

NSString *ELHostApplicationCaptureStatus(void) {
    os_unfair_lock_lock(&ELHostCaptureLock);
    NSString *status = [ELHostCaptureInstallStatus copy];
    os_unfair_lock_unlock(&ELHostCaptureLock);
    return status;
}
