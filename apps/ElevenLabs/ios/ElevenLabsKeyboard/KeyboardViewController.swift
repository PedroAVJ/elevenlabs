import SwiftUI
import UIKit

final class KeyboardViewController: UIInputViewController {
    private var hostingController: UIHostingController<KeyboardView>?
    private var documentChangeRevision: UInt64 = 0

    private lazy var model = KeyboardModel(
        resolveHostApplication: {
            HostApplicationResolution(
                bundleIdentifier: nil,
                processIdentifier: nil,
                attempts: ["manual-return"]
            )
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
        },
        insertLocalText: { [weak self] text in
            self?.textDocumentProxy.insertText(text)
        },
        deleteLocalCharacter: { [weak self] in
            self?.textDocumentProxy.deleteBackward()
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
        // The public keyboard uses only its current document proxy. Returning
        // to a destination is an explicit user action; no host identity is inferred.
        model.setHostPreparationInProgress(false)
        model.startPolling()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // A completed transcript may arrive while UIKit is still attaching the
        // document proxy. Cross one run-loop turn before allowing insertion.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.viewIfLoaded?.window != nil else { return }
            self.model.setInsertionSurfaceReady(true)
        }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        documentChangeRevision &+= 1
        applyKeyboardAppearance()
        model.hasFullAccess = hasFullAccess
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
    }

    override func viewDidDisappear(_ animated: Bool) {
        model.stopPolling()
        super.viewDidDisappear(animated)
    }

    @MainActor
    private func open(url: URL) async -> KeyboardAppLaunchOutcome {
        guard let extensionContext else {
            return .failed(attempts: ["extension-context-unavailable"])
        }
        let didOpen = await withCheckedContinuation { continuation in
            extensionContext.open(url) { success in
                continuation.resume(returning: success)
            }
        }
        return didOpen
            ? .opened(route: "extension-context", attempts: ["extension-context:true"])
            : .failed(attempts: ["manual-open-required"])
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
