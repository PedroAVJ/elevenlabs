import ObjectiveC.runtime
import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private let hostResolver = HostApplicationResolver()
    private var hostingController: UIHostingController<KeyboardView>?
    private var hostPrewarmTask: Task<Void, Never>?
    private var visibleHostLeaseTask: Task<Void, Never>?
    private var documentChangeRevision: UInt64 = 0

    private lazy var model = KeyboardModel(
        resolveHostApplication: { [weak self] in
            guard let self else {
                return HostApplicationResolution(
                    bundleIdentifier: nil,
                    processIdentifier: nil,
                    attempts: ["controller-deallocated"]
                )
            }
            return self.hostResolver.resolve(for: self)
        },
        openContainingApp: { [weak self] url in
            guard let self else { return .failed(attempts: ["controller-deallocated"]) }
            return await self.open(url: url)
        },
        currentInsertionContextFingerprint: { [weak self] in
            self?.insertionContextFingerprint() ?? "controller-deallocated"
        },
        insertTranscript: { [weak self] transcript in
            guard let self else {
                return KeyboardInsertionResult(
                    confirmed: false,
                    documentIdentifierBefore: "controller-deallocated",
                    documentIdentifierAfter: "controller-deallocated",
                    contextBeforeMutation: nil,
                    contextAfterMutation: nil,
                    documentChangeObserved: false
                )
            }
            return await self.insert(transcript: transcript)
        },
        advanceToNextKeyboard: { [weak self] in
            self?.advanceToNextInputMode()
        }
    )

    override func viewDidLoad() {
        super.viewDidLoad()

        let keyboardView = KeyboardView(model: model)
        let hostingController = UIHostingController(rootView: keyboardView)
        hostingController.view.backgroundColor = .clear
        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        hostingController.didMove(toParent: self)
        self.hostingController = hostingController

        let height = view.heightAnchor.constraint(equalToConstant: 272)
        height.priority = .init(999)
        height.isActive = true
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.setInsertionSurfaceReady(false)
        applyKeyboardAppearance()
        model.hasFullAccess = hasFullAccess
        // Establish the appearance boundary before UIKit finishes presenting
        // the keyboard. The process-load arbiter callback can already be
        // available here on a cold extension launch; consuming it now avoids
        // the window where a Live Activity tap starts without a return target.
        hostResolver.beginAppearance(for: self)
        let immediateResolution = hostResolver.resolve(for: self)
        let prepared = immediateResolution.bundleIdentifier != nil
            && hostResolver.refreshVisibleHostLease(for: self)
        model.setHostPreparationInProgress(!prepared)
        model.startPolling()
        if prepared {
            startVisibleHostLease()
        } else {
            startHostPreparation()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // The preparation task begins in viewWillAppear so a very fast Dynamic
        // Island tap cannot beat the first arbiter refresh. It keeps retrying
        // through this visible boundary when UIKit initializes the client
        // lazily, without blocking presentation.
        if hostPrewarmTask == nil, visibleHostLeaseTask == nil {
            startHostPreparation()
        }
        // The extension can be recreated with a completed transcript before its
        // document proxy is attached to the host field. Cross one run-loop turn
        // beyond `viewDidAppear` before allowing the first insertion attempt.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.viewIfLoaded?.window != nil else { return }
            self.model.setInsertionSurfaceReady(true)
        }
    }

    private func startHostPreparation() {
        hostPrewarmTask?.cancel()
        model.setHostPreparationInProgress(true)
        hostPrewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let preparedCurrentAppearance = await self.hostResolver
                .prepareVisibleHostLease(
                for: self
            )
            guard !Task.isCancelled else { return }
            self.model.setHostPreparationInProgress(
                !preparedCurrentAppearance
            )
            self.startVisibleHostLease()
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        documentChangeRevision &+= 1
        applyKeyboardAppearance()
        model.hasFullAccess = hasFullAccess
        _ = hostResolver.refreshVisibleHostLease(for: self)
        if viewIfLoaded?.window != nil {
            model.setInsertionSurfaceReady(true)
        }
    }

    /// Most hosts leave this `.default`, and the system appearance already
    /// reaches the trait collection. A host that asks for a specific keyboard
    /// appearance overrides that, so honor it too.
    private func applyKeyboardAppearance() {
        switch textDocumentProxy.keyboardAppearance {
        case .dark:
            overrideUserInterfaceStyle = .dark
        case .light:
            overrideUserInterfaceStyle = .light
        default:
            overrideUserInterfaceStyle = .unspecified
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        model.setInsertionSurfaceReady(false)

        // A Dynamic Island tap begins dismissing the host keyboard before the
        // containing app receives its URL. Capture one final exact host lease
        // at that transition boundary, and let an in-flight arbiter prewarm
        // finish until the keyboard is actually gone. Cleaning up here used to
        // cancel a cold first-host capture at the precise moment it was needed.
        _ = hostResolver.resolve(for: self)
        _ = hostResolver.refreshVisibleHostLease(for: self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        hostPrewarmTask?.cancel()
        hostPrewarmTask = nil
        visibleHostLeaseTask?.cancel()
        visibleHostLeaseTask = nil
        model.setHostPreparationInProgress(false)
        model.stopPolling()
        // Never let one host's process-local bundle leak into the next app.
        // The exact bundle+PID record remains available in the App Group.
        hostResolver.endAppearance()
        super.viewDidDisappear(animated)
    }

    private func startVisibleHostLease() {
        visibleHostLeaseTask?.cancel()
        visibleHostLeaseTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let prepared = await self.hostResolver
                    .prepareVisibleHostLease(for: self)
                guard !Task.isCancelled else { return }
                self.model.setHostPreparationInProgress(!prepared)
                do {
                    try await Task.sleep(
                        for: prepared ? .seconds(1) : .milliseconds(250)
                    )
                } catch {
                    return
                }
            }
        }
    }

    @MainActor
    private func open(url: URL) async -> KeyboardAppLaunchOutcome {
        var attempts: [String] = []

        // A keyboard's responder chain belongs to the host presentation. On
        // current iOS versions the URL-capable responder is normally UIScene,
        // not UIApplication. These APIs take different option types, so they
        // must be invoked as their real classes instead of through one dynamic
        // Objective-C signature.
        if let result = await openUsingResponderChain(url) {
            attempts.append("responder-\(result.route):\(result.didOpen)")
            if result.didOpen {
                return .opened(route: result.route, attempts: attempts)
            }
        }

        // Apple doesn't consistently honor NSExtensionContext.open for custom
        // keyboards, but keep the supported extension API as a fallback.
        if let extensionContext {
            let didOpen = await withCheckedContinuation { continuation in
                extensionContext.open(url) { success in
                    continuation.resume(returning: success)
                }
            }
            attempts.append("extension-context:\(didOpen)")
            if didOpen {
                return .opened(route: "extension-context", attempts: attempts)
            }
        }

        // This personal sideload can still fall back to opening its bundle.
        // App activation consumes the pending shared launch request even when
        // the custom deep link itself isn't delivered.
        let didOpenBundle = openContainingBundle()
        attempts.append("workspace-bundle:\(didOpenBundle)")
        if didOpenBundle {
            return .opened(route: "workspace-bundle", attempts: attempts)
        }

        return .failed(attempts: attempts)
    }

    private func openUsingResponderChain(
        _ url: URL
    ) async -> (didOpen: Bool, route: String)? {
        var responder: UIResponder? = self
        while let current = responder {
            if let scene = current as? UIScene {
                let didOpen = await scene.open(url, options: nil)
                return (didOpen, "scene")
            }
            if let application = current as? UIApplication {
                let didOpen = await application.open(url, options: [:])
                return (didOpen, "application")
            }
            responder = current.next
        }
        return nil
    }

    private func openContainingBundle() -> Bool {
        guard
            let extensionBundleIdentifier = Bundle.main.bundleIdentifier,
            extensionBundleIdentifier.hasSuffix(".Keyboard")
        else {
            return false
        }
        let containingBundleIdentifier = String(
            extensionBundleIdentifier.dropLast(".Keyboard".count)
        )

        guard let workspaceClass = NSClassFromString("LSApplicationWorkspace") else {
            return false
        }
        let defaultSelector = NSSelectorFromString("defaultWorkspace")
        guard
            let defaultMethod = class_getClassMethod(
                workspaceClass,
                defaultSelector
            ),
            let defaultEncoding = method_getTypeEncoding(defaultMethod),
            String(cString: defaultEncoding) == "@16@0:8"
        else {
            return false
        }
        typealias DefaultWorkspaceFunction = @convention(c) (
            AnyClass,
            Selector
        ) -> Unmanaged<AnyObject>?
        let defaultWorkspace = unsafeBitCast(
            method_getImplementation(defaultMethod),
            to: DefaultWorkspaceFunction.self
        )
        guard
            let workspace = defaultWorkspace(
                workspaceClass,
                defaultSelector
            )?.takeUnretainedValue()
        else {
            return false
        }

        let openSelector = NSSelectorFromString("openApplicationWithBundleID:")
        guard
            let openMethod = class_getInstanceMethod(workspaceClass, openSelector),
            let openEncoding = method_getTypeEncoding(openMethod),
            String(cString: openEncoding) == "B24@0:8@16"
        else {
            return false
        }
        typealias OpenApplicationFunction = @convention(c) (
            AnyObject,
            Selector,
            NSString
        ) -> Bool
        let openApplication = unsafeBitCast(
            method_getImplementation(openMethod),
            to: OpenApplicationFunction.self
        )
        return openApplication(
            workspace,
            openSelector,
            containingBundleIdentifier as NSString
        )
    }

    @MainActor
    private func insert(transcript: String) async
        -> KeyboardInsertionResult
    {
        guard viewIfLoaded?.window != nil else {
            return KeyboardInsertionResult(
                confirmed: false,
                documentIdentifierBefore: "surface-unavailable",
                documentIdentifierAfter: "surface-unavailable",
                contextBeforeMutation: nil,
                contextAfterMutation: nil,
                documentChangeObserved: false
            )
        }

        let documentIdentifier = textDocumentProxy.documentIdentifier
        let documentIdentifierBefore = String(describing: documentIdentifier)
        let contextBeforeMutation = textDocumentProxy.documentContextBeforeInput
        let revisionBeforeMutation = documentChangeRevision
        var text = transcript
        if
            let previousCharacter = textDocumentProxy.documentContextBeforeInput?.last,
            !previousCharacter.isWhitespace,
            !previousCharacter.isNewline,
            let firstCharacter = transcript.first,
            !firstCharacter.isPunctuation
        {
            text = " " + text
        }
        textDocumentProxy.insertText(text)
        UIDevice.current.playInputClick()

        var contextAfterMutation =
            textDocumentProxy.documentContextBeforeInput
        var documentIdentifierAfter = String(
            describing: textDocumentProxy.documentIdentifier
        )
        let delays: [Duration] = [
            .zero,
            .milliseconds(40),
            .milliseconds(120),
            .milliseconds(240),
            .milliseconds(480),
        ]
        for delay in delays {
            if delay != .zero {
                try? await Task.sleep(for: delay)
            } else {
                await Task.yield()
            }
            contextAfterMutation = textDocumentProxy.documentContextBeforeInput
            documentIdentifierAfter = String(
                describing: textDocumentProxy.documentIdentifier
            )
            let documentChangeObserved =
                documentChangeRevision != revisionBeforeMutation
            guard
                !Task.isCancelled,
                viewIfLoaded?.window != nil,
                textDocumentProxy.documentIdentifier == documentIdentifier
            else {
                return KeyboardInsertionResult(
                    confirmed: false,
                    documentIdentifierBefore: documentIdentifierBefore,
                    documentIdentifierAfter: documentIdentifierAfter,
                    contextBeforeMutation: contextBeforeMutation,
                    contextAfterMutation: contextAfterMutation,
                    documentChangeObserved: documentChangeObserved
                )
            }
            if KeyboardInsertionAcknowledgementPolicy.confirmsMutation(
                insertedText: text,
                contextBeforeMutation: contextBeforeMutation,
                contextAfterMutation: contextAfterMutation,
                documentChangeObserved: documentChangeObserved
            ) {
                return KeyboardInsertionResult(
                    confirmed: true,
                    documentIdentifierBefore: documentIdentifierBefore,
                    documentIdentifierAfter: documentIdentifierAfter,
                    contextBeforeMutation: contextBeforeMutation,
                    contextAfterMutation: contextAfterMutation,
                    documentChangeObserved: documentChangeObserved
                )
            }
        }
        return KeyboardInsertionResult(
            confirmed: false,
            documentIdentifierBefore: documentIdentifierBefore,
            documentIdentifierAfter: documentIdentifierAfter,
            contextBeforeMutation: contextBeforeMutation,
            contextAfterMutation: contextAfterMutation,
            documentChangeObserved:
                documentChangeRevision != revisionBeforeMutation
        )
    }

    private func insertionContextFingerprint() -> String {
        let proxy = textDocumentProxy
        return InsertionContextFingerprint.make(
            documentIdentifier: proxy.documentIdentifier,
            textBeforeInput: proxy.documentContextBeforeInput,
            textAfterInput: proxy.documentContextAfterInput,
            selectedText: proxy.selectedText,
            keyboardType: proxy.keyboardType?.rawValue
        )
    }
}
