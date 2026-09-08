import Combine
import Foundation

struct KeyboardAppLaunchOutcome: Equatable, Sendable {
    let didOpen: Bool
    let route: String?
    let attempts: [String]

    static func opened(
        route: String,
        attempts: [String]
    ) -> KeyboardAppLaunchOutcome {
        KeyboardAppLaunchOutcome(
            didOpen: true,
            route: route,
            attempts: attempts
        )
    }

    static func failed(attempts: [String]) -> KeyboardAppLaunchOutcome {
        KeyboardAppLaunchOutcome(
            didOpen: false,
            route: nil,
            attempts: attempts
        )
    }
}

@MainActor
final class KeyboardModel: ObservableObject {
    @Published private(set) var snapshot: SharedDictationSnapshot
    @Published var hasFullAccess = false
    @Published private(set) var localError: String?
    @Published private(set) var recentlyInserted = false
    @Published private(set) var isPreparingHost = true
    @Published private(set) var isConfirmingInsertion = false
    /// Optimistic UI state for a cross-process command. The keyboard changes
    /// immediately on tap, then polling clears this only after the recording
    /// process publishes the requested shared phase.
    @Published private(set) var pendingControl: SharedDictationCommand?

    private let store: SharedDictationStore
    private let insertionTelemetry: KeyboardInsertionTelemetryStore
    private let resolveHostApplication: () -> HostApplicationResolution
    private let openContainingApp: (URL) async -> KeyboardAppLaunchOutcome
    private let currentInsertionContextFingerprint: () -> String
    private let insertTranscript: @MainActor (String) async
        -> KeyboardInsertionResult
    private let advanceToNextKeyboard: () -> Void
    private var pollTask: Task<Void, Never>?
    private var insertedConfirmationTask: Task<Void, Never>?
    private var insertionTask: Task<Void, Never>?
    private var isInsertionSurfaceReady = false
    private var startedSessionID: UUID?
    private var pendingControlSessionID: UUID?
    private var pendingControlIssuedAt: Date?

    init(
        store: SharedDictationStore = SharedDictationStore(),
        insertionTelemetry: KeyboardInsertionTelemetryStore = .init(),
        resolveHostApplication: @escaping () -> HostApplicationResolution,
        openContainingApp: @escaping (URL) async -> KeyboardAppLaunchOutcome,
        currentInsertionContextFingerprint: @escaping () -> String,
        insertTranscript: @escaping @MainActor (String) async
            -> KeyboardInsertionResult,
        advanceToNextKeyboard: @escaping () -> Void
    ) {
        self.store = store
        self.insertionTelemetry = insertionTelemetry
        self.snapshot = store.load()
        self.resolveHostApplication = resolveHostApplication
        self.openContainingApp = openContainingApp
        self.currentInsertionContextFingerprint = currentInsertionContextFingerprint
        self.insertTranscript = insertTranscript
        self.advanceToNextKeyboard = advanceToNextKeyboard
    }

    var effectivePhase: SharedDictationPhase {
        guard let pendingControl else { return snapshot.phase }
        return switch pendingControl {
        case .pause:
            .pausing
        case .resume:
            .resuming
        case .stop:
            .transcribing
        case .cancel:
            .cancelled
        case .none, .retry:
            snapshot.phase
        }
    }

    var isIdle: Bool {
        [.idle, .inserted, .handled, .cancelled].contains(effectivePhase)
    }

    var isStarting: Bool {
        effectivePhase == .starting
            || effectivePhase == .resuming
            || effectivePhase == .launching
    }
    var startingStatusText: String {
        if effectivePhase == .resuming { return "Resuming microphone…" }
        return effectivePhase == .launching
            ? "Opening Dictation Button…"
            : "Starting microphone…"
    }
    var isRecording: Bool { effectivePhase == .recording }
    var isPausing: Bool { effectivePhase == .pausing }
    var isPaused: Bool { effectivePhase == .paused }
    var isTranscribing: Bool { effectivePhase == .transcribing }
    var realtimeDraft: String? {
        guard
            let draft = snapshot.realtimeTranscript?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !draft.isEmpty
        else {
            return nil
        }
        return draft
    }
    var canSendRealtimeDraft: Bool {
        snapshot.phase == .transcribing
            && snapshot.realtimeDraftSendable == true
            && realtimeDraft != nil
            && insertionTask == nil
    }
    var isInserting: Bool {
        effectivePhase == .inserting && isConfirmingInsertion
    }
    var isCancelling: Bool { pendingControl == .cancel }
    var isAwaitingControlAcknowledgement: Bool { pendingControl != nil }
    var didFail: Bool {
        [.failed, .deliveryBlocked].contains(snapshot.phase)
            || (snapshot.phase == .inserting && !isConfirmingInsertion)
    }
    var recoveryButtonTitle: String {
        switch snapshot.recoveryAction {
        case .openContainingApp:
            "Open Dictation Button"
        case .insertHere:
            "Insert Here"
        case .reviewPossibleInsertion:
            "Insert Again"
        case .retryTranscription, nil:
            "Retry"
        }
    }
    var errorDismissalButtonTitle: String {
        guard [.deliveryBlocked, .inserting].contains(snapshot.phase) else {
            return "Dismiss"
        }
        return snapshot.historyPersisted == true
            ? "Keep in History"
            : "Discard Transcript"
    }
    var canDismissError: Bool {
        localError != nil
            || [.deliveryBlocked, .inserting].contains(snapshot.phase)
            || (snapshot.phase == .failed
                && snapshot.hasRecoverableAudio != true)
    }

    func startPolling() {
        pollTask?.cancel()
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                self?.refresh()
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func setHostPreparationInProgress(_ isInProgress: Bool) {
        isPreparingHost = isInProgress
    }

    /// `viewWillAppear` is too early to mutate the host document: UIKit may
    /// already have created the extension while its text proxy is still moving
    /// to the newly focused field. Delivery begins only after `viewDidAppear`
    /// (or a later document callback) proves the keyboard is attached.
    func setInsertionSurfaceReady(_ isReady: Bool) {
        guard isInsertionSurfaceReady != isReady else { return }
        isInsertionSurfaceReady = isReady
        if isReady {
            refresh()
        }
    }

    func startDictation() {
        localError = nil
        guard isIdle, !isPreparingHost else { return }
        guard hasFullAccess else {
            localError = "Enable Allow Full Access for Dictation Button in Keyboard Settings."
            return
        }
        guard store.isAvailable else {
            localError = "Dictation Button's shared app group is unavailable. Reinstall the signed app."
            return
        }

        let hostResolution = resolveHostApplication()
        guard let newSnapshot = store.begin(
            returnBundleIdentifier: hostResolution.bundleIdentifier,
            returnProcessIdentifier: hostResolution.processIdentifier,
            insertionContextFingerprint: currentInsertionContextFingerprint()
        ) else {
            snapshot = store.load()
            localError = "Another Dictation Button dictation is still active or waiting for recovery."
            return
        }
        startedSessionID = newSnapshot.sessionID
        store.setHostResolutionDiagnostics(
            hostResolution.attempts,
            sessionID: newSnapshot.sessionID
        )
        snapshot = newSnapshot
        guard let url = URL(
            string: "elevenlabs://dictate/start?session=\(newSnapshot.sessionID.uuidString)"
        ) else {
            return
        }

        Task {
            let outcome = await openContainingApp(url)
            store.setLaunchDiagnostics(
                outcome.attempts,
                successfulRoute: outcome.route,
                sessionID: newSnapshot.sessionID
            )
            if outcome.didOpen {
                try? await Task.sleep(for: .seconds(4))
                let latest = store.load()
                guard
                    latest.sessionID == newSnapshot.sessionID,
                    latest.phase == .launching
                else {
                    return
                }
            }

            let message = "Dictation Button did not open. Dismiss this message and try again."
            store.setPhase(
                .failed,
                sessionID: newSnapshot.sessionID,
                errorMessage: message,
                hasRecoverableAudio: false,
                recoveryAction: .openContainingApp
            )
            localError = message
            refresh()
        }
    }

    func stopAndTranscribe(expectedSessionID: UUID) {
        let current = store.load()
        guard
            current.sessionID == expectedSessionID,
            [.recording, .paused].contains(current.phase)
        else {
            refresh()
            return
        }
        // Capture cursor evidence while the keyboard handles the
        // tap. This is diagnostic only; completed text follows the document
        // proxy that owns focus at delivery time.
        _ = store.claimInsertionContext(
            sessionID: expectedSessionID,
            fingerprint: currentInsertionContextFingerprint(),
            replacingExistingClaim: true
        )
        store.send(.stop, sessionID: expectedSessionID)
        beginPendingControl(.stop, sessionID: expectedSessionID)
        refresh()
    }

    func sendRealtimeDraft(expectedSessionID: UUID) {
        localError = nil
        guard
            isInsertionSurfaceReady,
            insertionTask == nil,
            snapshot.sessionID == expectedSessionID,
            let transcript = store.claimRealtimeDraftForInsertion(
                sessionID: expectedSessionID
            )
        else {
            refresh()
            return
        }
        let claimed = store.load()
        snapshot = claimed
        beginInsertion(
            transcript: transcript,
            snapshot: claimed
        )
    }

    func pauseDictation(expectedSessionID: UUID) {
        sendControl(
            .pause,
            expectedSessionID: expectedSessionID,
            allowedPhases: [.recording]
        )
    }

    func resumeDictation(expectedSessionID: UUID) {
        sendControl(
            .resume,
            expectedSessionID: expectedSessionID,
            allowedPhases: [.paused]
        )
    }

    func cancelDictation(expectedSessionID: UUID) {
        sendControl(
            .cancel,
            expectedSessionID: expectedSessionID,
            allowedPhases: [.recording, .paused]
        )
    }

    func retry() {
        localError = nil
        switch snapshot.recoveryAction {
        case .openContainingApp:
            openElevenLabs()
        case .insertHere, .reviewPossibleInsertion:
            insertPendingHere()
        case .retryTranscription:
            store.send(.retry, sessionID: snapshot.sessionID)
            wakeContainingAppForRecovery(sessionID: snapshot.sessionID)
            refresh()
        case nil:
            store.send(.retry, sessionID: snapshot.sessionID)
            wakeContainingAppForRecovery(sessionID: snapshot.sessionID)
            refresh()
        }
    }

    func openElevenLabs() {
        guard let url = URL(string: "elevenlabs://settings") else { return }
        Task { _ = await openContainingApp(url) }
    }

    private func wakeContainingAppForRecovery(sessionID: UUID) {
        guard let url = URL(
            string: "elevenlabs://recover?session=\(sessionID.uuidString)"
        ) else {
            return
        }
        Task {
            let outcome = await openContainingApp(url)
            if !outcome.didOpen {
                localError = "Open Dictation Button to retry the recovered recording."
            }
        }
    }

    func nextKeyboard() {
        advanceToNextKeyboard()
    }

    func dismissError() {
        let hadLocalError = localError != nil
        localError = nil
        let current = store.load()
        if hadLocalError, startedSessionID != current.sessionID {
            // Full-access and CAS failures are local UI state. Never let their
            // Dismiss button mutate a session owned by the other process.
            snapshot = current
            return
        }
        if [.deliveryBlocked, .inserting].contains(current.phase) {
            // The label says whether this keeps a durable History copy or is
            // explicitly discarding the only transcript under Never retention.
            store.markHandled(sessionID: current.sessionID)
            if startedSessionID == current.sessionID {
                startedSessionID = nil
            }
        } else if current.phase == .failed,
                  current.hasRecoverableAudio != true {
            // Setup/open failures have no private audio bundle to protect. A
            // recreated extension must still be able to clear them and start.
            store.reset(sessionID: current.sessionID)
            if startedSessionID == current.sessionID {
                startedSessionID = nil
            }
        } else if startedSessionID == current.sessionID {
            store.reset(sessionID: current.sessionID)
            startedSessionID = nil
        }
        refresh()
    }

    private func refresh() {
        var latest = store.load()
        if
            latest.phase.allowsKeyboardInsertionContextClaim,
            latest.insertionContextFingerprint == nil
        {
            _ = store.claimInsertionContext(
                sessionID: latest.sessionID,
                fingerprint: currentInsertionContextFingerprint()
            )
            latest = store.load()
        }
        if
            latest.phase.isContainingAppOwned,
            Date().timeIntervalSince(latest.updatedAt)
                > latest.phase.containingAppAbandonmentTimeout
        {
            // Preserve the session ID so a journaled recording can be matched
            // after a force quit or background termination.
            let hasRecoverableAudio = latest.hasRecoverableAudio == true
            let cutoff = Date().addingTimeInterval(
                -latest.phase.containingAppAbandonmentTimeout
            )
            _ = store.failAbandonedSession(
                sessionID: latest.sessionID,
                phases: [latest.phase],
                updatedAtOrBefore: cutoff,
                errorMessage: hasRecoverableAudio
                    ? "Dictation was interrupted. Open Dictation Button to recover the recording."
                    : "Dictation was interrupted before audio was saved. Dismiss this message and try again.",
                hasRecoverableAudio: hasRecoverableAudio,
                recoveryAction: .openContainingApp
            )
            latest = store.load()
            if latest.phase == .failed {
                localError = nil
            }
        }
        reconcilePendingControl(with: latest)
        snapshot = latest

        deliverCompletedTranscript(latest)
    }

    private func sendControl(
        _ command: SharedDictationCommand,
        expectedSessionID: UUID,
        allowedPhases: Set<SharedDictationPhase>
    ) {
        localError = nil
        let current = store.load()
        guard
            current.sessionID == expectedSessionID,
            allowedPhases.contains(current.phase)
        else {
            refresh()
            return
        }
        store.send(command, sessionID: expectedSessionID)
        beginPendingControl(command, sessionID: expectedSessionID)
        refresh()
    }

    private func beginPendingControl(
        _ command: SharedDictationCommand,
        sessionID: UUID
    ) {
        pendingControl = command
        pendingControlSessionID = sessionID
        pendingControlIssuedAt = Date()
    }

    private func reconcilePendingControl(
        with latest: SharedDictationSnapshot
    ) {
        guard let pendingControl else { return }
        guard latest.sessionID == pendingControlSessionID else {
            clearPendingControl()
            return
        }

        let reachedRequestedState: Bool
        switch pendingControl {
        case .pause:
            reachedRequestedState = latest.phase == .paused
        case .resume:
            reachedRequestedState = latest.phase == .recording
        case .stop:
            reachedRequestedState = [
                .transcribing,
                .completed,
                .inserting,
                .deliveryBlocked,
                .inserted,
                .handled,
                .failed,
            ].contains(latest.phase)
        case .cancel:
            reachedRequestedState = [
                .cancelled,
                .idle,
                .handled,
                .failed,
            ].contains(latest.phase)
        case .none, .retry:
            reachedRequestedState = true
        }

        let timedOut = pendingControlIssuedAt.map {
            Date().timeIntervalSince($0) > 8
        } ?? true
        if reachedRequestedState || timedOut {
            clearPendingControl()
        }
    }

    private func clearPendingControl() {
        pendingControl = nil
        pendingControlSessionID = nil
        pendingControlIssuedAt = nil
    }

    private func insertPendingHere() {
        let pending = store.load()
        guard [.deliveryBlocked, .inserting].contains(pending.phase) else {
            return
        }
        store.allowExplicitInsertion(sessionID: pending.sessionID)
        let completed = store.load()
        snapshot = completed
        deliverCompletedTranscript(completed)
    }

    private func deliverCompletedTranscript(
        _ latest: SharedDictationSnapshot
    ) {
        guard
            isInsertionSurfaceReady,
            insertionTask == nil,
            latest.phase == .completed,
            let transcript = latest.transcript?.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            !transcript.isEmpty
        else {
            return
        }

        // A custom keyboard's document proxy follows the writable field that
        // owns focus now. The earlier cursor fingerprint is useful diagnostic
        // context, but it must not veto delivery after iOS recreates a field,
        // moves the caret, or presents the keyboard in another destination.
        // The atomic insertion boundary below still prevents duplicate sends.
        guard store.markInsertionStarted(sessionID: latest.sessionID) else {
            snapshot = store.load()
            return
        }
        let insertingSnapshot = store.load()
        snapshot = insertingSnapshot
        beginInsertion(
            transcript: transcript,
            snapshot: insertingSnapshot
        )
    }

    private func beginInsertion(
        transcript: String,
        snapshot insertingSnapshot: SharedDictationSnapshot
    ) {
        guard insertionTask == nil else { return }
        isConfirmingInsertion = true
        let sessionID = insertingSnapshot.sessionID
        let telemetryID = insertionTelemetry.begin(
            sessionID: sessionID,
            transcript: transcript,
            returnBundleIdentifier: insertingSnapshot.returnBundleIdentifier,
            deliverySource: insertingSnapshot.deliverySource
        )
        insertionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isConfirmingInsertion = false
                self.insertionTask = nil
            }
            let result = await self.insertTranscript(transcript)
            self.insertionTelemetry.finish(id: telemetryID, result: result)
            guard !Task.isCancelled else { return }

            if result.confirmed {
                self.store.markInserted(sessionID: sessionID)
                if self.startedSessionID == sessionID {
                    self.startedSessionID = nil
                }
                self.snapshot = self.store.load()
                self.showInsertedConfirmation()
            } else {
                // `inserting` deliberately retains the transcript and offers an
                // explicit retry. UIKit's proxy has no receipt API, so an
                // unconfirmed mutation must never be reported as delivered.
                self.snapshot = self.store.load()
            }
        }
    }

    private func showInsertedConfirmation() {
        insertedConfirmationTask?.cancel()
        recentlyInserted = true
        insertedConfirmationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.recentlyInserted = false
        }
    }
}
