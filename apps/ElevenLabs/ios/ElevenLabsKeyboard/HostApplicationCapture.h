#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The host application most recently reported by UIKit's keyboard arbiter.
FOUNDATION_EXPORT NSString * _Nullable
ELHostApplicationCaptureLastBundleIdentifier(void);

/// Atomically copy the latest host and its generation under the same lock.
FOUNDATION_EXPORT NSString * _Nullable
ELHostApplicationCaptureCopySnapshot(uint64_t * _Nullable generation);

/// Monotonically increases whenever UIKit publishes an acceptable host.
FOUNDATION_EXPORT uint64_t ELHostApplicationCaptureGeneration(void);

/// Ask UIKit's keyboard arbiter to publish its current destination again.
/// Returns whether the lazy client existed and `checkConnection` was invoked.
FOUNDATION_EXPORT BOOL ELHostApplicationCaptureRefresh(void);

/// Drop the process-local value when this keyboard leaves its current host.
/// A durable bundle+PID record remains available through the App Group.
/// Returns the invalidation generation from the same locked operation.
FOUNDATION_EXPORT uint64_t ELHostApplicationCaptureInvalidate(void);

/// A non-sensitive diagnostic describing whether the early hook installed.
FOUNDATION_EXPORT NSString *ELHostApplicationCaptureStatus(void);

NS_ASSUME_NONNULL_END
