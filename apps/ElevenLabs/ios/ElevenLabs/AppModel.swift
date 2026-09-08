import Combine
import Darwin
import Foundation
import UIKit

@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case paused
        case transcribing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var transcriptText = ""
    @Published var language: TranscriptionLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }
    @Published var cleanSpeech: Bool {
        didSet { defaults.set(cleanSpeech, forKey: Keys.cleanSpeech) }
    }
    @Published var autoCopy: Bool {
        didSet { defaults.set(autoCopy, forKey: Keys.autoCopy) }
    }
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var copiedRecently = false
    @Published var needsMicrophoneSettings = false
    @Published private(set) var recordingNotice: String?
    @Published private(set) var isWaitingToContinue = false
    /// True from the instant a keyboard launch is claimed until capture has
    /// either started or failed. `isKeyboardDictation` only turns true once the
    /// recorder is running, and permission plus audio activation can take a
    /// noticeable moment on a cold launch — without this the round trip shows
    /// the dashboard for that whole window.
    @Published private(set) var isPreparingKeyboardSession = false

    let recorder: AudioRecorder
    let history: HistoryStore
    let audioDiagnostics: AudioDiagnosticsStore

    private let client: ElevenLabsClientProtocol
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private let sharedStore: SharedDictationStore
    private let continuationStore: SharedDictationContinuationStore
    private let recordingJournal: RecordingJournal
    private let segmentedSessionStore: SegmentedDictationSessionStore
    private let liveActivity: DictationLiveActivity

    private struct RecordingTranscriptionSource {
        let audioURL: URL
        let capture: RecordingJournalCapture?
        let journalEntry: RecordingJournalEntry?
        let duration: TimeInterval
        let continuationPartID: UUID?
        let historySourceSessionID: UUID?
        let historyItemID: UUID
        let diagnosticSourceID: UUID
        let diagnosticQuality: AudioCaptureQualitySummary
        let diagnosticMicrophoneMode: AudioMicrophoneModeSnapshot
    }

    private var activeRecordingURL: URL?
    private var activeRecordingCapture: RecordingJournalCapture?
    private var activeRecordingJournalEntry: RecordingJournalEntry?
    private var activeRecordingDuration: TimeInterval = 0
    private var activeSharedSessionID: UUID?
    private var activeRecordingSessionID: UUID?
    private var activeContinuationPartID: UUID?
    private var activeSegmentedSession: SegmentedDictationSessionManifest?
    private var activeLiveActivitySessionID: UUID?
    private struct PendingLiveActivityStart {
        let sessionID: UUID
        let startedAt: Date
    }
    private var pendingLiveActivityStart: PendingLiveActivityStart?
    private var liveActivityStartSessionID: UUID?
    private var liveActivityStartGeneration: UInt64 = 0
    private var liveActivityStartTask: Task<Void, Never>?
    private var hasObservedActiveScene = false
    private var liveActivityUpdateTask: Task<Void, Never>?
    private var liveActivityVisualizationTask: Task<Void, Never>?
    private var captureLeaseHeldID: UUID?
    private var copiedTask: Task<Void, Never>?
    private var sharedMonitorTask: Task<Void, Never>?
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var isStartingRecording = false
    private var isHandlingLiveActivityTap = false
    private var recorderEventCancellable: AnyCancellable?
    private var foregroundControlRequestCancellable: AnyCancellable?
    private var recordingNoticeTask: Task<Void, Never>?
    private var captureLeaseHeartbeatTask: Task<Void, Never>?
    private var recoveryRecheckTask: Task<Void, Never>?
    private var continuationDeliveryWaitTask: Task<Void, Never>?
    private var transcriptionTask: Task<TranscriptionResult, Error>?
    private var realtimeClient: ElevenLabsRealtimeClient?
    private var realtimeTask: Task<Void, Never>?
    private var realtimeAttemptID: UUID?
    private var realtimeSessionID: UUID?
    private var realtimeStartedAt: Date?
    private var didLogFirstRealtimeDraft = false
    private var realtimeDraftIsFinal = false
    private var segmentedTranscriptionTask:
        Task<SegmentedTranscriptAssembly, Error>?
    private var transcriptionAttemptID: UUID?
    private var activeTranscriptionSource: RecordingTranscriptionSource?
    private var continuationBaseDuration: TimeInterval = 0
    private var backgroundContinuationStartupSessionID: UUID?

    private enum Keys {
        static let language = "transcription-language"
        static let cleanSpeech = "clean-speech"
        static let autoCopy = "auto-copy"
    }

    init(
        client: ElevenLabsClientProtocol = ElevenLabsClient(),
        recorder: AudioRecorder? = nil,
        history: HistoryStore? = nil,
        audioDiagnostics: AudioDiagnosticsStore? = nil,
        keychain: KeychainStore = KeychainStore(),
        defaults: UserDefaults = .standard,
        sharedStore: SharedDictationStore = SharedDictationStore(),
        continuationStore: SharedDictationContinuationStore =
            SharedDictationContinuationStore(),
        recordingJournal: RecordingJournal = RecordingJournal(),
        segmentedSessionStore: SegmentedDictationSessionStore =
            SegmentedDictationSessionStore(),
        liveActivity: DictationLiveActivity = DictationLiveActivity()
    ) {
        self.client = client
        self.recorder = recorder ?? AudioRecorder()
        self.history = history ?? HistoryStore()
        self.audioDiagnostics = audioDiagnostics ?? AudioDiagnosticsStore()
        self.keychain = keychain
        self.defaults = defaults
        self.sharedStore = sharedStore
        self.continuationStore = continuationStore
        self.recordingJournal = recordingJournal
        self.segmentedSessionStore = segmentedSessionStore
        self.liveActivity = liveActivity

        if
            let rawLanguage = defaults.string(forKey: Keys.language),
            let savedLanguage = TranscriptionLanguage(rawValue: rawLanguage)
        {
            language = savedLanguage
        } else {
            language = .automatic
        }
        cleanSpeech = defaults.object(forKey: Keys.cleanSpeech) as? Bool ?? true
        autoCopy = defaults.object(forKey: Keys.autoCopy) as? Bool ?? true

        recorderEventCancellable = self.recorder.events.sink { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handleRecorderEvent(event)
            }
        }
        foregroundControlRequestCancellable = NotificationCenter.default
            .publisher(for: ForegroundControlStartRequest.notification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.consumeForegroundControlStartRequest()
                }
            }
        // Active manifests carry the recorder PID. Adoption skips a live owner,
        // but immediately promotes audio left by a force-quit process.
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        restoreOldestRecoverableRecording()
        pruneAudioDiagnosticsToHistory()
    }

    var hasAPIKey: Bool {
        guard let key = keychain.load() else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRecording: Bool { phase == .recording }
    var isPaused: Bool { phase == .paused }
    var isTranscribing: Bool { phase == .transcribing }
    var isKeyboardDictation: Bool { activeSharedSessionID != nil }
    var sessionElapsedDuration: TimeInterval {
        SessionElapsedDurationPolicy.total(
            accumulatedDuration: continuationBaseDuration,
            liveRecorderDuration: recorder.duration,
            finalizedSegmentDuration: activeRecordingDuration,
            isRecording: isRecording,
            hasActiveRecordingReference: activeRecordingURL != nil
                || activeRecordingCapture != nil
                || activeRecordingJournalEntry != nil
        )
    }
    var canStartRecording: Bool {
        isRecording
            || isPaused
            || (!isTranscribing
                && activeRecordingURL == nil
                && activeSegmentedSession == nil)
    }
    var hasRecoverableRecording: Bool {
        activeRecordingURL != nil
            || activeTranscriptionSource != nil
            || activeSegmentedSession != nil
    }
    func toggleRecording() {
        if isRecording || isPaused {
            stopAndTranscribe()
        } else {
            scheduleRecordingStart()
        }
    }

    func startRecording() async {
        guard reserveRecordingStart() else { return }
        await performRecordingStart(for: nil)
    }

    /// Handles the idle Live Activity tap and foreground-launching controls
    /// retained from older builds. The new Control Center action only prepares
    /// the launcher; this path owns its deliberate foreground recording start.
    func handleForegroundControlIntent() {
        // A retained compatibility request must not cause a second start when
        // an older app-opening intent already reached this synchronous path.
        _ = ForegroundControlStartRequest.consume()
        startFromForegroundControl()
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "elevenlabs" else { return }

        if url.host == "control-center", url.path == "/start" {
            handleForegroundControlIntent()
            return
        }

        if url.host == "live-activity" {
            handleLiveActivityURL(url)
            return
        }

        if url.host == "settings" {
            showSettings = true
            return
        }

        if url.host == "recover" {
            let requestedSessionID = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            )?.queryItems?
                .first(where: { $0.name == "session" })?
                .value
                .flatMap(UUID.init(uuidString:))
            let currentSharedSessionID = sharedStore.load().sessionID
            restoreOldestRecoverableRecording(
                preferredSessionID: requestedSessionID == currentSharedSessionID
                    ? requestedSessionID
                    : nil
            )
            if let activeSharedSessionID {
                startSharedCommandMonitor(sessionID: activeSharedSessionID)
            }
            return
        }

        guard url.host == "dictate", url.path == "/start" else { return }
        let snapshot = sharedStore.load()
        guard
            snapshot.phase == .launching || snapshot.phase == .failed,
            Date().timeIntervalSince(snapshot.startedAt) < 30,
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "session" })?
                .value == snapshot.sessionID.uuidString
        else {
            return
        }

        scheduleSharedRecordingStart(sessionID: snapshot.sessionID)
    }

    func handleActivation() {
        if UIApplication.shared.applicationState == .active {
            hasObservedActiveScene = true
            resumePendingKeyboardLiveActivityIfNeeded()
        }
        history.reload()
        restoreOldestRecoverableRecording()
        if case .failed = phase {
            // Keep the visible error until the user chooses Retry or Dismiss.
        } else {
            // An update/relaunch can inherit a setup failure that has neither
            // audio nor a live recorder. Clear only that disposable state so
            // the keyboard is not permanently blocked by an old attempt.
            resetNonrecoverableSharedFailureIfNeeded()
        }
        if ForegroundControlStartRequest.consume() {
            startFromForegroundControl()
            return
        }
        let snapshot = sharedStore.load()
        if
            snapshot.phase == .launching,
            Date().timeIntervalSince(snapshot.updatedAt) < 30,
            !isRecording,
            !isPaused,
            !isTranscribing,
            !isStartingRecording,
            !isHandlingLiveActivityTap
        {
            scheduleSharedRecordingStart(sessionID: snapshot.sessionID)
            return
        }
        ensureIdleLiveActivityIfAppropriate(snapshot: snapshot)
    }

    /// iOS requires the user to enable every new keyboard identity once. The
    /// first URL is the same bounded keyboard-settings destination used by the
    /// reference app; public app settings remain the fallback if iOS rejects
    /// that settings route on a future release.
    func openKeyboardSettings() {
        Task { @MainActor in
            let destinations = [
                "prefs:root=General&path=Keyboard",
                "App-Prefs:root=General&path=Keyboard",
                UIApplication.openSettingsURLString,
            ]
            for destination in destinations {
                guard let url = URL(string: destination) else { continue }
                if await UIApplication.shared.open(url, options: [:]) {
                    return
                }
            }
        }
    }

    /// Kept as a scene-delegate compatibility seam for URLs created by earlier
    /// builds. Manual home-bar swipe is now the only return contract, so host
    /// identity captured here is deliberately ignored.
    func captureLiveActivityLaunchContext(
        _ context: LiveActivityLaunchContext?,
        for url: URL
    ) {
        _ = context
        _ = url
    }

    private func handleLiveActivityURL(_ url: URL) {
        switch url.path {
        case "/start":
            handleForegroundControlIntent()
        default:
            break
        }
    }

    /// The idle launcher opens Dictation Button before entering this path, so
    /// microphone activation has the containing app's normal foreground
    /// lifecycle. It also remains compatible with older app-opening controls.
    private func startFromForegroundControl() {
        resetNonrecoverableSharedFailureIfNeeded()
        var current = sharedStore.load()

        if
            current.sessionKind == .keyboardRoundTrip,
            current.phase == .paused
        {
            continuePausedSharedSession(sessionID: current.sessionID)
            return
        }

        if
            current.sessionKind == .keyboardRoundTrip,
            current.phase == .transcribing
        {
            if startImmediateContinuationIfPossible(
                sessionID: current.sessionID
            ) {
                return
            }
            guard continuationStore.requestContinuation(
                sessionID: current.sessionID
            ) else {
                return
            }
            isWaitingToContinue = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            return
        }

        if
            current.sessionKind == .keyboardRoundTrip,
            current.phase == .completed,
            let reopened = continuationStore.reopenCompletedForContinuation(
                sessionID: current.sessionID
            )
        {
            continuationDeliveryWaitTask?.cancel()
            continuationDeliveryWaitTask = nil
            isWaitingToContinue = false
            continuationBaseDuration = continuationStore.state(
                sessionID: reopened.sessionID
            )?.accumulatedDuration ?? max(0, reopened.elapsedDuration ?? 0)
            scheduleSharedRecordingStart(sessionID: reopened.sessionID)
            return
        }

        current = sharedStore.load()
        if current.phase == .inserting {
            waitForPreviousInsertion(sessionID: current.sessionID)
            return
        }

        guard
            !isRecording,
            !isPaused,
            !isTranscribing,
            !isStartingRecording
        else {
            return
        }

        if
            current.phase == .launching,
            current.sessionKind == .keyboardRoundTrip
        {
            scheduleSharedRecordingStart(sessionID: current.sessionID)
            return
        }

        guard let snapshot = sharedStore.begin(
            returnBundleIdentifier: nil,
            returnProcessIdentifier: nil,
            insertionContextFingerprint: nil
        ) else {
            if current.phase == .failed {
                restoreOldestRecoverableRecording(
                    preferredSessionID: current.sessionID
                )
            }
            return
        }
        scheduleSharedRecordingStart(sessionID: snapshot.sessionID)
    }

    /// Control Center is the only continuation affordance. An in-flight Scribe
    /// request is detached from the stopped file so the next microphone segment
    /// can start immediately; banking continues in parallel and remains ordered
    /// by the durable continuation ledger.
    private func continuePausedSharedSession(sessionID: UUID) {
        let continuation = continuationStore.state(sessionID: sessionID)
        guard continuation?.pausedBoundaryActive == true else {
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "unavailable"
            )
            return
        }

        if activeSharedSessionID == nil {
            activeSharedSessionID = sessionID
            activeRecordingSessionID = sessionID
            activeContinuationPartID = continuation?.activePartID
            continuationBaseDuration = continuation?.accumulatedDuration ?? 0
            phase = .paused
            startSharedCommandMonitor(sessionID: sessionID)
        }

        if transcriptionAttemptID == nil, activeRecordingURL != nil {
            if beginBackgroundExecution() {
                transcribeActiveRecording(publishState: false)
            }
        }
        if startImmediateContinuationIfPossible(sessionID: sessionID) {
            return
        }

        switch continuationStore.requestPausedContinuation(
            sessionID: sessionID
        ) {
        case let .launch(launch):
            isWaitingToContinue = false
            continuationBaseDuration = launch.assembly.duration
            activeContinuationPartID = nil
            phase = .idle
            updateKeyboardLiveActivity(
                .starting,
                sessionID: sessionID,
                elapsedDuration: launch.assembly.duration,
                advancesVisualization: true
            )
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "segment_started"
            )
            scheduleSharedRecordingStart(sessionID: sessionID)

        case .waitingForTranscript:
            isWaitingToContinue = true
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "waiting_for_bank"
            )
            if transcriptionAttemptID == nil, activeRecordingURL != nil {
                if beginBackgroundExecution() {
                    transcribeActiveRecording(publishState: false)
                } else {
                    Observability.logDictationContinuation(
                        event: "control_center_continue",
                        outcome: "bank_deferred"
                    )
                }
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)

        case .unavailable:
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "unavailable"
            )
        }
    }

    /// Moves ownership of the stopped source into its in-flight request, then
    /// claims a new part and recorder without waiting for the network. The
    /// finite background assertion is retained until AVFoundation confirms the
    /// new microphone is hot, closing the fast-swipe suspension window.
    @discardableResult
    private func startImmediateContinuationIfPossible(
        sessionID: UUID
    ) -> Bool {
        guard
            !isStartingRecording,
            let source = activeTranscriptionSource,
            transcriptionAttemptID != nil,
            let sourcePartID = source.continuationPartID,
            let launch = continuationStore.beginImmediateContinuation(
                sessionID: sessionID,
                expectedPriorPartID: sourcePartID
            )
        else {
            return false
        }

        detachActiveRecording(matching: source)
        activeContinuationPartID = launch.nextPartID
        continuationBaseDuration = launch.elapsedDuration
        isWaitingToContinue = false
        phase = .idle
        backgroundContinuationStartupSessionID = sessionID
        updateKeyboardLiveActivity(
            .starting,
            sessionID: sessionID,
            elapsedDuration: launch.elapsedDuration,
            advancesVisualization: true
        )
        scheduleSharedRecordingStart(
            sessionID: sessionID,
            preRegisteredPartID: launch.nextPartID,
            elapsedDuration: launch.elapsedDuration
        )
        Observability.logDictationContinuation(
            event: "control_center_continue",
            outcome: "segment_started_immediately"
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    private func consumeForegroundControlStartRequest() {
        guard ForegroundControlStartRequest.consume() else { return }
        startFromForegroundControl()
    }

    /// `markInsertionStarted` and continuation reopening use the same lock. If
    /// the keyboard won, wait only for its synchronous exact-once insertion to
    /// reach a terminal phase, then make this Control Center press the next
    /// recording. Never steal an `.inserting` transcript or guess that it
    /// landed.
    private func waitForPreviousInsertion(sessionID: UUID) {
        continuationDeliveryWaitTask?.cancel()
        isWaitingToContinue = true
        continuationDeliveryWaitTask = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<250 {
                do {
                    try await Task.sleep(for: .milliseconds(120))
                } catch {
                    return
                }
                let snapshot = self.sharedStore.load()
                guard snapshot.sessionID == sessionID else {
                    self.isWaitingToContinue = false
                    self.startFromForegroundControl()
                    return
                }
                switch snapshot.phase {
                case .idle, .inserted, .handled, .cancelled:
                    self.isWaitingToContinue = false
                    self.startFromForegroundControl()
                    return
                case .completed:
                    self.isWaitingToContinue = false
                    self.startFromForegroundControl()
                    return
                case .deliveryBlocked, .failed:
                    self.isWaitingToContinue = false
                    self.phase = .failed(
                        "The previous transcript still needs delivery. Send or keep it before starting another dictation."
                    )
                    return
                case .launching, .starting, .recording, .pausing, .paused,
                     .resuming, .transcribing, .inserting:
                    continue
                }
            }
            self.isWaitingToContinue = false
            self.phase = .failed(
                "The previous transcript may still be inserting. Review the text field, then try the Control Center button again."
            )
        }
    }


#if false // RETIRED_AUTOMATIC_SWITCHBACK: manual swipe is the product contract.

    private func startFromLiveActivity() {
        guard !isHandlingLiveActivityTap else { return }
        resetNonrecoverableSharedFailureIfNeeded()
        let launchContext = pendingLiveActivityLaunchContext
        pendingLiveActivityLaunchContext = nil
        let initialReturnTarget = LiveActivityReturnTargetResolution.resolve(
            launchContext: launchContext,
            currentVisibleLease: recentVisibleKeyboardHostLease()
        )
        let sourceBundleIdentifier = launchContext?.sourceBundleIdentifier
        isHandlingLiveActivityTap = true
        isPreparingKeyboardSession = true
        let precedingLiveActivityUpdate = liveActivityUpdateTask
        liveActivityUpdateTask = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isHandlingLiveActivityTap = false
                self.isPreparingKeyboardSession = false
            }
            await precedingLiveActivityUpdate?.value
            do {
                let returnTarget = await self.awaitLiveActivityReturnTarget(
                    initialReturnTarget
                )
                let returnBundleIdentifier = returnTarget.bundleIdentifier
                Observability.logLiveActivityHostResolution(
                    available: returnBundleIdentifier != nil,
                    evidence: returnTarget.evidence.rawValue
                )
                self.keyboardHostAppName = HostAppSwitcher.appInfo(
                    for: returnBundleIdentifier
                )?.displayName
                try await DictationEngine.shared.start(
                    returnBundleIdentifier: returnBundleIdentifier,
                    returnProcessIdentifier: returnTarget.processIdentifier
                )
                var snapshot = self.sharedStore.load()
                guard
                    snapshot.sessionKind == .segmentedIntent,
                    snapshot.phase == .recording
                else {
                    return
                }
                let refreshedLease = returnBundleIdentifier.map {
                    VisibleHostApplicationLease(
                        bundleIdentifier: $0,
                        processIdentifier: returnTarget.processIdentifier,
                        capturedAt: Date()
                    )
                } ?? self.recentVisibleKeyboardHostLease()
                if
                    snapshot.returnBundleIdentifier == nil,
                    let refreshedLease
                {
                    if let processIdentifier = refreshedLease.processIdentifier {
                        self.sharedStore.setReturnApplicationIdentity(
                            bundleIdentifier: refreshedLease.bundleIdentifier,
                            processIdentifier: processIdentifier,
                            sessionID: snapshot.sessionID
                        )
                    } else {
                        self.sharedStore.setReturnBundleIdentifier(
                            refreshedLease.bundleIdentifier,
                            sessionID: snapshot.sessionID
                        )
                    }
                    snapshot = self.sharedStore.load()
                }
                self.sharedStore.setHostResolutionDiagnostics(
                    self.liveActivityHostDiagnostics(
                        bundleIdentifier: refreshedLease?.bundleIdentifier,
                        processIdentifier: refreshedLease?.processIdentifier,
                        sourceBundleIdentifier: sourceBundleIdentifier,
                        identityEvidence: returnTarget.evidence.rawValue
                    ),
                    sessionID: snapshot.sessionID
                )
                await self.returnAfterLiveActivityTransition(
                    sessionID: snapshot.sessionID
                )
            } catch {
                Observability.logDictationIntentFailure(
                    error,
                    operation: "live_activity_url_start"
                )
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    /// The keyboard writes its final lease from `viewWillDisappear`, which can
    /// race a warm containing-app URL delivery by a few run-loop turns. Wait a
    /// bounded second only when scene preflight had no target; recording then
    /// starts with the late, still-fresh lease instead of immediately showing
    /// a false manual-return prompt.
    private func awaitLiveActivityReturnTarget(
        _ initial: LiveActivityReturnTargetResolution
    ) async -> LiveActivityReturnTargetResolution {
        guard initial.bundleIdentifier == nil else { return initial }
        for _ in 0..<20 {
            guard !Task.isCancelled else { return initial }
            if let lease = recentVisibleKeyboardHostLease() {
                return LiveActivityReturnTargetResolution.resolve(
                    launchContext: nil,
                    currentVisibleLease: lease
                )
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return initial
    }

    private func resumeFromLiveActivity(sessionID: UUID) {
        var snapshot = sharedStore.load()
        guard
            snapshot.sessionID == sessionID,
            snapshot.phase == .paused
        else {
            return
        }

        if snapshot.sessionKind == .segmentedIntent {
            guard !isHandlingLiveActivityTap else { return }
            let launchContext = pendingLiveActivityLaunchContext
            pendingLiveActivityLaunchContext = nil
            let returnTarget = LiveActivityReturnTargetResolution.resolve(
                launchContext: launchContext,
                currentVisibleLease: recentVisibleKeyboardHostLease()
            )
            let sourceBundleIdentifier = launchContext?.sourceBundleIdentifier
            Observability.logLiveActivityHostResolution(
                available: snapshot.returnBundleIdentifier != nil
                    || returnTarget.bundleIdentifier != nil,
                evidence: snapshot.returnBundleIdentifier != nil
                    ? "shared_session"
                    : returnTarget.evidence.rawValue
            )
            if
                snapshot.returnBundleIdentifier == nil,
                let returnBundleIdentifier = returnTarget.bundleIdentifier
            {
                if let processIdentifier = returnTarget.processIdentifier {
                    sharedStore.setReturnApplicationIdentity(
                        bundleIdentifier: returnBundleIdentifier,
                        processIdentifier: processIdentifier,
                        sessionID: sessionID
                    )
                } else {
                    sharedStore.setReturnBundleIdentifier(
                        returnBundleIdentifier,
                        sessionID: sessionID
                    )
                }
                sharedStore.setHostResolutionDiagnostics(
                    liveActivityHostDiagnostics(
                        bundleIdentifier: returnBundleIdentifier,
                        processIdentifier: returnTarget.processIdentifier,
                        sourceBundleIdentifier: sourceBundleIdentifier,
                        identityEvidence: returnTarget.evidence.rawValue
                    ),
                    sessionID: sessionID
                )
                snapshot = sharedStore.load()
            }

            isHandlingLiveActivityTap = true
            isPreparingKeyboardSession = true
            keyboardHostAppName = HostAppSwitcher.appInfo(
                for: snapshot.returnBundleIdentifier
            )?.displayName
            let precedingLiveActivityUpdate = liveActivityUpdateTask
            liveActivityUpdateTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    self.isHandlingLiveActivityTap = false
                    self.isPreparingKeyboardSession = false
                }
                await precedingLiveActivityUpdate?.value
                do {
                    try await DictationEngine.shared.resume(
                        expectedSessionID: sessionID
                    )
                    await self.returnAfterLiveActivityTransition(
                        sessionID: sessionID
                    )
                } catch {
                    Observability.logDictationIntentFailure(
                        error,
                        operation: "live_activity_url_resume"
                    )
                    self.phase = .failed(error.localizedDescription)
                }
            }
            return
        }

        guard
            snapshot.sessionKind == .keyboardRoundTrip,
            activeSharedSessionID == sessionID,
            isPaused
        else {
            return
        }

        let hostAppName = HostAppSwitcher.displayName(
            for: snapshot.returnBundleIdentifier
        )
        keyboardReturnPrompt = KeyboardReturnPrompt(
            id: sessionID,
            bundleIdentifier: snapshot.returnBundleIdentifier,
            processIdentifier: snapshot.returnProcessIdentifier,
            appName: hostAppName
        )
        keyboardHostAppName = hostAppName
        showManualReturnHint = false
        resumeSharedRecording(expectedSessionID: sessionID)
        guard isRecording else { return }
        if HostAppSwitcher.supportsAutomaticReturn(
            to: snapshot.returnBundleIdentifier
        ) {
            automaticallyReturnToKeyboardHost(sessionID: sessionID)
        } else {
            showManualReturnHint = true
        }
    }

    private func liveActivityHostDiagnostics(
        bundleIdentifier: String?,
        processIdentifier: Int32?,
        sourceBundleIdentifier: String? = nil,
        identityEvidence: String? = nil
    ) -> [String] {
        var diagnostics = ["live-activity-launcher"]
        diagnostics.append(
            "host-identity-evidence:" + (identityEvidence ?? "unavailable")
        )
        if let bundleIdentifier {
            diagnostics.append(
                "visible-keyboard-host:\(bundleIdentifier);pid="
                    + (processIdentifier.map(String.init) ?? "nil")
            )
        } else {
            diagnostics.append("visible-keyboard-host:nil")
        }
        diagnostics.append(
            "live-activity-source:"
                + (sourceBundleIdentifier ?? "nil")
        )
        return diagnostics
    }

    private func returnAfterLiveActivityTransition(
        sessionID: UUID
    ) async {
        let snapshot = sharedStore.load()
        guard
            snapshot.sessionID == sessionID,
            snapshot.sessionKind == .segmentedIntent,
            snapshot.phase == .recording
        else {
            return
        }

        let prompt = KeyboardReturnPrompt(
            id: sessionID,
            bundleIdentifier: snapshot.returnBundleIdentifier,
            processIdentifier: snapshot.returnProcessIdentifier,
            appName: HostAppSwitcher.displayName(
                for: snapshot.returnBundleIdentifier
            )
        )
        keyboardReturnPrompt = prompt
        keyboardHostAppName = prompt.appName
        showManualReturnHint = false
        guard HostAppSwitcher.supportsAutomaticReturn(
            to: prompt.bundleIdentifier
        ) else {
            showManualReturnHint = true
            return
        }

        sharedStore.setReturnDiagnostics(
            HostAppSwitcher.anticipatedAttempts(
                for: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier
            ),
            sessionID: sessionID
        )
        let outcome = await HostAppSwitcher.open(
            bundleIdentifier: prompt.bundleIdentifier,
            processIdentifier: prompt.processIdentifier,
            onAttemptsChanged: { [sharedStore] attempts in
                sharedStore.setReturnDiagnostics(
                    attempts,
                    sessionID: sessionID
                )
            }
        )
        sharedStore.setReturnDiagnostics(
            outcome.attempts,
            sessionID: sessionID
        )
        Observability.logHostReturn(
            didOpen: outcome.didOpen,
            attemptCount: outcome.openAttemptCount
        )
        guard
            sharedStore.load().sessionID == sessionID,
            keyboardReturnPrompt?.id == sessionID
        else {
            return
        }
        if outcome.didOpen {
            keyboardReturnPrompt = nil
        } else {
            showManualReturnHint = true
        }
    }

    private func recentVisibleKeyboardHostLease()
        -> VisibleHostApplicationLease?
    {
        guard
            let fresh = visibleHostLeaseCache.freshLease(),
            HostAppSwitcher.supportsAutomaticReturn(
                to: fresh.bundleIdentifier
            )
        else {
            return nil
        }
        return fresh
    }

    private func ensureIdleLiveActivityIfAppropriate(
        snapshot: SharedDictationSnapshot
    ) {
        guard
            !isRecording,
            !isPaused,
            !isTranscribing,
            !isStartingRecording,
            !isHandlingLiveActivityTap,
            [
                SharedDictationPhase.idle,
                .cancelled,
                .inserted,
                .handled,
            ].contains(snapshot.phase)
        else {
            return
        }
        let precedingUpdate = liveActivityUpdateTask
        liveActivityUpdateTask = Task { [liveActivity] in
            await precedingUpdate?.value
            await liveActivity.ensureIdleLauncher()
        }
    }

    func returnToKeyboardHost() {
        guard let prompt = keyboardReturnPrompt else { return }
        sharedStore.setReturnDiagnostics(
            HostAppSwitcher.anticipatedAttempts(
                for: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier
            ),
            sessionID: prompt.id
        )
        Task {
            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier,
                onAttemptsChanged: { [sharedStore] attempts in
                    sharedStore.setReturnDiagnostics(
                        attempts,
                        sessionID: prompt.id
                    )
                }
            )
            sharedStore.setReturnDiagnostics(
                outcome.attempts,
                sessionID: prompt.id
            )
            Observability.logHostReturn(
                didOpen: outcome.didOpen,
                attemptCount: outcome.openAttemptCount
            )
            let currentSnapshot = sharedStore.load()
            guard
                keyboardReturnPrompt?.id == prompt.id,
                activeSharedSessionID == prompt.id
                    || currentSnapshot.sessionID == prompt.id
            else {
                return
            }
            if outcome.didOpen {
                keyboardReturnPrompt = nil
            } else {
                showManualReturnHint = true
            }
        }
    }

    /// Turns an explicit fallback choice into the same exact cataloged return
    /// target used by automatic switchback. When iOS supplied a known target,
    /// retry only that app. When it supplied no usable target, allow only the
    /// requested ChatGPT and Claude choices instead of guessing.
    func returnToKeyboardHost(_ userSelectedBundleIdentifier: String) {
        guard
            let prompt = keyboardReturnPrompt,
            let selectedApp = HostAppSwitcher.appInfo(
                for: userSelectedBundleIdentifier
            )
        else {
            return
        }

        let capturedApp = HostAppSwitcher.appInfo(
            for: prompt.bundleIdentifier
        )
        if let capturedApp {
            guard capturedApp.bundleIdentifier == selectedApp.bundleIdentifier else {
                return
            }
        } else {
            guard HostAppSwitcher.supportsUserSelectedChatReturn(
                to: selectedApp.bundleIdentifier
            ) else {
                return
            }
        }

        keyboardReturnPrompt = KeyboardReturnPrompt(
            id: prompt.id,
            bundleIdentifier: selectedApp.bundleIdentifier,
            processIdentifier: capturedApp == nil
                ? nil
                : prompt.processIdentifier,
            appName: selectedApp.displayName
        )
        keyboardHostAppName = selectedApp.displayName
        showManualReturnHint = false
        sharedStore.setReturnApplicationIdentity(
            bundleIdentifier: selectedApp.bundleIdentifier,
            processIdentifier: capturedApp == nil
                ? nil
                : prompt.processIdentifier,
            sessionID: prompt.id
        )
        returnToKeyboardHost()
    }

    func confirmSwitchbackExplanation() {
        showSwitchbackExplanation = false
        guard let sessionID = pendingAutomaticReturnSessionID else { return }
        pendingAutomaticReturnSessionID = nil
        if
            let prompt = keyboardReturnPrompt,
            prompt.id == sessionID,
            let key = switchbackExplanationKey(
                for: prompt.bundleIdentifier
            )
        {
            defaults.set(true, forKey: key)
        }
        automaticallyReturnToKeyboardHost(sessionID: sessionID)
    }
#endif

    /// Adopt an already-armed resting Live Activity only when no active or
    /// recoverable state needs the system surface. Control Center is the path
    /// that creates it; app activation never opts the user in implicitly.
    private func ensureIdleLiveActivityIfAppropriate(
        snapshot: SharedDictationSnapshot
    ) {
        guard
            !isRecording,
            !isPaused,
            !isTranscribing,
            !isStartingRecording,
            !isHandlingLiveActivityTap,
            ![
                SharedDictationPhase.launching,
                .starting,
                .recording,
                .pausing,
                .paused,
                .resuming,
                .transcribing,
            ].contains(snapshot.phase)
        else {
            return
        }
        let precedingUpdate = liveActivityUpdateTask
        liveActivityUpdateTask = Task { [liveActivity] in
            await precedingUpdate?.value
            await liveActivity.maintainIdleLauncherIfPresent()
        }
    }

    private func scheduleRecordingStart() {
        guard reserveRecordingStart() else { return }
        Task { await performRecordingStart(for: nil) }
    }

    private func scheduleSharedRecordingStart(
        sessionID: UUID,
        preRegisteredPartID: UUID? = nil,
        elapsedDuration: TimeInterval? = nil
    ) {
        guard reserveRecordingStart() else {
            if rollbackImmediateContinuationStartIfPossible(
                sessionID: sessionID,
                notice: "The microphone could not reopen. The previous segment is still transcribing."
            ) {
                return
            }
            if backgroundContinuationStartupSessionID == sessionID {
                backgroundContinuationStartupSessionID = nil
                endBackgroundExecution()
            }
            return
        }
        guard let snapshot = sharedStore.claimLaunchingSession(
            sessionID: sessionID
        ) else {
            isStartingRecording = false
            if rollbackImmediateContinuationStartIfPossible(
                sessionID: sessionID,
                notice: "The microphone could not reopen. The previous segment is still transcribing."
            ) {
                return
            }
            if backgroundContinuationStartupSessionID == sessionID {
                backgroundContinuationStartupSessionID = nil
                endBackgroundExecution()
            }
            return
        }
        continuationBaseDuration = elapsedDuration
            ?? continuationStore.state(
                sessionID: sessionID
            )?.accumulatedDuration
            ?? 0
        isPreparingKeyboardSession = true
        Task {
            await performRecordingStart(
                for: snapshot,
                preRegisteredPartID: preRegisteredPartID
            )
        }
    }

    /// Reverts only an unstarted continuation part. The prior network request
    /// keeps its protected file and the existing background assertion, so a
    /// microphone-start failure cannot publish an older prefix early or cancel
    /// the segment that was already being transcribed.
    @discardableResult
    private func rollbackImmediateContinuationStartIfPossible(
        sessionID: UUID,
        notice: String
    ) -> Bool {
        guard
            backgroundContinuationStartupSessionID == sessionID,
            activeRecordingURL == nil,
            activeRecordingCapture == nil,
            activeRecordingJournalEntry == nil,
            let priorSource = activeTranscriptionSource,
            transcriptionAttemptID != nil,
            let priorPartID = priorSource.continuationPartID,
            let abandonedPartID = activeContinuationPartID,
            let rollback = continuationStore.abandonImmediateContinuation(
                sessionID: sessionID,
                abandonedPartID: abandonedPartID,
                priorPartID: priorPartID,
                elapsedDuration: continuationBaseDuration
            )
        else {
            return false
        }

        activeContinuationPartID = rollback.priorPartID
        continuationBaseDuration = rollback.elapsedDuration
        backgroundContinuationStartupSessionID = nil
        isWaitingToContinue = false
        phase = .transcribing
        updateKeyboardLiveActivity(
            .transcribing,
            sessionID: sessionID,
            elapsedDuration: rollback.elapsedDuration,
            advancesVisualization: true
        )
        startLiveActivityVisualization(sessionID: sessionID)
        showRecordingNotice(notice)
        Observability.logDictationContinuation(
            event: "control_center_continue",
            outcome: "microphone_start_rolled_back"
        )
        return true
    }

    private func reserveRecordingStart() -> Bool {
        guard
            !isRecording,
            !isPaused,
            !isTranscribing,
            !isStartingRecording
        else {
            return false
        }
        isStartingRecording = true
        return true
    }

    private func performRecordingStart(
        for incomingSharedSnapshot: SharedDictationSnapshot?,
        preRegisteredPartID: UUID? = nil
    ) async {
        // By the time this returns, a successful start has already published
        // `.recording`, so the keyboard surface stays up without a gap.
        defer {
            isStartingRecording = false
            isPreparingKeyboardSession = false
            if
                let incomingSharedSnapshot,
                backgroundContinuationStartupSessionID
                    == incomingSharedSnapshot.sessionID,
                !recorder.isRecording
            {
                backgroundContinuationStartupSessionID = nil
                endBackgroundExecution()
            }
        }
        guard activeRecordingURL == nil, activeSegmentedSession == nil else {
            let message = "An unfinished recording is ready to retry. Transcribe or discard it before starting another dictation."
            phase = .failed(message)
            if let incomingSharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: incomingSharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
            }
            endBackgroundExecution()
            return
        }
        let sharedSnapshot = incomingSharedSnapshot
        guard hasAPIKey else {
            if
                let sharedSnapshot,
                rollbackImmediateContinuationStartIfPossible(
                    sessionID: sharedSnapshot.sessionID,
                    notice: "The microphone could not reopen. The previous segment is still transcribing."
                )
            {
                releaseCaptureLease()
                return
            }
            if
                let sharedSnapshot,
                restoreAccumulatedContinuationIfAvailable(
                    sessionID: sharedSnapshot.sessionID
                )
            {
                return
            }
            showSettings = true
            let message = "Add your speech API key before your first dictation."
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
                sharedStore.releaseCaptureLease(
                    ownerID: sharedSnapshot.sessionID
                )
            }
            endBackgroundExecution()
            return
        }

        let recordingSessionID = sharedSnapshot?.sessionID ?? UUID()
        if sharedSnapshot != nil {
            // The launch and lease were claimed atomically before this task
            // was queued. If ownership changed meanwhile, this is a stale
            // callback; leave the newer state and its real error untouched.
            guard sharedStore.renewCaptureLease(
                ownerID: recordingSessionID
            ) else {
                _ = rollbackImmediateContinuationStartIfPossible(
                    sessionID: recordingSessionID,
                    notice: "The microphone could not reopen. The previous segment is still transcribing."
                )
                return
            }
        } else {
            guard sharedStore.acquireCaptureLease(
                ownerID: recordingSessionID
            ) else {
                phase = .failed(
                    "Another Dictation Button recording is already using the microphone. Stop it before starting a new dictation."
                )
                return
            }
        }
        activeRecordingSessionID = recordingSessionID
        captureLeaseHeldID = recordingSessionID
        startCaptureLeaseHeartbeat(ownerID: recordingSessionID)

        if sharedSnapshot != nil {
            let partID: UUID?
            if let preRegisteredPartID {
                partID = continuationStore.state(
                    sessionID: recordingSessionID
                )?.activePartID == preRegisteredPartID
                    ? preRegisteredPartID
                    : nil
            } else {
                partID = continuationStore.registerPart(
                    sessionID: recordingSessionID
                )
            }
            guard let partID else {
                if rollbackImmediateContinuationStartIfPossible(
                    sessionID: recordingSessionID,
                    notice: "The microphone could not reopen. The previous segment is still transcribing."
                ) {
                    releaseCaptureLease()
                    return
                }
                if restoreAccumulatedContinuationIfAvailable(
                    sessionID: recordingSessionID
                ) {
                    return
                }
                let message = "Dictation Button couldn't reserve durable continuation state. No recording was started."
                phase = .failed(message)
                sharedStore.setPhase(
                    .failed,
                    sessionID: recordingSessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
                releaseCaptureLease()
                return
            }
            activeContinuationPartID = partID
        }

        let hasPermission = await recorder.requestPermission()
        guard hasPermission else {
            if
                let sharedSnapshot,
                rollbackImmediateContinuationStartIfPossible(
                    sessionID: sharedSnapshot.sessionID,
                    notice: "The microphone could not reopen. The previous segment is still transcribing."
                )
            {
                releaseCaptureLease()
                return
            }
            if
                let sharedSnapshot,
                restoreAccumulatedContinuationIfAvailable(
                    sessionID: sharedSnapshot.sessionID
                )
            {
                return
            }
            needsMicrophoneSettings = true
            let message = AudioRecorderError.microphoneDenied.localizedDescription
            phase = .failed(message)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: false,
                    recoveryAction: .openContainingApp
                )
            }
            releaseCaptureLease()
            return
        }

        if
            let sharedSnapshot,
            activeLiveActivitySessionID != sharedSnapshot.sessionID
        {
            await startKeyboardLiveActivity(for: sharedSnapshot)
        } else if let sharedSnapshot {
            updateKeyboardLiveActivity(
                .starting,
                sessionID: sharedSnapshot.sessionID,
                elapsedDuration: continuationBaseDuration,
                advancesVisualization: true
            )
        }

        do {
            // Every keyboard segment uses its continuation part identity as the
            // journal identity. That makes multiple overlapping protected files
            // unambiguous after a crash; standalone recordings keep their
            // session identity for backward-compatible recovery.
            let capture = try recordingJournal.beginCapture(
                id: activeContinuationPartID ?? recordingSessionID,
                audioFileExtension: sharedSnapshot == nil ? "m4a" : "wav"
            )
            activeRecordingCapture = capture
            do {
                activeRecordingURL = try await recorder.start(
                    capture: capture,
                    in: recordingJournal
                )
                recorder.reportCaptureStarted(surface: "containing_app")
            } catch {
                recorder.reportCaptureStartFailure(
                    error,
                    surface: "containing_app"
                )
                throw error
            }
            recordingNotice = nil
            phase = .recording
            if let sharedSnapshot {
                activeSharedSessionID = sharedSnapshot.sessionID
                let recordingStartedAt = Date()
                let published = sharedStore.setPhase(
                    .recording,
                    sessionID: sharedSnapshot.sessionID,
                    hasRecoverableAudio: true,
                    elapsedDuration: continuationBaseDuration,
                    startedAt: recordingStartedAt
                )
                guard published else {
                    activeRecordingDuration = recorder.duration
                    let finalizedURL = recorder.stop() ?? activeRecordingURL
                    releaseCaptureLease()
                    activeRecordingURL = finalizeProtectedRecording(
                        at: finalizedURL,
                        duration: activeRecordingDuration
                    )
                    phase = .failed(
                        "Dictation Button started recording, but shared storage became unavailable. The audio is saved; retry in Dictation Button."
                    )
                    endKeyboardLiveActivity(
                        .failed,
                        sessionID: sharedSnapshot.sessionID
                    )
                    if
                        backgroundContinuationStartupSessionID
                            == sharedSnapshot.sessionID,
                        activeTranscriptionSource != nil,
                        transcriptionAttemptID != nil
                    {
                        // The stopped newer file is protected. Keep the finite
                        // assertion with the older in-flight request; once it
                        // banks, that request will submit this file next.
                        backgroundContinuationStartupSessionID = nil
                    }
                    return
                }
                updateKeyboardLiveActivity(
                    .recording,
                    sessionID: sharedSnapshot.sessionID,
                    recordingStartedAt: recordingStartedAt,
                    elapsedDuration: continuationBaseDuration,
                    audioLevel: Double(recorder.level),
                    meterLevels: recorder.meterLevels.map(Double.init)
                )
                startLiveActivityVisualization(
                    sessionID: sharedSnapshot.sessionID
                )
                startSharedCommandMonitor(sessionID: sharedSnapshot.sessionID)
                if let activeRecordingURL {
                    startRealtimeTranscription(
                        audioURL: activeRecordingURL,
                        sessionID: sharedSnapshot.sessionID
                    )
                }
            }
            if backgroundContinuationStartupSessionID == recordingSessionID {
                backgroundContinuationStartupSessionID = nil
                endBackgroundExecution()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } catch {
            var hasRecoverableAudio = false
            if let activeRecordingCapture {
                // `recorder.start` did not return, so capture never became an
                // acknowledged recorder. Usually its empty reservation can be
                // retired; if AVFoundation wrote bytes before failing, preserve
                // and finalize those bytes instead.
                do {
                    try recordingJournal.abandonCapture(activeRecordingCapture)
                    self.activeRecordingCapture = nil
                    activeRecordingURL = nil
                } catch {
                    activeRecordingURL = try? recordingJournal.audioURL(
                        for: activeRecordingCapture
                    )
                    activeRecordingURL = finalizeProtectedRecording(
                        at: activeRecordingURL,
                        duration: recorder.duration
                    )
                    hasRecoverableAudio = activeRecordingURL != nil
                }
            }
            if
                let sharedSnapshot,
                !hasRecoverableAudio,
                rollbackImmediateContinuationStartIfPossible(
                    sessionID: sharedSnapshot.sessionID,
                    notice: "The microphone could not reopen. The previous segment is still transcribing."
                )
            {
                releaseCaptureLease()
                return
            }
            if
                let sharedSnapshot,
                !hasRecoverableAudio,
                restoreAccumulatedContinuationIfAvailable(
                    sessionID: sharedSnapshot.sessionID
                )
            {
                return
            }
            phase = .failed(error.localizedDescription)
            if let sharedSnapshot {
                sharedStore.setPhase(
                    .failed,
                    sessionID: sharedSnapshot.sessionID,
                    errorMessage: error.localizedDescription,
                    hasRecoverableAudio: hasRecoverableAudio,
                    recoveryAction: .openContainingApp
                )
                endKeyboardLiveActivity(
                    .failed,
                    sessionID: sharedSnapshot.sessionID
                )
            }
            if backgroundContinuationStartupSessionID == recordingSessionID {
                backgroundContinuationStartupSessionID = nil
                if activeTranscriptionSource == nil
                    || transcriptionAttemptID == nil
                {
                    endBackgroundExecution()
                }
            }
            releaseCaptureLease()
        }
    }

#if false // RETIRED_AUTOMATIC_SWITCHBACK: manual swipe is the product contract.
    private func hasShownSwitchbackExplanation(
        for bundleIdentifier: String?
    ) -> Bool {
        guard let key = switchbackExplanationKey(for: bundleIdentifier) else {
            return false
        }
        return defaults.bool(forKey: key)
    }

    private func switchbackExplanationKey(
        for bundleIdentifier: String?
    ) -> String? {
        guard
            HostAppSwitcher.supportsAutomaticReturn(to: bundleIdentifier),
            let bundleIdentifier
        else {
            return nil
        }
        return Keys.switchbackExplanationPrefix
            + bundleIdentifier.lowercased()
    }

    private func automaticallyReturnToKeyboardHost(sessionID: UUID) {
        Task { [weak self] in
            guard
                let self,
                self.activeSharedSessionID == sessionID,
                let prompt = self.keyboardReturnPrompt,
                prompt.id == sessionID
            else {
                return
            }

            self.sharedStore.setReturnDiagnostics(
                HostAppSwitcher.anticipatedAttempts(
                    for: prompt.bundleIdentifier,
                    processIdentifier: prompt.processIdentifier
                ),
                sessionID: sessionID
            )

            let outcome = await HostAppSwitcher.open(
                bundleIdentifier: prompt.bundleIdentifier,
                processIdentifier: prompt.processIdentifier,
                onAttemptsChanged: { [sharedStore = self.sharedStore] attempts in
                    sharedStore.setReturnDiagnostics(
                        attempts,
                        sessionID: sessionID
                    )
                }
            )
            self.sharedStore.setReturnDiagnostics(
                outcome.attempts,
                sessionID: sessionID
            )
            Observability.logHostReturn(
                didOpen: outcome.didOpen,
                attemptCount: outcome.openAttemptCount
            )
            guard
                self.activeSharedSessionID == sessionID,
                self.keyboardReturnPrompt?.id == sessionID
            else {
                return
            }
            if outcome.didOpen {
                self.keyboardReturnPrompt = nil
            } else {
                self.showManualReturnHint = true
            }
        }
    }
#endif

    private func startKeyboardLiveActivity(
        for snapshot: SharedDictationSnapshot
    ) async {
        guard LiveActivityStartReadiness.permitsRequest(
            hasObservedActiveScene: hasObservedActiveScene,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else {
            pendingLiveActivityStart = PendingLiveActivityStart(
                sessionID: snapshot.sessionID,
                startedAt: snapshot.startedAt
            )
            return
        }
        guard
            liveActivityStartTask == nil,
            liveActivityStartSessionID != snapshot.sessionID
        else {
            return
        }
        if pendingLiveActivityStart?.sessionID == snapshot.sessionID {
            pendingLiveActivityStart = nil
        }
        await requestKeyboardLiveActivity(
            sessionID: snapshot.sessionID,
            startedAt: snapshot.startedAt
        )
    }

    private func resumePendingKeyboardLiveActivityIfNeeded() {
        guard
            let pendingLiveActivityStart,
            LiveActivityStartReadiness.permitsRequest(
                hasObservedActiveScene: hasObservedActiveScene,
                applicationIsActive:
                    UIApplication.shared.applicationState == .active
            ),
            liveActivityStartSessionID == nil,
            liveActivityStartTask == nil
        else {
            return
        }
        self.pendingLiveActivityStart = nil
        liveActivityStartTask = Task { [weak self] in
            guard let self else { return }
            await self.requestKeyboardLiveActivity(
                sessionID: pendingLiveActivityStart.sessionID,
                startedAt: pendingLiveActivityStart.startedAt
            )
            self.liveActivityStartTask = nil
        }
    }

    private func requestKeyboardLiveActivity(
        sessionID: UUID,
        startedAt: Date
    ) async {
        guard LiveActivityStartReadiness.permitsRequest(
            hasObservedActiveScene: hasObservedActiveScene,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else {
            pendingLiveActivityStart = PendingLiveActivityStart(
                sessionID: sessionID,
                startedAt: startedAt
            )
            return
        }
        guard liveActivityStartSessionID != sessionID else { return }
        liveActivityStartGeneration &+= 1
        let generation = liveActivityStartGeneration
        liveActivityStartSessionID = sessionID
        defer {
            if
                generation == liveActivityStartGeneration,
                liveActivityStartSessionID == sessionID
            {
                liveActivityStartSessionID = nil
            }
        }
        await liveActivityUpdateTask?.value
        guard
            generation == liveActivityStartGeneration,
            liveActivityStartSessionID == sessionID,
            isCurrentLiveActivitySession(sessionID)
        else {
            return
        }
        liveActivityUpdateTask = nil
        guard LiveActivityStartReadiness.permitsRequest(
            hasObservedActiveScene: hasObservedActiveScene,
            applicationIsActive:
                UIApplication.shared.applicationState == .active
        ) else {
            pendingLiveActivityStart = PendingLiveActivityStart(
                sessionID: sessionID,
                startedAt: startedAt
            )
            return
        }
        do {
            try await liveActivity.start(
                sessionID: sessionID,
                startedAt: startedAt
            )
            guard
                generation == liveActivityStartGeneration,
                liveActivityStartSessionID == sessionID,
                isCurrentLiveActivitySession(sessionID)
            else {
                await liveActivity.end(.cancelled, sessionID: sessionID)
                return
            }
            activeLiveActivitySessionID = sessionID
            synchronizeStartedLiveActivity(sessionID: sessionID)
        } catch {
            guard
                generation == liveActivityStartGeneration,
                liveActivityStartSessionID == sessionID,
                isCurrentLiveActivitySession(sessionID)
            else {
                return
            }
            if !LiveActivityStartReadiness.permitsRequest(
                hasObservedActiveScene: hasObservedActiveScene,
                applicationIsActive:
                    UIApplication.shared.applicationState == .active
            ) {
                pendingLiveActivityStart = PendingLiveActivityStart(
                    sessionID: sessionID,
                    startedAt: startedAt
                )
            } else {
                // Foreground capture remains valid when Live Activities are
                // disabled or ActivityKit rejects the request.
                Observability.logLiveActivityFailure(
                    operation: "keyboard_start"
                )
            }
        }
    }

    private func isCurrentLiveActivitySession(_ sessionID: UUID) -> Bool {
        let snapshot = sharedStore.load()
        return snapshot.sessionID == sessionID
            && [
                SharedDictationPhase.launching,
                .starting,
                .recording,
                .paused,
                .transcribing,
            ].contains(snapshot.phase)
    }

    private func synchronizeStartedLiveActivity(sessionID: UUID) {
        let snapshot = sharedStore.load()
        guard snapshot.sessionID == sessionID else { return }
        switch snapshot.phase {
        case .recording:
            updateKeyboardLiveActivity(
                .recording,
                sessionID: sessionID,
                recordingStartedAt: snapshot.startedAt,
                elapsedDuration: snapshot.elapsedDuration,
                audioLevel: Double(recorder.level),
                meterLevels: recorder.meterLevels.map(Double.init)
            )
            startLiveActivityVisualization(sessionID: sessionID)
        case .paused:
            updateKeyboardLiveActivity(
                .paused,
                sessionID: sessionID,
                elapsedDuration: snapshot.elapsedDuration,
                advancesVisualization: true
            )
        case .transcribing:
            updateKeyboardLiveActivity(
                .transcribing,
                sessionID: sessionID,
                elapsedDuration: snapshot.elapsedDuration,
                advancesVisualization: true
            )
            startLiveActivityVisualization(sessionID: sessionID)
        case .launching, .starting:
            updateKeyboardLiveActivity(
                .starting,
                sessionID: sessionID,
                elapsedDuration: snapshot.elapsedDuration,
                advancesVisualization: true
            )
        case .resuming:
            updateKeyboardLiveActivity(
                .resuming,
                sessionID: sessionID,
                elapsedDuration: snapshot.elapsedDuration,
                advancesVisualization: true
            )
        case .pausing:
            updateKeyboardLiveActivity(
                .pausing,
                sessionID: sessionID,
                elapsedDuration: snapshot.elapsedDuration,
                advancesVisualization: true
            )
        default:
            break
        }
    }

    private func updateKeyboardLiveActivity(
        _ activityPhase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID,
        recordingStartedAt: Date? = nil,
        elapsedDuration: TimeInterval? = nil,
        audioLevel: Double? = nil,
        meterLevels: [Double]? = nil,
        advancesVisualization: Bool = false
    ) {
        guard activeLiveActivitySessionID == sessionID else { return }
        let precedingUpdate = liveActivityUpdateTask
        liveActivityUpdateTask = Task { [weak self] in
            await precedingUpdate?.value
            guard
                let self,
                self.activeLiveActivitySessionID == sessionID
            else {
                return
            }
            await self.liveActivity.update(
                activityPhase,
                sessionID: sessionID,
                recordingStartedAt: recordingStartedAt,
                elapsedDuration: elapsedDuration,
                audioLevel: audioLevel,
                meterLevels: meterLevels,
                advancesVisualization: advancesVisualization
            )
        }
    }

    /// ActivityKit renders only committed content updates. A stream of
    /// fire-and-forget tasks can continuously supersede itself while the
    /// system is still committing the previous frame, leaving the minimal
    /// island stuck forever. This single producer waits for each commit before
    /// sampling the next privacy-safe microphone level, so speech always gets
    /// a chance to advance the Studio Meter without building an update backlog.
    private func startLiveActivityVisualization(sessionID: UUID) {
        liveActivityVisualizationTask?.cancel()
        let precedingUpdate = liveActivityUpdateTask
        liveActivityVisualizationTask = Task { [weak self] in
            await precedingUpdate?.value
            guard !Task.isCancelled else { return }
            Observability.logDictationContinuation(
                event: "visualization",
                outcome: "started"
            )

            while !Task.isCancelled {
                guard
                    let self,
                    self.activeLiveActivitySessionID == sessionID,
                    self.activeSharedSessionID == sessionID
                else {
                    return
                }

                if self.isRecording {
                    await self.liveActivity.update(
                        .recording,
                        sessionID: sessionID,
                        audioLevel: Double(self.recorder.level),
                        meterLevels: self.recorder.meterLevels.map(Double.init),
                        advancesVisualization: true
                    )
                } else if self.isTranscribing {
                    await self.liveActivity.update(
                        .transcribing,
                        sessionID: sessionID,
                        elapsedDuration: self.continuationBaseDuration
                            + self.activeRecordingDuration,
                        advancesVisualization: true
                    )
                } else {
                    return
                }

                do {
                    try await Task.sleep(for: .milliseconds(180))
                } catch {
                    return
                }
            }
        }
    }

    private func stopLiveActivityVisualization() {
        liveActivityVisualizationTask?.cancel()
        liveActivityVisualizationTask = nil
    }

    @discardableResult
    private func endKeyboardLiveActivity(
        _ activityPhase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID
    ) -> Task<Void, Never>? {
        if pendingLiveActivityStart?.sessionID == sessionID {
            pendingLiveActivityStart = nil
        }
        if liveActivityStartSessionID == sessionID {
            liveActivityStartGeneration &+= 1
            liveActivityStartSessionID = nil
        }
        guard activeLiveActivitySessionID == sessionID else { return nil }
        stopLiveActivityVisualization()
        activeLiveActivitySessionID = nil
        let precedingUpdate = liveActivityUpdateTask
        let terminalUpdate = Task { [liveActivity] in
            await precedingUpdate?.value
            await liveActivity.end(activityPhase, sessionID: sessionID)
        }
        liveActivityUpdateTask = terminalUpdate
        return terminalUpdate
    }

    func stopAndTranscribe() {
        guard isRecording || isPaused else { return }
        if isPaused, transcriptionAttemptID != nil {
            // Pause already closed this segment and its one transcription is
            // in flight. Send changes only the delivery decision; starting a
            // second request would duplicate the same bytes.
            publishTranscribingState()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
        activeRecordingDuration = recorder.duration
        publishTranscribingState()
        let finalizedURL = recorder.stop() ?? activeRecordingURL
        finishRealtimeTranscription()
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL,
            duration: activeRecordingDuration
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        transcribeActiveRecording(publishState: false)
    }

    func cancelRecording() {
        guard isRecording || isPaused else { return }
        cancelRealtimeTranscription()
        stopLiveActivityVisualization()
        let detachedPriorSource = activeTranscriptionSource.flatMap { source in
            activeRecordingMatches(source) ? nil : source
        }
        let abandonedContinuationPartID = activeContinuationPartID
        let cancelsPausedBoundary = activeSharedSessionID.flatMap {
            continuationStore.state(sessionID: $0)?.pausedBoundaryActive
        } == true
        activeRecordingDuration = recorder.duration
        let finalizedURL = recorder.stop() ?? activeRecordingURL
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL,
            duration: activeRecordingDuration
        )
        let wasKeyboardDictation = activeSharedSessionID != nil
        guard discardActiveRecording() else {
            if let activeSharedSessionID {
                sharedStore.setPhase(
                    .failed,
                    sessionID: activeSharedSessionID,
                    errorMessage: "Dictation Button couldn't discard the recording. Retry or discard it again.",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
                endKeyboardLiveActivity(
                    .failed,
                    sessionID: activeSharedSessionID
                )
            }
            return
        }
        if
            let activeSharedSessionID,
            let detachedPriorSource,
            let priorPartID = detachedPriorSource.continuationPartID,
            let abandonedContinuationPartID,
            let rollback = continuationStore.abandonImmediateContinuation(
                sessionID: activeSharedSessionID,
                abandonedPartID: abandonedContinuationPartID,
                priorPartID: priorPartID,
                elapsedDuration: continuationBaseDuration
            )
        {
            // Cancel applies to the segment the user is hearing now. The older
            // Scribe request was already in flight before that segment began;
            // restore it as the delivery owner instead of cancelling or losing
            // the user's earlier dictation.
            activeContinuationPartID = rollback.priorPartID
            continuationBaseDuration = rollback.elapsedDuration
            phase = .transcribing
            isWaitingToContinue = false
            updateKeyboardLiveActivity(
                .transcribing,
                sessionID: activeSharedSessionID,
                elapsedDuration: rollback.elapsedDuration,
                advancesVisualization: true
            )
            startLiveActivityVisualization(sessionID: activeSharedSessionID)
            if transcriptionAttemptID == nil, beginBackgroundExecution() {
                transcribeActiveRecording(publishState: false)
            }
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "newer_segment_cancelled_prior_preserved"
            )
            return
        }
        if let activeSharedSessionID, detachedPriorSource != nil {
            let message = "The newer segment was cancelled, but Dictation Button couldn't restore the earlier transcription boundary. Its audio remains protected for Retry."
            phase = .failed(message)
            _ = sharedStore.setPhase(
                .failed,
                sessionID: activeSharedSessionID,
                errorMessage: message,
                hasRecoverableAudio: true,
                recoveryAction: .retryTranscription,
                elapsedDuration: continuationBaseDuration
            )
            updateKeyboardLiveActivity(
                .failed,
                sessionID: activeSharedSessionID,
                elapsedDuration: continuationBaseDuration
            )
            return
        }
        if let activeSharedSessionID, cancelsPausedBoundary {
            _ = sharedStore.setPhase(
                .cancelled,
                sessionID: activeSharedSessionID,
                hasRecoverableAudio: false
            )
            continuationStore.clear(sessionID: activeSharedSessionID)
            endKeyboardLiveActivity(
                .cancelled,
                sessionID: activeSharedSessionID
            )
            Observability.logDictationContinuation(
                event: "pause_boundary",
                outcome: "cancelled"
            )
            finishSharedSession(keepSharedResult: true)
            phase = .idle
            ensureIdleLiveActivityIfAppropriate(snapshot: sharedStore.load())
            return
        }
        if
            let activeSharedSessionID,
            restoreAccumulatedContinuationIfAvailable(
                sessionID: activeSharedSessionID
            )
        {
            return
        }
        if let activeSharedSessionID {
            sharedStore.setPhase(.cancelled, sessionID: activeSharedSessionID)
            continuationStore.clear(sessionID: activeSharedSessionID)
            endKeyboardLiveActivity(
                .cancelled,
                sessionID: activeSharedSessionID
            )
        }
        finishSharedSession(keepSharedResult: wasKeyboardDictation)
        phase = .idle
        ensureIdleLiveActivityIfAppropriate(snapshot: sharedStore.load())
    }

    /// Pause is a real segment boundary. Closing the recorder before publishing
    /// `.paused` guarantees that neither silence nor a background pause interval
    /// can enter the next ElevenLabs request, and releasing the audio session
    /// gives interrupted media back to the system immediately.
    @discardableResult
    func pauseSharedRecording(expectedSessionID: UUID) async -> Bool {
        guard
            activeSharedSessionID == expectedSessionID,
            isRecording
        else {
            return false
        }

        stopLiveActivityVisualization()
        let finalizedURL = recorder.stop(deactivatesSession: true)
            ?? activeRecordingURL
        finishRealtimeTranscription()
        activeRecordingDuration = recorder.duration
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL,
            duration: activeRecordingDuration
        )
        let totalElapsed = continuationBaseDuration + activeRecordingDuration
        phase = .paused

        guard continuationStore.beginPausedBoundary(
            sessionID: expectedSessionID,
            elapsedDuration: totalElapsed
        ) else {
            let message = "Dictation Button stopped listening, but couldn't save the pause boundary. The audio is protected; retry transcription in the app."
            phase = .failed(message)
            _ = sharedStore.setPhase(
                .failed,
                sessionID: expectedSessionID,
                errorMessage: message,
                hasRecoverableAudio: activeRecordingURL != nil,
                recoveryAction: .retryTranscription,
                elapsedDuration: totalElapsed
            )
            updateKeyboardLiveActivity(
                .failed,
                sessionID: expectedSessionID,
                elapsedDuration: totalElapsed
            )
            Observability.logDictationContinuation(
                event: "pause_boundary",
                outcome: "storage_failed"
            )
            return false
        }

        let boundaryCommand = sharedStore.takePendingCommand(
            sessionID: expectedSessionID,
            accepting: [.stop, .cancel]
        )
        if boundaryCommand == .cancel {
            cancelRecording()
            return true
        }
        if boundaryCommand == .stop {
            publishTranscribingState()
        } else {
            updateKeyboardLiveActivity(
                .paused,
                sessionID: expectedSessionID,
                elapsedDuration: totalElapsed
            )
        }
        Observability.logDictationContinuation(
            event: "pause_boundary",
            outcome: "segment_finalized",
            durationMs: Int((activeRecordingDuration * 1_000).rounded())
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Banking begins immediately while iOS still grants the intent's
        // execution window. If no background slot is available, the protected
        // segment remains recoverable and the next Control Center invocation
        // retries it before opening a fresh microphone segment.
        if beginBackgroundExecution() {
            transcribeActiveRecording(publishState: false)
        } else {
            Observability.logDictationContinuation(
                event: "pause_boundary",
                outcome: "bank_deferred"
            )
        }
        return true
    }

    func retry() {
        guard hasRecoverableRecording else { return }
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        if activeSegmentedSession != nil {
            transcribeActiveSegmentedSession()
        } else {
            transcribeActiveRecording()
        }
    }

    func retryAfterError() {
        if hasRecoverableRecording {
            retry()
        } else {
            resetNonrecoverableSharedFailureIfNeeded()
            phase = .idle
            ensureIdleLiveActivityIfAppropriate(snapshot: sharedStore.load())
        }
    }

    func discardRecoverableRecording() {
        guard hasRecoverableRecording else { return }
        let sharedSessionID = activeSharedSessionID
        transcriptionTask?.cancel()
        transcriptionTask = nil
        transcriptionAttemptID = nil
        if activeSegmentedSession != nil {
            guard discardActiveSegmentedSession() else { return }
        } else {
            guard discardAllActiveRecordingSources() else { return }
        }
        if let sharedSessionID {
            guard discardContinuationJournalEntries(
                sessionID: sharedSessionID
            ) else {
                return
            }
            if restoreAccumulatedContinuationIfAvailable(
                sessionID: sharedSessionID
            ) {
                recordingNotice = nil
                return
            }
            sharedStore.markHandled(sessionID: sharedSessionID)
            continuationStore.clear(sessionID: sharedSessionID)
        }
        finishSharedSession(keepSharedResult: true)
        recordingNotice = nil
        phase = .idle
        ensureIdleLiveActivityIfAppropriate(snapshot: sharedStore.load())
    }

    /// Cancelling or failing a later continuation must never make the already
    /// transcribed prefix disappear. Republish that prefix into the unchanged
    /// keyboard delivery lane, then retire only the abandoned newer part.
    @discardableResult
    private func restoreAccumulatedContinuationIfAvailable(
        sessionID: UUID
    ) -> Bool {
        guard
            let continuation = continuationStore.state(sessionID: sessionID),
            !continuation.accumulatedTranscript.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return false
        }

        let snapshot = sharedStore.load()
        guard sharedStore.setPhase(
            .completed,
            sessionID: sessionID,
            transcript: continuation.accumulatedTranscript,
            historyPersisted: snapshot.historyPersisted,
            hasRecoverableAudio: false,
            elapsedDuration: continuation.accumulatedDuration
        ) else {
            phase = .failed(
                "The newer recording stopped, but the earlier transcript remains protected. Keep Dictation Button open and retry delivery."
            )
            endKeyboardLiveActivity(.failed, sessionID: sessionID)
            return true
        }

        transcriptText = continuation.accumulatedTranscript
        continuationStore.clear(sessionID: sessionID)
        endKeyboardLiveActivity(.completed, sessionID: sessionID)
        finishSharedSession(keepSharedResult: true)
        phase = .idle
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return true
    }

    func saveAPIKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            try keychain.delete()
        } else {
            try keychain.save(key)
        }
        objectWillChange.send()
    }

    func deleteAPIKey() throws {
        try keychain.delete()
        objectWillChange.send()
    }

    func copyTranscript() {
        let text = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showCopiedConfirmation()
    }

    func clearTranscript() {
        transcriptText = ""
        phase = .idle
    }

    func useHistoryItem(_ item: TranscriptItem) {
        acknowledgePendingTranscript(for: item)
        transcriptText = item.text
        phase = .idle
        showHistory = false
    }

    func copyHistoryItem(_ item: TranscriptItem) {
        UIPasteboard.general.string = item.text
        acknowledgePendingTranscript(for: item)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func deleteHistoryItem(_ item: TranscriptItem) {
        acknowledgePendingTranscript(for: item)
        history.delete(id: item.id)
        audioDiagnostics.delete(historyID: item.id)
    }

    func clearHistory() {
        let pending = sharedStore.load()
        if [.completed, .inserting, .deliveryBlocked].contains(pending.phase) {
            sharedStore.markHandled(sessionID: pending.sessionID)
        }
        history.clear()
        audioDiagnostics.prune(keeping: [])
    }

    func setHistoryRetention(_ policy: HistoryRetentionPolicy) {
        history.setRetention(policy)
        pruneAudioDiagnosticsToHistory()
    }

    func toggleHistoryAudio(_ item: TranscriptItem) throws {
        try audioDiagnostics.togglePlayback(for: item.id)
    }

    func reportHistoryAudioIssue(_ item: TranscriptItem) throws {
        guard let record = audioDiagnostics.record(for: item.id) else {
            throw AudioDiagnosticsStoreError.audioMissing
        }
        Observability.captureAudioDiagnosticReport(record)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func pruneAudioDiagnosticsToHistory() {
        audioDiagnostics.prune(keeping: Set(history.items.map(\.id)))
    }

    private func acknowledgePendingTranscript(for item: TranscriptItem) {
        let pending = sharedStore.load()
        guard [.completed, .inserting, .deliveryBlocked].contains(pending.phase) else {
            return
        }

        let matchesPendingSession: Bool
        if let sourceSessionID = item.sourceSessionID {
            matchesPendingSession = sourceSessionID == pending.sessionID
        } else {
            // Compatibility for on-device history written before session IDs
            // were stored with background transcripts. If a tagged row exists,
            // an older duplicate must never acknowledge it. For a genuinely
            // legacy pending session, only its newest time-correlated row wins.
            let hasTaggedPendingItem = history.items.contains {
                $0.sourceSessionID == pending.sessionID
            }
            let pendingText = pending.transcript?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let legacyPendingItem = history.items
                .filter {
                    $0.sourceSessionID == nil
                        && $0.createdAt
                            >= pending.startedAt.addingTimeInterval(-1)
                        && $0.text.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ) == pendingText
                }
                .max { $0.createdAt < $1.createdAt }
            matchesPendingSession = !hasTaggedPendingItem
                && legacyPendingItem?.id == item.id
        }
        guard matchesPendingSession else { return }
        sharedStore.markHandled(sessionID: pending.sessionID)
    }

    func dismissError() {
        guard !hasRecoverableRecording else { return }
        if case .failed = phase {
            resetNonrecoverableSharedFailureIfNeeded()
            guard sharedStore.load().phase != .failed else { return }
            phase = .idle
            ensureIdleLiveActivityIfAppropriate(snapshot: sharedStore.load())
        }
    }

    private func resetNonrecoverableSharedFailureIfNeeded() {
        let snapshot = sharedStore.load()
        if
            snapshot.phase == .failed,
            snapshot.hasRecoverableAudio != true,
            restoreAccumulatedContinuationIfAvailable(
                sessionID: snapshot.sessionID
            )
        {
            return
        }
        _ = sharedStore.resetNonrecoverableFailure(
            sessionID: snapshot.sessionID
        )
    }

    private func transcribeActiveRecording(publishState: Bool = true) {
        guard let apiKey = keychain.load(), !apiKey.isEmpty else {
            if
                let activeSharedSessionID,
                restoreAccumulatedContinuationIfAvailable(
                    sessionID: activeSharedSessionID
                )
            {
                return
            }
            let message = "The recording or speech API key is missing."
            phase = .failed(message)
            if let activeSharedSessionID {
                sharedStore.setPhase(
                    .failed,
                    sessionID: activeSharedSessionID,
                    errorMessage: message,
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
                endKeyboardLiveActivity(
                    .failed,
                    sessionID: activeSharedSessionID
                )
            }
            endBackgroundExecution()
            return
        }

        guard transcriptionAttemptID == nil else { return }
        let source: RecordingTranscriptionSource
        if let retainedSource = activeTranscriptionSource {
            // A fast continuation detaches the previous stopped file while its
            // request runs. If that request fails, retry that exact older part
            // before ever submitting the newer file and preserve transcript
            // order without overwriting either journal owner.
            source = retainedSource
        } else {
            guard let audioURL = activeRecordingURL else {
                if
                    let activeSharedSessionID,
                    restoreAccumulatedContinuationIfAvailable(
                        sessionID: activeSharedSessionID
                    )
                {
                    return
                }
                let message = "The recording or speech API key is missing."
                phase = .failed(message)
                if let activeSharedSessionID {
                    sharedStore.setPhase(
                        .failed,
                        sessionID: activeSharedSessionID,
                        errorMessage: message,
                        hasRecoverableAudio: true,
                        recoveryAction: .openContainingApp
                    )
                    endKeyboardLiveActivity(
                        .failed,
                        sessionID: activeSharedSessionID
                    )
                }
                endBackgroundExecution()
                return
            }
            let duration = activeRecordingDuration
            let continuationPartID: UUID? = {
                guard let activeSharedSessionID else { return nil }
                if let activeContinuationPartID {
                    return activeContinuationPartID
                }
                if let persistedPartID = continuationStore.state(
                    sessionID: activeSharedSessionID
                )?.activePartID {
                    return persistedPartID
                }
                // Recordings created by an older build do not have a sidecar
                // part. Give a recovered retry a stable identity before its
                // result exists.
                return continuationStore.registerPart(
                    sessionID: activeSharedSessionID
                )
            }()
            activeContinuationPartID = continuationPartID
            let historySourceSessionID = activeSharedSessionID
                ?? activeRecordingSessionID
                ?? activeRecordingJournalEntry?.id
            let historyItemID = historySourceSessionID ?? UUID()
            // Keyboard continuations reuse the parent history item. The part ID
            // remains the durable, unique identity for each diagnostic source.
            let diagnosticSourceID = activeContinuationPartID
                ?? activeRecordingJournalEntry?.id
                ?? activeRecordingCapture?.id
                ?? historyItemID
            source = RecordingTranscriptionSource(
                audioURL: audioURL,
                capture: activeRecordingCapture,
                journalEntry: activeRecordingJournalEntry,
                duration: duration,
                continuationPartID: continuationPartID,
                historySourceSessionID: historySourceSessionID,
                historyItemID: historyItemID,
                diagnosticSourceID: diagnosticSourceID,
                diagnosticQuality: recorder.captureQualitySummary,
                diagnosticMicrophoneMode: recorder.microphoneModeSnapshot
            )
            activeTranscriptionSource = source
        }

        let attemptID = UUID()
        transcriptionAttemptID = attemptID
        let transcriptionBackgroundTaskID = backgroundTaskID
        if publishState {
            publishTranscribingState()
        }
        updateRealtimeDraftSendability(for: source)
        let selectedLanguage = language
        let shouldCleanSpeech = cleanSpeech
        let audioURL = source.audioURL
        let duration = source.duration
        let continuationPartID = source.continuationPartID
        let historySourceSessionID = source.historySourceSessionID
        let historyItemID = source.historyItemID
        let diagnosticSourceID = source.diagnosticSourceID
        let diagnosticQuality = source.diagnosticQuality
        let diagnosticMicrophoneMode = source.diagnosticMicrophoneMode

        let request = Task {
            try await client.transcribe(
                audioURL: audioURL,
                apiKey: apiKey,
                language: selectedLanguage,
                cleanSpeech: shouldCleanSpeech
            )
        }
        transcriptionTask = request

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await request.value
                guard self.transcriptionAttemptID == attemptID else { return }
                self.transcriptionTask = nil
                Observability.logTranscriptionCompleted(
                    characterCount: result.text.count,
                    surface: "ios_containing_app",
                    sessionID: historySourceSessionID,
                    partID: continuationPartID,
                    requestedLanguage: selectedLanguage.rawValue,
                    detectedLanguage: result.languageCode,
                    languageProbability: result.languageProbability,
                    durationMs: Int((duration * 1_000).rounded())
                )
                let assembly: SharedDictationContinuationAssembly
                if
                    let activeSharedSessionID = self.activeSharedSessionID,
                    let continuationPartID
                {
                    assembly = self.continuationStore.assembly(
                        sessionID: activeSharedSessionID,
                        partID: continuationPartID,
                        transcript: result.text,
                        duration: duration
                    )
                } else {
                    assembly = SharedDictationContinuationAssembly(
                        text: result.text,
                        duration: duration
                    )
                }
                self.transcriptText = assembly.text
                let historyPersisted = self.history.add(
                    TranscriptItem(
                        id: historyItemID,
                        text: assembly.text,
                        languageCode: result.languageCode,
                        duration: assembly.duration,
                        sourceSessionID: historySourceSessionID
                    )
                )
                if historyPersisted {
                    self.archiveAudioDiagnostics(
                        sources: [
                            AudioDiagnosticSource(
                                id: diagnosticSourceID,
                                url: audioURL
                            ),
                        ],
                        historyID: historyItemID,
                        createdAt: Date(),
                        duration: assembly.duration,
                        quality: diagnosticQuality,
                        microphoneMode: diagnosticMicrophoneMode,
                        languageProbability: result.languageProbability
                    )
                }

                if
                    let activeSharedSessionID = self.activeSharedSessionID,
                    let continuationPartID,
                    let bankedAssembly = self.continuationStore
                        .bankImmediateContinuationPart(
                            sessionID: activeSharedSessionID,
                            partID: continuationPartID,
                            transcript: result.text,
                            duration: duration,
                            historyPersisted: historyPersisted
                        )
                {
                    self.transcriptionAttemptID = nil
                    self.activeTranscriptionSource = nil
                    self.continuationBaseDuration = bankedAssembly.duration
                    self.consumeTranscriptionSource(source)
                    if
                        self.activeRecordingURL != nil,
                        !self.isRecording,
                        !self.isStartingRecording
                    {
                        if !self.isTranscribing && !self.isPaused {
                            self.publishTranscribingState()
                        }
                        self.transcribeActiveRecording(publishState: false)
                    } else if
                        !self.isRecording,
                        !self.isStartingRecording,
                        self.backgroundContinuationStartupSessionID
                            != activeSharedSessionID
                    {
                        if self.restoreNextContinuationPartIfAvailable(
                            sessionID: activeSharedSessionID
                        ) {
                            self.phase = .transcribing
                            let recoveredElapsed = max(
                                bankedAssembly.duration,
                                max(
                                    0,
                                    self.sharedStore.load()
                                        .elapsedDuration ?? 0
                                )
                            )
                            _ = self.sharedStore.setPhase(
                                .transcribing,
                                sessionID: activeSharedSessionID,
                                hasRecoverableAudio: true,
                                elapsedDuration: recoveredElapsed
                            )
                            self.updateKeyboardLiveActivity(
                                .transcribing,
                                sessionID: activeSharedSessionID,
                                elapsedDuration: recoveredElapsed,
                                advancesVisualization: true
                            )
                            self.transcribeActiveRecording(
                                publishState: false
                            )
                        } else if !self.restoreAccumulatedContinuationIfAvailable(
                            sessionID: activeSharedSessionID
                        ) {
                            self.endBackgroundExecution(
                                expected: transcriptionBackgroundTaskID
                            )
                        }
                    }
                    Observability.logDictationContinuation(
                        event: "control_center_continue",
                        outcome: "prior_segment_banked"
                    )
                    return
                }

                if
                    let activeSharedSessionID = self.activeSharedSessionID,
                    let continuationPartID,
                    let pausedCompletion = self.continuationStore
                        .completePausedPart(
                            sessionID: activeSharedSessionID,
                            partID: continuationPartID,
                            transcript: result.text,
                            duration: duration,
                            historyPersisted: historyPersisted
                        )
                {
                    switch pausedCompletion {
                    case let .waiting(bankedAssembly):
                        self.transcriptionAttemptID = nil
                        self.phase = .paused
                        self.isWaitingToContinue = false
                        self.continuationBaseDuration = bankedAssembly.duration
                        self.activeTranscriptionSource = nil
                        self.consumeTranscriptionSource(source)
                        self.endBackgroundExecution(
                            expected: transcriptionBackgroundTaskID
                        )
                        self.updateKeyboardLiveActivity(
                            .paused,
                            sessionID: activeSharedSessionID,
                            elapsedDuration: bankedAssembly.duration
                        )
                        Observability.logDictationContinuation(
                            event: "pause_boundary",
                            outcome: "segment_banked",
                            durationMs: Int(
                                (duration * 1_000).rounded()
                            )
                        )
                        return

                    case let .launch(launch):
                        self.transcriptionAttemptID = nil
                        self.phase = .idle
                        self.isWaitingToContinue = false
                        self.continuationBaseDuration = launch.assembly.duration
                        self.activeTranscriptionSource = nil
                        self.consumeTranscriptionSource(source)
                        self.backgroundContinuationStartupSessionID =
                            activeSharedSessionID
                        self.updateKeyboardLiveActivity(
                            .starting,
                            sessionID: activeSharedSessionID,
                            elapsedDuration: launch.assembly.duration,
                            advancesVisualization: true
                        )
                        Observability.logDictationContinuation(
                            event: "control_center_continue",
                            outcome: "segment_started"
                        )
                        self.scheduleSharedRecordingStart(
                            sessionID: activeSharedSessionID
                        )
                        return

                    case .finishing:
                        // The keyboard's Send command arrived while the pause
                        // segment was still banking. The ledger is now durable;
                        // fall through and publish the already assembled text.
                        break

                    case .storageFailed:
                        self.transcriptionAttemptID = nil
                        let message = "The paused segment was transcribed, but its continuation boundary could not be saved. The audio remains protected for Retry."
                        self.phase = .failed(message)
                        _ = self.sharedStore.setPhase(
                            .failed,
                            sessionID: activeSharedSessionID,
                            errorMessage: message,
                            hasRecoverableAudio: true,
                            recoveryAction: .retryTranscription,
                            elapsedDuration: assembly.duration
                        )
                        self.updateKeyboardLiveActivity(
                            .failed,
                            sessionID: activeSharedSessionID,
                            elapsedDuration: assembly.duration
                        )
                        self.endBackgroundExecution(
                            expected: transcriptionBackgroundTaskID
                        )
                        Observability.logDictationContinuation(
                            event: "pause_boundary",
                            outcome: "storage_failed"
                        )
                        return
                    }
                }

                if
                    let activeSharedSessionID = self.activeSharedSessionID,
                    let continuationPartID,
                    let launch = self.continuationStore
                        .beginRequestedContinuation(
                            sessionID: activeSharedSessionID,
                            partID: continuationPartID,
                            transcript: result.text,
                            duration: duration,
                            historyPersisted: historyPersisted
                        )
                {
                    // The Control Center press arrived before completion. Bank
                    // this exact part, retire its audio, and immediately reuse
                    // the same delivery session for the next recording. No
                    // live draft is eligible for insertion until the combined
                    // final source begins its batch request, so this older part
                    // cannot be sent without the newer recording.
                    self.transcriptionAttemptID = nil
                    self.phase = .idle
                    self.isWaitingToContinue = false
                    self.continuationBaseDuration = launch.assembly.duration
                    self.activeTranscriptionSource = nil
                    self.consumeTranscriptionSource(source)
                    self.backgroundContinuationStartupSessionID =
                        activeSharedSessionID
                    self.updateKeyboardLiveActivity(
                        .starting,
                        sessionID: activeSharedSessionID,
                        elapsedDuration: launch.assembly.duration,
                        advancesVisualization: true
                    )
                    self.scheduleSharedRecordingStart(
                        sessionID: activeSharedSessionID
                    )
                    return
                }

                var liveActivityCompletionTask: Task<Void, Never>?
                var sharedDeliveryOutcome: String?
                if let activeSharedSessionID = self.activeSharedSessionID {
                    let publishResult = self.sharedStore.publishBatchCompletion(
                        sessionID: activeSharedSessionID,
                        transcript: assembly.text,
                        historyPersisted: historyPersisted,
                        elapsedDuration: assembly.duration
                    )
                    guard publishResult != .rejected else {
                        self.transcriptionAttemptID = nil
                        self.phase = .failed(
                            "The transcript finished, but Dictation Button couldn't deliver it to the controls. The recording is saved; retry when storage is available."
                        )
                        self.endBackgroundExecution()
                        self.sharedMonitorTask?.cancel()
                        self.sharedMonitorTask = nil
                        self.endKeyboardLiveActivity(
                            .failed,
                            sessionID: activeSharedSessionID
                        )
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        return
                    }
                    sharedDeliveryOutcome = publishResult == .publishedBatch
                        ? "batch_delivery_ready"
                        : "realtime_already_delivered"
                    self.continuationStore.clear(
                        sessionID: activeSharedSessionID
                    )
                    liveActivityCompletionTask = self.endKeyboardLiveActivity(
                        .completed,
                        sessionID: activeSharedSessionID
                    )
                }
                self.transcriptionAttemptID = nil
                self.phase = .idle
                // Keyboard delivery goes straight to the original field. Also
                // writing the pasteboard leaks dictated text and produces a
                // surprising second side effect.
                if self.autoCopy && self.activeSharedSessionID == nil {
                    self.copyTranscript()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                Observability.logDictationFinished(
                    outcome: self.activeSharedSessionID == nil
                        ? "completed_in_app"
                        : sharedDeliveryOutcome ?? "shared_delivery_ready",
                    durationMs: Int((assembly.duration * 1_000).rounded()),
                    characterCount: assembly.text.count,
                    sessionID: historySourceSessionID
                )
                self.activeTranscriptionSource = nil
                self.consumeTranscriptionSource(source)
                // Complete the one-step idle ActivityKit update before
                // finishSharedSession releases our finite background time.
                await liveActivityCompletionTask?.value
                let latest = self.sharedStore.load()
                let didBeginAnotherPart = latest.sessionID
                    == historySourceSessionID
                    && [
                        SharedDictationPhase.launching,
                        .starting,
                        .recording,
                        .paused,
                        .transcribing,
                    ].contains(latest.phase)
                if didBeginAnotherPart {
                    // A second Control Center press can win while the terminal
                    // ActivityKit update is awaiting. Never let the older
                    // completion tear down that newer capture or background job.
                    self.endBackgroundExecution(
                        expected: transcriptionBackgroundTaskID
                    )
                } else {
                    self.finishSharedSession(keepSharedResult: true)
                }
                self.ensureIdleLiveActivityIfAppropriate(
                    snapshot: self.sharedStore.load()
                )
            } catch {
                guard self.transcriptionAttemptID == attemptID else { return }
                Observability.logTranscriptionFailure(
                    error,
                    surface: "ios_containing_app",
                    sessionID: historySourceSessionID,
                    partID: continuationPartID,
                    durationMs: Int((duration * 1_000).rounded()),
                    quality: diagnosticQuality,
                    preferredMicrophoneMode:
                        diagnosticMicrophoneMode.preferred,
                    activeMicrophoneMode: diagnosticMicrophoneMode.active
                )
                self.transcriptionTask = nil
                self.transcriptionAttemptID = nil
                let newerCaptureIsLive = !self.activeRecordingMatches(source)
                    && (self.isRecording
                        || self.isStartingRecording
                        || self.backgroundContinuationStartupSessionID
                            == self.activeSharedSessionID)
                if newerCaptureIsLive {
                    // The network request owns the older protected file; the
                    // recorder owns a different, newer one. A failure of the
                    // former must not turn a live microphone into Failed or
                    // dismiss its Activity. Send/Pause will retry the retained
                    // source first, then submit the current segment in order.
                    self.showRecordingNotice(
                        "The previous segment will retry when you Send or Pause. This recording is still listening."
                    )
                    Observability.logDictationContinuation(
                        event: "prior_segment_transcription",
                        outcome: "retry_deferred_while_recording"
                    )
                    UINotificationFeedbackGenerator()
                        .notificationOccurred(.warning)
                    return
                }
                if
                    let activeSharedSessionID = self.activeSharedSessionID,
                    self.realtimeDeliveryOwnsSession(
                        sessionID: activeSharedSessionID
                    )
                {
                    // The user explicitly chose latency and the keyboard has
                    // already crossed its exactly-once insertion boundary.
                    // A later refinement failure must not replace that success
                    // with an error or block the next recording.
                    _ = self.sharedStore
                        .settleRealtimeDeliveryAfterBatchFailure(
                            sessionID: activeSharedSessionID,
                            elapsedDuration: duration
                        )
                    self.consumeTranscriptionSource(source)
                    self.activeTranscriptionSource = nil
                    self.continuationStore.clear(
                        sessionID: activeSharedSessionID
                    )
                    let completion = self.endKeyboardLiveActivity(
                        .completed,
                        sessionID: activeSharedSessionID
                    )
                    self.phase = .idle
                    await completion?.value
                    self.finishSharedSession(keepSharedResult: true)
                    Observability.logDictationContinuation(
                        event: "realtime_delivery",
                        outcome: "batch_failed_after_send"
                    )
                    self.ensureIdleLiveActivityIfAppropriate(
                        snapshot: self.sharedStore.load()
                    )
                    return
                }
                self.phase = .failed(error.localizedDescription)
                if let activeSharedSessionID = self.activeSharedSessionID {
                    self.sharedStore.setPhase(
                        .failed,
                        sessionID: activeSharedSessionID,
                        errorMessage: error.localizedDescription,
                        hasRecoverableAudio: true,
                        recoveryAction: self.sharedRecoveryAction(for: error)
                    )
                    self.endKeyboardLiveActivity(
                        .failed,
                        sessionID: activeSharedSessionID
                    )
                }
                self.endBackgroundExecution(
                    expected: transcriptionBackgroundTaskID
                )
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func transcribeActiveSegmentedSession() {
        guard
            let manifest = activeSegmentedSession,
            let apiKey = keychain.load(),
            !apiKey.isEmpty
        else {
            phase = .failed(
                "The segmented recording or speech API key is missing."
            )
            endBackgroundExecution()
            return
        }
        guard transcriptionAttemptID == nil else { return }

        let group: SegmentedDictationRecoveryGroup
        do {
            group = try segmentedSessionStore.recoveryGroup(
                for: manifest,
                journalEntries: recordingJournal.recoverableEntries()
            )
        } catch {
            phase = .failed(error.localizedDescription)
            endBackgroundExecution()
            return
        }

        let attemptID = UUID()
        transcriptionAttemptID = attemptID
        phase = .transcribing
        if activeSharedSessionID == manifest.id {
            sharedStore.setPhase(.transcribing, sessionID: manifest.id)
        }
        if let updatedManifest = try? segmentedSessionStore.setLifecycle(
            .transcribing,
            sessionID: manifest.id
        ) {
            activeSegmentedSession = updatedManifest
        }
        let selectedLanguage = language
        let shouldCleanSpeech = cleanSpeech
        let client = self.client
        let recordingJournal = self.recordingJournal
        let request = Task {
            var pieces: [SegmentedTranscriptPiece] = []
            for (segment, entry) in zip(
                manifest.orderedSegments,
                group.entries
            ) {
                do {
                    let result = try await client.transcribe(
                        audioURL: try recordingJournal.audioURL(for: entry),
                        apiKey: apiKey,
                        language: selectedLanguage,
                        cleanSpeech: shouldCleanSpeech
                    )
                    Observability.logTranscriptionCompleted(
                        characterCount: result.text.count,
                        surface: "ios_segmented_recovery",
                        sessionID: manifest.id,
                        partID: entry.id,
                        requestedLanguage: selectedLanguage.rawValue,
                        detectedLanguage: result.languageCode,
                        languageProbability: result.languageProbability,
                        durationMs: Int((entry.duration * 1_000).rounded())
                    )
                    pieces.append(
                        SegmentedTranscriptPiece(
                            ordinal: segment.ordinal,
                            text: result.text,
                            languageCode: result.languageCode
                        )
                    )
                } catch {
                    guard SegmentedTranscriptFailurePolicy.canSkipSegment(error) else {
                        throw error
                    }
                    Observability.logSegmentTranscriptionSkipped(
                        surface: "containing_app_recovery",
                        reason: "noSpeech"
                    )
                }
            }
            guard let assembly = SegmentedTranscriptAssembler.assemble(pieces) else {
                throw ElevenLabsClientError.emptyTranscript
            }
            return assembly
        }
        segmentedTranscriptionTask = request

        Task { [weak self] in
            guard let self else { return }
            do {
                let assembly = try await request.value
                guard
                    self.transcriptionAttemptID == attemptID,
                    self.activeSegmentedSession?.id == manifest.id
                else {
                    return
                }
                self.segmentedTranscriptionTask = nil
                self.transcriptText = assembly.text
                let historyPersisted = self.history.add(
                    TranscriptItem(
                        id: manifest.id,
                        text: assembly.text,
                        languageCode: assembly.languageCode,
                        duration: manifest.totalDuration,
                        sourceSessionID: manifest.id
                    )
                )
                if historyPersisted {
                    let sources = zip(manifest.orderedSegments, group.entries)
                        .compactMap { _, entry -> AudioDiagnosticSource? in
                            guard let url = try? self.recordingJournal.audioURL(
                                for: entry
                            ) else {
                                return nil
                            }
                            return AudioDiagnosticSource(id: entry.id, url: url)
                        }
                    self.archiveAudioDiagnostics(
                        sources: sources,
                        historyID: manifest.id,
                        createdAt: manifest.createdAt,
                        duration: manifest.totalDuration,
                        quality: self.recorder.captureQualitySummary,
                        microphoneMode: self.recorder.microphoneModeSnapshot,
                        languageProbability: nil
                    )
                }

                var sharedPersisted = false
                var liveActivityCompletionTask: Task<Void, Never>?
                if self.activeSharedSessionID == manifest.id {
                    sharedPersisted = self.sharedStore.setPhase(
                        .completed,
                        sessionID: manifest.id,
                        transcript: assembly.text,
                        historyPersisted: historyPersisted,
                        hasRecoverableAudio: false
                    )
                    guard sharedPersisted else {
                        throw DictationEngine.EngineError.sharedStateUnavailable
                    }
                    liveActivityCompletionTask = self.endKeyboardLiveActivity(
                        .completed,
                        sessionID: manifest.id
                    )
                }
                self.transcriptionAttemptID = nil
                self.phase = .idle
                _ = try? self.segmentedSessionStore.setLifecycle(
                    .completed,
                    sessionID: manifest.id
                )
                try? self.retireSegmentedSession(
                    manifest,
                    entries: group.entries,
                    discarding: false
                )
                // A durable completion can outlive a transient cleanup error.
                // Drop the in-memory recovery selection so the next restore
                // pass can retry any completed manifest that remains on disk.
                self.activeSegmentedSession = nil
                if self.autoCopy && self.activeSharedSessionID == nil {
                    self.copyTranscript()
                } else {
                    UINotificationFeedbackGenerator().notificationOccurred(
                        .success
                    )
                }
                Observability.logDictationFinished(
                    outcome: self.activeSharedSessionID == nil
                        ? "completed_in_app"
                        : "shared_delivery_ready",
                    durationMs: Int((manifest.totalDuration * 1_000).rounded()),
                    characterCount: assembly.text.count,
                    sessionID: manifest.id
                )
                await liveActivityCompletionTask?.value
                self.finishSharedSession(keepSharedResult: true)
                self.ensureIdleLiveActivityIfAppropriate(
                    snapshot: self.sharedStore.load()
                )
            } catch {
                guard self.transcriptionAttemptID == attemptID else { return }
                Observability.logTranscriptionFailure(error)
                self.segmentedTranscriptionTask = nil
                self.transcriptionAttemptID = nil
                if let updatedManifest = try? self.segmentedSessionStore.setLifecycle(
                    .failed,
                    sessionID: manifest.id
                ) {
                    self.activeSegmentedSession = updatedManifest
                }
                self.phase = .failed(error.localizedDescription)
                if self.activeSharedSessionID == manifest.id {
                    self.sharedStore.setPhase(
                        .failed,
                        sessionID: manifest.id,
                        errorMessage: error.localizedDescription,
                        hasRecoverableAudio: true,
                        recoveryAction: self.sharedRecoveryAction(for: error)
                    )
                }
                self.endBackgroundExecution()
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func startRealtimeTranscription(
        audioURL: URL,
        sessionID: UUID
    ) {
        cancelRealtimeTranscription()
        guard
            let apiKey = keychain.load(),
            !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }

        let attemptID = UUID()
        let realtime = ElevenLabsRealtimeClient()
        let prefix = sharedStore.load().realtimeTranscript
            ?? continuationStore.state(sessionID: sessionID)?
                .accumulatedTranscript
            ?? ""
        let selectedLanguage = language
        let shouldCleanSpeech = cleanSpeech
        realtimeClient = realtime
        realtimeAttemptID = attemptID
        realtimeSessionID = sessionID
        realtimeStartedAt = Date()
        didLogFirstRealtimeDraft = false
        realtimeDraftIsFinal = false
        Observability.logRealtimeTranscription(
            outcome: "started",
            sessionID: sessionID
        )

        realtimeTask = Task { [weak self] in
            do {
                try await realtime.streamGrowingWave(
                    at: audioURL,
                    apiKey: apiKey,
                    language: selectedLanguage,
                    cleanSpeech: shouldCleanSpeech,
                    prefix: prefix
                ) { [weak self] draft in
                    await self?.publishRealtimeDraft(
                        draft,
                        sessionID: sessionID,
                        attemptID: attemptID
                    )
                }
                guard !Task.isCancelled else { return }
                self?.finishRealtimeAttempt(
                    attemptID: attemptID,
                    sessionID: sessionID,
                    outcome: "finished"
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishRealtimeAttempt(
                    attemptID: attemptID,
                    sessionID: sessionID,
                    outcome: "failed",
                    reason: (error as? ElevenLabsRealtimeError)?
                        .telemetryReason ?? "unknown"
                )
            }
        }
    }

    private func publishRealtimeDraft(
        _ draft: String,
        sessionID: UUID,
        attemptID: UUID
    ) {
        guard
            realtimeAttemptID == attemptID,
            realtimeSessionID == sessionID,
            activeSharedSessionID == sessionID
        else {
            return
        }
        let published = sharedStore.updateRealtimeTranscript(
            draft,
            sessionID: sessionID
        )
        if published, !didLogFirstRealtimeDraft {
            didLogFirstRealtimeDraft = true
            Observability.logRealtimeTranscription(
                outcome: "first_draft",
                sessionID: sessionID,
                characterCount: draft.count,
                durationMs: realtimeStartedAt.map {
                    Int((Date().timeIntervalSince($0) * 1_000).rounded())
                }
            )
        }
    }

    private func finishRealtimeTranscription() {
        guard let realtimeClient else { return }
        Task { await realtimeClient.finish() }
    }

    private func cancelRealtimeTranscription() {
        let client = realtimeClient
        realtimeTask?.cancel()
        realtimeTask = nil
        realtimeClient = nil
        realtimeAttemptID = nil
        realtimeSessionID = nil
        realtimeStartedAt = nil
        didLogFirstRealtimeDraft = false
        realtimeDraftIsFinal = false
        guard let client else { return }
        Task { await client.cancel() }
    }

    private func finishRealtimeAttempt(
        attemptID: UUID,
        sessionID: UUID,
        outcome: String,
        reason: String? = nil
    ) {
        guard realtimeAttemptID == attemptID else { return }
        realtimeDraftIsFinal = outcome == "finished"
        Observability.logRealtimeTranscription(
            outcome: outcome,
            sessionID: sessionID,
            durationMs: realtimeStartedAt.map {
                Int((Date().timeIntervalSince($0) * 1_000).rounded())
            },
            reason: reason
        )
        realtimeTask = nil
        realtimeClient = nil
        realtimeAttemptID = nil
        realtimeSessionID = nil
        realtimeStartedAt = nil
        didLogFirstRealtimeDraft = false
        updateRealtimeDraftSendability()
    }

    private func realtimeDeliveryOwnsSession(sessionID: UUID) -> Bool {
        let snapshot = sharedStore.load()
        return snapshot.sessionID == sessionID
            && snapshot.deliverySource == .realtimeDraft
            && [
                SharedDictationPhase.completed,
                .inserting,
                .deliveryBlocked,
                .inserted,
                .handled,
            ].contains(snapshot.phase)
    }

    /// A batch request for an older continuation may remain in flight while a
    /// newer microphone segment is recording or waiting on disk. Expose the
    /// fast send only when this request owns the final stopped source, so an
    /// early insertion can never omit newer audio or reorder the transcript.
    private func updateRealtimeDraftSendability(
        for source: RecordingTranscriptionSource? = nil
    ) {
        guard let activeSharedSessionID else { return }
        let source = source ?? activeTranscriptionSource
        let isFinalStoppedSource: Bool
        if
            let source,
            !isRecording,
            !isStartingRecording,
            activeRecordingMatches(source),
            let partID = source.continuationPartID,
            let continuation = continuationStore.state(
                sessionID: activeSharedSessionID
            )
        {
            isFinalStoppedSource = realtimeDraftIsFinal
                && continuation.activePartID == partID
                && continuation.pendingPartIDs?.isEmpty != false
        } else {
            isFinalStoppedSource = false
        }
        _ = sharedStore.setRealtimeDraftSendable(
            isFinalStoppedSource,
            sessionID: activeSharedSessionID
        )
    }

    private func startSharedCommandMonitor(sessionID: UUID) {
        sharedMonitorTask?.cancel()
        sharedMonitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard let self, self.activeSharedSessionID == sessionID else { return }

                // Heartbeat so the keyboard can tell a live dictation from one
                // this process no longer owns. Without it a killed app leaves
                // the keyboard showing Listening with no way back.
                tick += 1
                if tick.isMultiple(of: 25) {
                    self.sharedStore.touch(sessionID: sessionID)
                }
                guard self.sharedStore.load().sessionID == sessionID else {
                    continue
                }

                let acceptedCommands: Set<SharedDictationCommand>
                if self.isRecording {
                    acceptedCommands = [.pause, .stop, .cancel]
                } else if self.isPaused {
                    acceptedCommands = [.stop, .cancel]
                } else if case .failed = self.phase,
                          self.hasRecoverableRecording {
                    acceptedCommands = [.retry]
                } else {
                    acceptedCommands = []
                }

                switch self.sharedStore.takePendingCommand(
                    sessionID: sessionID,
                    accepting: acceptedCommands
                ) {
                case .pause where self.isRecording:
                    await self.pauseSharedRecording(
                        expectedSessionID: sessionID
                    )
                case .stop where self.isRecording || self.isPaused:
                    self.stopAndTranscribe()
                case .cancel where self.isRecording || self.isPaused:
                    self.cancelRecording()
                    return
                case .retry where self.hasRecoverableRecording
                    && !self.isTranscribing:
                    self.sharedStore.setPhase(.transcribing, sessionID: sessionID)
                    self.retry()
                default:
                    break
                }
            }
        }
    }

    /// Live Activity intents already execute in the containing app process.
    /// Consume Pause and Cancel before the intent returns instead of relying on
    /// the 120 ms monitor tick. Continue intentionally belongs to the
    /// foreground Control Center OpenIntent, not this background command lane.
    @discardableResult
    func performSharedIntentCommand(
        _ command: SharedDictationCommand,
        expectedSessionID: UUID
    ) async -> Bool {
        guard activeSharedSessionID == expectedSessionID else { return false }
        let pendingCommand = sharedStore.takePendingCommand(
            sessionID: expectedSessionID,
            accepting: [command]
        )
        if pendingCommand != command {
            // The 120 ms monitor can win the race with the App Intent wakeup.
            // Keep the intent's execution window until the command and its
            // ActivityKit update finish.
            guard command == .stop, isTranscribing else { return false }
            await liveActivityUpdateTask?.value
            return true
        }

        switch command {
        case .pause where isRecording:
            guard await pauseSharedRecording(
                expectedSessionID: expectedSessionID
            ) else {
                return false
            }
        case .stop where isRecording || isPaused:
            stopAndTranscribe()
        case .cancel where isRecording || isPaused:
            cancelRecording()
        default:
            return false
        }

        // Keep the system-granted intent execution window until ActivityKit has
        // visibly published the new state (or dismissed the cancelled card).
        await liveActivityUpdateTask?.value
        return true
    }

    private func publishTranscribingState() {
        phase = .transcribing
        guard let activeSharedSessionID else { return }
        _ = sharedStore.setPhase(
            .transcribing,
            sessionID: activeSharedSessionID,
            elapsedDuration: continuationBaseDuration
                + activeRecordingDuration
        )
        updateRealtimeDraftSendability()
        updateKeyboardLiveActivity(
            .transcribing,
            sessionID: activeSharedSessionID,
            elapsedDuration: continuationBaseDuration
                + activeRecordingDuration,
            advancesVisualization: true
        )
        startLiveActivityVisualization(sessionID: activeSharedSessionID)
    }

    private func sharedRecoveryAction(
        for error: Error
    ) -> SharedDictationRecoveryAction {
        if let clientError = error as? ElevenLabsClientError,
           clientError.isRetryable
        {
            return .retryTranscription
        }
        return .openContainingApp
    }

    private func startCaptureLeaseHeartbeat(ownerID: UUID) {
        captureLeaseHeartbeatTask?.cancel()
        captureLeaseHeartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(3))
                } catch {
                    return
                }
                guard
                    let self,
                    self.captureLeaseHeldID == ownerID,
                    self.isRecording || self.isStartingRecording
                else {
                    return
                }
                _ = self.sharedStore.renewCaptureLease(ownerID: ownerID)
            }
        }
    }

    private func releaseCaptureLease() {
        captureLeaseHeartbeatTask?.cancel()
        captureLeaseHeartbeatTask = nil
        guard let captureLeaseHeldID else { return }
        _ = sharedStore.releaseCaptureLease(ownerID: captureLeaseHeldID)
        self.captureLeaseHeldID = nil
    }

    private func finishSharedSession(keepSharedResult: Bool = false) {
        let completedSessionID = activeSharedSessionID
        cancelRealtimeTranscription()
        continuationDeliveryWaitTask?.cancel()
        continuationDeliveryWaitTask = nil
        sharedMonitorTask?.cancel()
        sharedMonitorTask = nil
        stopLiveActivityVisualization()
        activeSharedSessionID = nil
        activeRecordingSessionID = nil
        activeContinuationPartID = nil
        continuationBaseDuration = 0
        isWaitingToContinue = false
        isPreparingKeyboardSession = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        segmentedTranscriptionTask?.cancel()
        segmentedTranscriptionTask = nil
        transcriptionAttemptID = nil
        activeTranscriptionSource = nil
        backgroundContinuationStartupSessionID = nil
        releaseCaptureLease()
        if !keepSharedResult, let completedSessionID {
            sharedStore.reset(sessionID: completedSessionID)
        }
        endBackgroundExecution()
    }

    @discardableResult
    private func beginBackgroundExecution() -> Bool {
        endBackgroundExecution()
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "Finish Dictation Button transcription"
        ) { [weak self] in
            MainActor.assumeIsolated {
                self?.expireBackgroundTranscription()
            }
        }
        return backgroundTaskID != .invalid
    }

    private func surfaceBackgroundTranscriptionUnavailable() {
        let message = "iOS couldn't reserve enough background time to transcribe. The recording is saved; retry in Dictation Button."
        phase = .failed(message)
        if let activeSharedSessionID {
            _ = sharedStore.setPhase(
                .failed,
                sessionID: activeSharedSessionID,
                errorMessage: message,
                hasRecoverableAudio: true,
                recoveryAction: .retryTranscription
            )
            endKeyboardLiveActivity(
                .failed,
                sessionID: activeSharedSessionID
            )
        }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func expireBackgroundTranscription() {
        guard transcriptionAttemptID != nil else {
            endBackgroundExecution()
            return
        }

        let expiringTaskID = backgroundTaskID
        let retainedSource = activeTranscriptionSource
        let newerCaptureIsLive = retainedSource.map {
            !activeRecordingMatches($0)
                && (isRecording || isStartingRecording)
        } ?? false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        segmentedTranscriptionTask?.cancel()
        segmentedTranscriptionTask = nil
        transcriptionAttemptID = nil
        if newerCaptureIsLive {
            showRecordingNotice(
                "The previous segment will retry when you Send or Pause. This recording is still listening."
            )
            Observability.logDictationContinuation(
                event: "prior_segment_transcription",
                outcome: "background_window_expired_while_recording"
            )
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            endBackgroundExecution(expected: expiringTaskID)
            return
        }
        let message = "iOS ended the background transcription window. The recording is saved; retry in Dictation Button."
        phase = .failed(message)
        if let activeSegmentedSession,
           let failedManifest = try? segmentedSessionStore.setLifecycle(
               .failed,
               sessionID: activeSegmentedSession.id
           )
        {
            self.activeSegmentedSession = failedManifest
        }
        if let activeSharedSessionID {
            _ = sharedStore.setPhase(
                .failed,
                sessionID: activeSharedSessionID,
                errorMessage: message,
                hasRecoverableAudio: true,
                recoveryAction: .retryTranscription
            )
            endKeyboardLiveActivity(
                .failed,
                sessionID: activeSharedSessionID
            )
        }
        sharedMonitorTask?.cancel()
        sharedMonitorTask = nil
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        endBackgroundExecution(expected: expiringTaskID)
    }

    private func endBackgroundExecution(
        expected taskID: UIBackgroundTaskIdentifier? = nil
    ) {
        if let taskID, backgroundTaskID != taskID { return }
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func finalizeProtectedRecording(
        at finalizedURL: URL?,
        duration: TimeInterval
    ) -> URL? {
        guard let finalizedURL else { return nil }
        if let activeRecordingCapture {
            do {
                let entry = try recordingJournal.finalizeCapture(
                    activeRecordingCapture,
                    duration: duration
                )
                let protectedURL = try recordingJournal.audioURL(for: entry)
                activeRecordingJournalEntry = entry
                self.activeRecordingCapture = nil
                return protectedURL
            } catch {
                // This URL already lives in the journal's private Active area.
                // Keep it and its capture token so relaunch adoption can retry.
                showRecordingNotice(
                    "The recovery recording is safe, but its index could not be finalized yet. Keep Dictation Button open while it retries."
                )
                return finalizedURL
            }
        }
        if activeRecordingJournalEntry != nil {
            return activeRecordingURL ?? finalizedURL
        }

        do {
            let entry = try recordingJournal.stageRecording(
                at: finalizedURL,
                id: activeRecordingSessionID ?? activeSharedSessionID ?? UUID(),
                duration: duration
            )
            let protectedURL = try recordingJournal.audioURL(for: entry)
            activeRecordingJournalEntry = entry
            if finalizedURL.standardizedFileURL != protectedURL.standardizedFileURL {
                try? FileManager.default.removeItem(at: finalizedURL)
            }
            return protectedURL
        } catch {
            showRecordingNotice(
                "Dictation Button couldn't create its recovery copy. Keep the app open while this recording transcribes."
            )
            return finalizedURL
        }
    }

    private func consumeActiveRecording() {
        if let activeRecordingCapture {
            if let entry = try? recordingJournal.finalizeCapture(
                activeRecordingCapture,
                duration: activeRecordingDuration
            ) {
                try? recordingJournal.consume(entry)
            }
        } else if let activeRecordingJournalEntry {
            try? recordingJournal.consume(activeRecordingJournalEntry)
        } else if let activeRecordingURL {
            try? FileManager.default.removeItem(at: activeRecordingURL)
        }
        clearActiveRecordingReference()
    }

    private func activeRecordingMatches(
        _ source: RecordingTranscriptionSource
    ) -> Bool {
        if let sourceEntry = source.journalEntry {
            return activeRecordingJournalEntry?.id == sourceEntry.id
        }
        if let sourceCapture = source.capture {
            return activeRecordingCapture?.id == sourceCapture.id
        }
        return activeRecordingURL?.standardizedFileURL
            == source.audioURL.standardizedFileURL
    }

    /// Releases only AppModel's pointers to an in-flight source. Its journal
    /// entry stays protected and the request closure remains its exact owner.
    private func detachActiveRecording(
        matching source: RecordingTranscriptionSource
    ) {
        guard activeRecordingMatches(source) else { return }
        activeRecordingURL = nil
        activeRecordingCapture = nil
        activeRecordingJournalEntry = nil
        activeRecordingDuration = 0
        activeContinuationPartID = nil
    }

    /// Retires the exact bytes that produced one response. A newer continuation
    /// may already occupy the ordinary active-recording fields, so completion
    /// must never consume those fields by accident.
    private func consumeTranscriptionSource(
        _ source: RecordingTranscriptionSource
    ) {
        if let capture = source.capture {
            if let entry = try? recordingJournal.finalizeCapture(
                capture,
                duration: source.duration
            ) {
                try? recordingJournal.consume(entry)
            }
        } else if let entry = source.journalEntry {
            try? recordingJournal.consume(entry)
        } else {
            try? FileManager.default.removeItem(at: source.audioURL)
        }
        if activeRecordingMatches(source) {
            clearActiveRecordingReference()
        }
    }

    @discardableResult
    private func discardTranscriptionSource(
        _ source: RecordingTranscriptionSource
    ) -> Bool {
        do {
            if let capture = source.capture {
                let entry = try recordingJournal.finalizeCapture(
                    capture,
                    duration: source.duration
                )
                try recordingJournal.discard(entry)
            } else if let entry = source.journalEntry {
                try recordingJournal.discard(entry)
            } else if FileManager.default.fileExists(atPath: source.audioURL.path) {
                try FileManager.default.removeItem(at: source.audioURL)
            }
        } catch {
            phase = .failed(
                "Dictation Button couldn't discard the recovery recording: \(error.localizedDescription)"
            )
            return false
        }
        if activeRecordingMatches(source) {
            clearActiveRecordingReference()
        }
        if activeTranscriptionSource?.audioURL.standardizedFileURL
            == source.audioURL.standardizedFileURL
        {
            activeTranscriptionSource = nil
        }
        return true
    }

    @discardableResult
    private func discardAllActiveRecordingSources() -> Bool {
        let retainedSource = activeTranscriptionSource
        let retainedMatchesActive = retainedSource.map(activeRecordingMatches)
            ?? false
        let hadActiveRecordingReference = activeRecordingURL != nil
            || activeRecordingCapture != nil
            || activeRecordingJournalEntry != nil

        if hadActiveRecordingReference {
            guard discardActiveRecording() else { return false }
        }
        if
            let retainedSource,
            !(retainedMatchesActive && hadActiveRecordingReference)
        {
            guard discardTranscriptionSource(retainedSource) else {
                return false
            }
        }
        activeTranscriptionSource = nil
        return true
    }

    @discardableResult
    private func discardContinuationJournalEntries(
        sessionID: UUID
    ) -> Bool {
        let continuation = continuationStore.state(sessionID: sessionID)
        let partIDs = Set(
            (continuation?.pendingPartIDs ?? [])
                + [continuation?.activePartID].compactMap { $0 }
                + [sessionID]
        )
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        guard let entries = try? recordingJournal.recoverableEntries() else {
            phase = .failed(
                "Dictation Button couldn't inspect all continuation recordings before discarding them. Retry Discard."
            )
            return false
        }
        for entry in entries where partIDs.contains(entry.id) {
            do {
                try recordingJournal.discard(entry)
            } catch RecordingJournalError.recordMissing {
                continue
            } catch {
                phase = .failed(
                    "Dictation Button couldn't discard every continuation recording: \(error.localizedDescription)"
                )
                return false
            }
        }
        return true
    }

    private func archiveAudioDiagnostics(
        sources: [AudioDiagnosticSource],
        historyID: UUID,
        createdAt: Date,
        duration: TimeInterval,
        quality: AudioCaptureQualitySummary,
        microphoneMode: AudioMicrophoneModeSnapshot,
        languageProbability: Double?
    ) {
        do {
            let record = try audioDiagnostics.archive(
                sources,
                historyID: historyID,
                createdAt: createdAt,
                duration: duration,
                quality: quality,
                microphoneMode: microphoneMode,
                languageProbability: languageProbability
            )
            pruneAudioDiagnosticsToHistory()
            Observability.logAudioDiagnosticRetained(record)
        } catch let error as AudioDiagnosticsStoreError {
            Observability.logAudioDiagnosticArchiveFailure(
                reason: error.safeReason
            )
        } catch {
            Observability.logAudioDiagnosticArchiveFailure(reason: "storage")
        }
    }

    @discardableResult
    private func discardActiveRecording() -> Bool {
        do {
            if let activeRecordingCapture {
                let entry = try recordingJournal.finalizeCapture(
                    activeRecordingCapture,
                    duration: activeRecordingDuration
                )
                try recordingJournal.discard(entry)
            } else if let activeRecordingJournalEntry {
                try recordingJournal.discard(activeRecordingJournalEntry)
            } else if let activeRecordingURL {
                try FileManager.default.removeItem(at: activeRecordingURL)
            }
        } catch {
            phase = .failed(
                "Dictation Button couldn't discard the recovery recording: \(error.localizedDescription)"
            )
            return false
        }
        clearActiveRecordingReference()
        return true
    }

    @discardableResult
    private func discardActiveSegmentedSession() -> Bool {
        guard let manifest = activeSegmentedSession else { return false }
        do {
            try retireSegmentedSession(
                manifest,
                entries: recordingJournal.recoverableEntries(),
                discarding: true
            )
            return true
        } catch {
            phase = .failed(
                "Dictation Button couldn't discard the segmented recovery recording: \(error.localizedDescription)"
            )
            return false
        }
    }

    private func retireSegmentedSession(
        _ manifest: SegmentedDictationSessionManifest,
        entries: [RecordingJournalEntry],
        discarding: Bool
    ) throws {
        let entriesByID = Dictionary(uniqueKeysWithValues: entries.map {
            ($0.id, $0)
        })
        var firstError: (any Error)?
        for segment in manifest.orderedSegments {
            guard let entry = entriesByID[segment.id] else {
                // A prior cleanup pass already retired this child.
                continue
            }
            do {
                if discarding {
                    try recordingJournal.discard(entry)
                } else {
                    try recordingJournal.consume(entry)
                }
            } catch RecordingJournalError.recordMissing {
                continue
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
        try segmentedSessionStore.delete(sessionID: manifest.id)
        if activeSegmentedSession?.id == manifest.id {
            activeSegmentedSession = nil
        }
    }

    private func clearActiveRecordingReference() {
        activeRecordingURL = nil
        activeRecordingCapture = nil
        activeRecordingJournalEntry = nil
        activeRecordingDuration = 0
        activeContinuationPartID = nil
    }

    private func continuationRecoveryEntry(
        partID: UUID,
        sessionID: UUID,
        entries: [RecordingJournalEntry],
        allowsLegacySessionIdentity: Bool
    ) -> RecordingJournalEntry? {
        if let exact = entries.first(where: { $0.id == partID }) {
            return exact
        }
        guard allowsLegacySessionIdentity else { return nil }
        // Builds before per-part journal identities stored the first keyboard
        // segment under its parent session ID. Keep that one-way migration
        // readable without ever guessing between two modern child entries.
        return entries.first(where: { $0.id == sessionID })
    }

    /// After a recovered pending part banks, load the next durable part before
    /// publishing anything. Runtime overlap already leaves this part in the
    /// ordinary active fields; this path provides the same ordering guarantee
    /// after process death.
    @discardableResult
    private func restoreNextContinuationPartIfAvailable(
        sessionID: UUID
    ) -> Bool {
        guard
            activeRecordingURL == nil,
            let continuation = continuationStore.state(sessionID: sessionID),
            let partID = continuation.activePartID
        else {
            return false
        }
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        guard
            let entries = try? recordingJournal.recoverableEntries(),
            let entry = continuationRecoveryEntry(
                partID: partID,
                sessionID: sessionID,
                entries: entries,
                allowsLegacySessionIdentity: true
            ),
            let url = try? recordingJournal.audioURL(for: entry)
        else {
            return false
        }
        activeRecordingJournalEntry = entry
        activeRecordingURL = url
        activeRecordingDuration = entry.duration
        activeRecordingSessionID = sessionID
        activeContinuationPartID = partID
        continuationBaseDuration = continuation.accumulatedDuration
        return true
    }

    private func restoreOldestRecoverableRecording(
        preferredSessionID: UUID? = nil
    ) {
        recoveryRecheckTask?.cancel()
        recoveryRecheckTask = nil
        if
            let preferredSessionID,
            hasRecoverableRecording,
            activeRecordingSessionID != preferredSessionID
                && activeSegmentedSession?.id != preferredSessionID,
            activeSharedSessionID == nil,
            !isRecording,
            !isTranscribing
        {
            // The existing recovery bundle stays in the journal. A targeted
            // keyboard Retry may safely put its own session in front without
            // deleting or consuming the older standalone recording.
            clearActiveRecordingReference()
            activeSegmentedSession = nil
            activeRecordingSessionID = nil
        }
        guard
            activeRecordingURL == nil,
            activeSegmentedSession == nil,
            !isRecording,
            !isTranscribing
        else {
            return
        }
        // A stopped recorder may have persisted writer-release proof but lost
        // the final Active -> Entries rename. Adoption is safe to repeat: it
        // refuses live writers and makes an existing scene recover immediately.
        _ = try? recordingJournal.adoptCrashLeftCaptures()
        guard var entries = try? recordingJournal.recoverableEntries() else {
            return
        }

        let shared = sharedStore.load()
        if shared.phase == .paused {
            // A keyboard pause boundary owns no microphone, but its banked
            // transcript ledger must remain adoptable after process death. If
            // the closed segment has not finished transcribing, restore only
            // that exact journal entry so Control Center can bank it before
            // starting the next segment.
            if
                shared.sessionKind == .keyboardRoundTrip,
                let continuation = continuationStore.state(
                    sessionID: shared.sessionID
                ),
                continuation.pausedBoundaryActive == true
            {
                activeSharedSessionID = shared.sessionID
                activeRecordingSessionID = shared.sessionID
                let recoveryPartID = continuation.pendingPartIDs?.first
                    ?? continuation.activePartID
                activeContinuationPartID = recoveryPartID
                continuationBaseDuration = max(
                    continuation.accumulatedDuration,
                    max(0, shared.elapsedDuration ?? 0)
                )
                phase = .paused
                if
                    let recoveryPartID,
                    let entry = continuationRecoveryEntry(
                        partID: recoveryPartID,
                        sessionID: shared.sessionID,
                        entries: entries,
                        allowsLegacySessionIdentity: true
                    ),
                    let url = try? recordingJournal.audioURL(for: entry)
                {
                    activeRecordingJournalEntry = entry
                    activeRecordingURL = url
                    activeRecordingDuration = entry.duration
                }
                startSharedCommandMonitor(sessionID: shared.sessionID)
            }
            return
        }
        if
            [.starting, .recording, .transcribing]
                .contains(shared.phase),
            Date().timeIntervalSince(shared.updatedAt) < 15
        {
            // A background engine currently owns recording/transcription. Do
            // not surface any journal entry beneath its live work.
            let age = max(0, Date().timeIntervalSince(shared.updatedAt))
            recoveryRecheckTask = Task { [weak self] in
                try? await Task.sleep(
                    for: .seconds(max(0.5, 15.1 - age))
                )
                guard !Task.isCancelled, let self else { return }
                self.restoreOldestRecoverableRecording(
                    preferredSessionID: shared.sessionID
                )
            }
            return
        }

        if
            shared.sessionKind == .keyboardRoundTrip,
            let continuation = continuationStore.state(
                sessionID: shared.sessionID
            )
        {
            let recoveryPartIDs = (continuation.pendingPartIDs ?? [])
                + [continuation.activePartID].compactMap { $0 }
            for (index, partID) in recoveryPartIDs.enumerated() {
                guard
                    let entry = continuationRecoveryEntry(
                        partID: partID,
                        sessionID: shared.sessionID,
                        entries: entries,
                        allowsLegacySessionIdentity: index == 0
                    ),
                    let url = try? recordingJournal.audioURL(for: entry)
                else {
                    continue
                }
                let message = "An interrupted continuation was recovered. Retry transcription or discard its protected audio."
                activeRecordingJournalEntry = entry
                activeRecordingURL = url
                activeRecordingDuration = entry.duration
                activeRecordingSessionID = shared.sessionID
                activeSharedSessionID = shared.sessionID
                activeContinuationPartID = partID
                continuationBaseDuration = continuation.accumulatedDuration
                _ = sharedStore.setPhase(
                    .failed,
                    sessionID: shared.sessionID,
                    errorMessage: message,
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription,
                    elapsedDuration: max(
                        continuation.accumulatedDuration,
                        max(0, shared.elapsedDuration ?? 0)
                    )
                )
                phase = .failed(message)
                startSharedCommandMonitor(sessionID: shared.sessionID)
                return
            }
        }

        var manifests = (try? segmentedSessionStore.allManifests()) ?? []
        for manifest in manifests where manifest.activeCapture != nil {
            _ = try? segmentedSessionStore.adoptFinalizedActiveCapture(
                sessionID: manifest.id,
                from: entries
            )
            if
                let refreshed = try? segmentedSessionStore.load(
                    sessionID: manifest.id
                ),
                let activeCapture = refreshed.activeCapture,
                (try? recordingJournal.abandonCrashLeftEmptyCapture(
                    id: activeCapture.id
                )) == true
            {
                _ = try? segmentedSessionStore.clearEmptyActiveCapture(
                    sessionID: manifest.id,
                    captureID: activeCapture.id,
                    ordinal: activeCapture.ordinal,
                    lifecycle: refreshed.segments.isEmpty
                        ? .failed
                        : .paused
                )
            }
        }
        manifests = (try? segmentedSessionStore.allManifests()) ?? manifests
        if let preferredSessionID,
           let preferredIndex = manifests.firstIndex(where: {
               $0.id == preferredSessionID
           })
        {
            let preferred = manifests.remove(at: preferredIndex)
            manifests.insert(preferred, at: 0)
        }

        for manifest in manifests {
            let committed = history.items.first {
                $0.sourceSessionID == manifest.id
            }
            let sharedOwnsParent = shared.sessionID == manifest.id
            let sharedCompleted = sharedOwnsParent
                && [.completed, .inserting, .deliveryBlocked, .inserted, .handled]
                    .contains(shared.phase)
            if manifest.lifecycle == .completed {
                try? retireSegmentedSession(
                    manifest,
                    entries: entries,
                    discarding: false
                )
                continue
            }
            if let committed {
                if sharedOwnsParent,
                   [.recording, .paused, .transcribing, .failed, .cancelled]
                    .contains(shared.phase)
                {
                    sharedStore.setPhase(
                        .completed,
                        sessionID: manifest.id,
                        transcript: committed.text,
                        historyPersisted: true,
                        hasRecoverableAudio: false
                    )
                }
                try? retireSegmentedSession(
                    manifest,
                    entries: entries,
                    discarding: false
                )
                continue
            }
            if sharedCompleted {
                try? retireSegmentedSession(
                    manifest,
                    entries: entries,
                    discarding: false
                )
                continue
            }
            if manifest.activeCapture == nil, manifest.segments.isEmpty {
                if sharedOwnsParent {
                    if [.starting, .recording, .transcribing]
                        .contains(shared.phase)
                    {
                        _ = sharedStore.transitionPhase(
                            from: [shared.phase],
                            to: .failed,
                            sessionID: manifest.id,
                            errorMessage: "Dictation stopped before any audio was captured. Try again.",
                            hasRecoverableAudio: false
                        )
                    } else {
                        sharedStore.setPhase(
                            .failed,
                            sessionID: manifest.id,
                            errorMessage: "Dictation stopped before any audio was captured. Try again.",
                            hasRecoverableAudio: false
                        )
                    }
                }
                try? segmentedSessionStore.delete(sessionID: manifest.id)
                continue
            }
            guard manifest.activeCapture == nil, !manifest.segments.isEmpty else {
                continue
            }

            if sharedOwnsParent,
               [.starting, .recording, .transcribing].contains(shared.phase)
            {
                guard sharedStore.transitionPhase(
                    from: [shared.phase],
                    to: .failed,
                    sessionID: manifest.id,
                    errorMessage: "A segmented dictation was recovered. Retry transcription or discard all of its audio.",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                ) else {
                    // A background App Intent won the same recovery race and
                    // now owns this parent. Do not expose stale Retry/Discard.
                    return
                }
            }

            activeSegmentedSession = manifest
            activeRecordingSessionID = manifest.id
            if sharedOwnsParent {
                activeSharedSessionID = manifest.id
                sharedStore.setPhase(
                    .failed,
                    sessionID: manifest.id,
                    errorMessage: "A segmented dictation was recovered. Retry transcription or discard all of its audio.",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                )
                startSharedCommandMonitor(sessionID: manifest.id)
            }
            phase = .failed(
                "A segmented dictation was recovered. Retry transcription or discard all of its audio."
            )
            return
        }

        let groupedChildIDs = Set(
            ((try? segmentedSessionStore.allManifests()) ?? [])
                .flatMap { manifest in
                    manifest.segments.map(\.id)
                        + [manifest.activeCapture?.id].compactMap { $0 }
                }
        )
        entries.removeAll { groupedChildIDs.contains($0.id) }
        let orderedEntries: [RecordingJournalEntry]
        if let preferredSessionID,
           let preferred = entries.first(where: { $0.id == preferredSessionID })
        {
            orderedEntries = [preferred] + entries.filter {
                $0.id != preferredSessionID
            }
        } else {
            orderedEntries = entries
        }
        for entry in orderedEntries {
            if let committed = history.items.first(where: {
                $0.sourceSessionID == entry.id
            }) {
                if shared.sessionID == entry.id,
                   [.recording, .paused, .transcribing, .failed]
                    .contains(shared.phase)
                {
                    sharedStore.setPhase(
                        .completed,
                        sessionID: entry.id,
                        transcript: committed.text,
                        historyPersisted: true
                    )
                }
                try? recordingJournal.consume(entry)
                continue
            }
            if shared.sessionID == entry.id,
               [.completed, .inserting, .deliveryBlocked, .inserted, .handled]
                    .contains(shared.phase)
            {
                try? recordingJournal.consume(entry)
                continue
            }
            guard let url = try? recordingJournal.audioURL(for: entry) else {
                continue
            }

            activeRecordingJournalEntry = entry
            activeRecordingURL = url
            activeRecordingDuration = entry.duration
            activeRecordingSessionID = entry.id
            if shared.sessionID == entry.id {
                activeSharedSessionID = entry.id
                let continuationState = continuationStore.state(
                    sessionID: entry.id
                )
                activeContinuationPartID = continuationState?.activePartID
                continuationBaseDuration = continuationState?
                    .accumulatedDuration ?? 0
                sharedStore.setPhase(
                    .failed,
                    sessionID: entry.id,
                    errorMessage: "An interrupted recording was recovered. Retry transcription or discard the audio.",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                )
                startSharedCommandMonitor(sessionID: entry.id)
            }
            phase = .failed(
                "An interrupted recording was recovered. Retry transcription or discard the audio."
            )
            return
        }
    }

    private func handleRecorderEvent(_ event: AudioRecorderEvent) {
        switch event {
        case let .noAudioDetected(elapsed):
            let microphoneMode = recorder.microphoneModeSnapshot
            Observability.logSilentCapture(
                surface: isKeyboardDictation
                    ? "keyboard_round_trip"
                    : "ios_containing_app",
                action: "persistent_silence",
                elapsedMs: Int((elapsed * 1_000).rounded()),
                quality: recorder.captureQualitySummary,
                preferredMicrophoneMode: microphoneMode.preferred,
                activeMicrophoneMode: microphoneMode.active
            )
            showRecordingNotice(
                "No voice detected after \(Int(elapsed)) seconds. Check the microphone and speak a little closer."
            )
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .maximumDurationApproaching(remaining):
            showRecordingNotice(
                "\(Int(remaining.rounded())) seconds remaining. Dictation Button will stop and transcribe automatically."
            )
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case let .maximumDurationReached(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Five-minute limit reached. Transcribing now."
            )
        case let .interruptionBegan(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Recording was interrupted. Transcribing what was captured."
            )
        case let .routeChanged(change):
            if let finalizedURL = change.finalizedRecordingURL {
                finalizeRecordingAfterSystemStop(
                    finalizedURL,
                    notice: "The microphone disconnected. Transcribing what was captured."
                )
            }
        case let .recordingEndedUnexpectedly(finalizedURL):
            finalizeRecordingAfterSystemStop(
                finalizedURL,
                notice: "Recording stopped unexpectedly. Transcribing what was captured."
            )
        case .interruptionEnded:
            break
        }
    }

    private func finalizeRecordingAfterSystemStop(
        _ finalizedURL: URL?,
        notice: String
    ) {
        guard isRecording else { return }
        recordingNoticeTask?.cancel()
        recordingNotice = notice
        activeRecordingDuration = recorder.duration
        finishRealtimeTranscription()
        releaseCaptureLease()
        activeRecordingURL = finalizeProtectedRecording(
            at: finalizedURL ?? activeRecordingURL,
            duration: activeRecordingDuration
        )
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard beginBackgroundExecution() else {
            surfaceBackgroundTranscriptionUnavailable()
            return
        }
        transcribeActiveRecording()
    }

    private func showRecordingNotice(_ message: String) {
        recordingNoticeTask?.cancel()
        recordingNotice = message
        recordingNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.recordingNotice = nil
        }
    }

    private func showCopiedConfirmation() {
        copiedTask?.cancel()
        copiedRecently = true
        copiedTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.copiedRecently = false
        }
    }
}

/// Continuation metadata remains separate from the shared delivery snapshot.
/// This sidecar takes the exact same state-file lock whenever it arbitrates with
/// keyboard insertion, so batch completion, the explicitly approved realtime
/// claim, and a Control Center continuation still have one deterministic winner.
struct SharedDictationContinuationState: Codable, Equatable, Sendable {
    let sessionID: UUID
    var accumulatedTranscript: String
    var accumulatedDuration: TimeInterval
    var continuationRequested: Bool
    var activePartID: UUID?
    var bankedPartIDs: [UUID]
    /// Optional so ledgers written by pre-boundary builds remain decodable.
    var pausedBoundaryActive: Bool? = nil
    /// A finalized part whose Scribe request may finish while the next part is
    /// already recording. Optional preserves ledgers written by earlier builds.
    var pendingPartIDs: [UUID]? = nil

    static func empty(sessionID: UUID) -> Self {
        SharedDictationContinuationState(
            sessionID: sessionID,
            accumulatedTranscript: "",
            accumulatedDuration: 0,
            continuationRequested: false,
            activePartID: nil,
            bankedPartIDs: [],
            pausedBoundaryActive: false,
            pendingPartIDs: []
        )
    }
}

struct SharedDictationContinuationAssembly: Equatable, Sendable {
    let text: String
    let duration: TimeInterval
}

struct SharedDictationContinuationLaunch: Equatable {
    let snapshot: SharedDictationSnapshot
    let assembly: SharedDictationContinuationAssembly
}

struct SharedDictationImmediateContinuationLaunch: Equatable {
    let snapshot: SharedDictationSnapshot
    let priorPartID: UUID
    let nextPartID: UUID
    let elapsedDuration: TimeInterval
}

struct SharedDictationImmediateContinuationRollback: Equatable {
    let priorPartID: UUID
    let elapsedDuration: TimeInterval
}

enum SharedDictationPausedContinuationRequest: Equatable {
    case waitingForTranscript
    case launch(SharedDictationContinuationLaunch)
    case unavailable
}

enum SharedDictationPausedPartCompletion: Equatable {
    case waiting(SharedDictationContinuationAssembly)
    case launch(SharedDictationContinuationLaunch)
    case finishing(SharedDictationContinuationAssembly)
    case storageFailed
}

struct SharedDictationContinuationStore: @unchecked Sendable {
    private static let ledgerFileName = "dictation-continuation-v1.json"
    private static let ledgerDefaultsKey = "dictation-continuation-v1"

    private let defaults: UserDefaults?
    private let storageDirectory: URL?

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageDirectory: URL? = nil
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if suiteName == SharedDictationConstants.appGroupIdentifier {
            self.storageDirectory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        } else {
            self.storageDirectory = nil
        }
    }

    func state(sessionID: UUID) -> SharedDictationContinuationState? {
        withMainStateLock {
            guard let state = loadLedgerUnlocked(), state.sessionID == sessionID else {
                return nil
            }
            return state
        } ?? nil
    }

    /// Persist a stable part identity before AVFoundation starts. A retry after
    /// process death can therefore recognize text already banked just before a
    /// state-file transition and never append that same audio twice.
    func registerPart(sessionID: UUID) -> UUID? {
        withMainStateLock {
            let snapshot = loadMainSnapshotUnlocked()
            guard snapshot.sessionID == sessionID else { return nil }
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            let partID = UUID()
            state.activePartID = partID
            state.continuationRequested = false
            state.pausedBoundaryActive = false
            guard saveLedgerUnlocked(state) else { return nil }
            return partID
        } ?? nil
    }

    /// Atomically turns the hot keyboard recording into a microphone-free
    /// resting state. The AppModel closes and protects the file before calling
    /// this method, so the shared snapshot cannot advertise Pause while audio
    /// is still being appended.
    func beginPausedBoundary(
        sessionID: UUID,
        elapsedDuration: TimeInterval
    ) -> Bool {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .recording,
                state.activePartID != nil
            else {
                return false
            }

            let previousState = state
            state.continuationRequested = false
            state.pausedBoundaryActive = true
            guard saveLedgerUnlocked(state) else { return false }

            snapshot.phase = .paused
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = true
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            snapshot.elapsedDuration = max(0, elapsedDuration)
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                return false
            }
            return true
        } ?? false
    }

    /// Records a foreground Control Center continuation request. If the pause
    /// segment is already banked, this claims the next capture immediately;
    /// otherwise the transcript completion owns that transition.
    func requestPausedContinuation(
        sessionID: UUID
    ) -> SharedDictationPausedContinuationRequest {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .paused,
                snapshot.command == .none,
                state.pausedBoundaryActive == true
            else {
                return .unavailable
            }

            if state.activePartID != nil {
                state.continuationRequested = true
                guard saveLedgerUnlocked(state) else { return .unavailable }
                return .waitingForTranscript
            }

            guard !state.bankedPartIDs.isEmpty else { return .unavailable }
            let previousState = state
            state.continuationRequested = false
            state.pausedBoundaryActive = false
            guard saveLedgerUnlocked(state) else { return .unavailable }

            snapshot.phase = .launching
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = false
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            snapshot.elapsedDuration = state.accumulatedDuration
            snapshot.startedAt = Date()
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                return .unavailable
            }
            return .launch(
                SharedDictationContinuationLaunch(
                    snapshot: snapshot,
                    assembly: SharedDictationContinuationAssembly(
                        text: state.accumulatedTranscript,
                        duration: state.accumulatedDuration
                    )
                )
            )
        } ?? .unavailable
    }

    /// Claims the next microphone segment before the previous Scribe request
    /// finishes. The prior and next identities move together under the same
    /// App Group lock, so a fast swipe can never strand a shared `.starting`
    /// state with no durable owner for either audio file.
    func beginImmediateContinuation(
        sessionID: UUID,
        expectedPriorPartID: UUID
    ) -> SharedDictationImmediateContinuationLaunch? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                [.paused, .transcribing].contains(snapshot.phase),
                snapshot.command == .none,
                let priorPartID = state.activePartID,
                priorPartID == expectedPriorPartID,
                state.pendingPartIDs?.isEmpty != false
            else {
                return nil
            }
            if snapshot.phase == .paused {
                guard state.pausedBoundaryActive == true else { return nil }
            }

            let previousState = state
            let previousSnapshot = snapshot
            let nextPartID = UUID()
            state.pendingPartIDs = [priorPartID]
            state.activePartID = nextPartID
            state.continuationRequested = false
            state.pausedBoundaryActive = false
            guard saveLedgerUnlocked(state) else { return nil }

            let elapsedDuration = max(
                state.accumulatedDuration,
                max(0, snapshot.elapsedDuration ?? 0)
            )
            snapshot.phase = .launching
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = true
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            snapshot.elapsedDuration = elapsedDuration
            snapshot.startedAt = Date()
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                _ = saveMainSnapshotUnlocked(previousSnapshot)
                return nil
            }
            return SharedDictationImmediateContinuationLaunch(
                snapshot: snapshot,
                priorPartID: priorPartID,
                nextPartID: nextPartID,
                elapsedDuration: elapsedDuration
            )
        } ?? nil
    }

    /// Banks the older part without changing the phase owned by the newer hot
    /// capture. Only the exact pending identity can advance the transcript
    /// prefix, and replaying the same completion is harmless.
    func bankImmediateContinuationPart(
        sessionID: UUID,
        partID: UUID,
        transcript: String,
        duration: TimeInterval,
        historyPersisted: Bool
    ) -> SharedDictationContinuationAssembly? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                state.pendingPartIDs?.contains(partID) == true
            else {
                return nil
            }

            let previousState = state
            let assembly = assembled(
                state: state,
                partID: partID,
                transcript: transcript,
                duration: duration
            )
            if !state.bankedPartIDs.contains(partID) {
                state.bankedPartIDs.append(partID)
            }
            state.accumulatedTranscript = assembly.text
            state.accumulatedDuration = assembly.duration
            state.pendingPartIDs?.removeAll { $0 == partID }
            guard saveLedgerUnlocked(state) else { return nil }

            snapshot.historyPersisted = historyPersisted
            snapshot.hasRecoverableAudio = true
            snapshot.elapsedDuration = max(
                assembly.duration,
                max(0, snapshot.elapsedDuration ?? 0)
            )
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                return nil
            }
            return assembly
        } ?? nil
    }

    /// Cancels only the newer microphone part while its predecessor is still
    /// transcribing. Ownership moves back to that protected predecessor under
    /// the shared lock so its eventual completion can still be delivered.
    func abandonImmediateContinuation(
        sessionID: UUID,
        abandonedPartID: UUID,
        priorPartID: UUID,
        elapsedDuration: TimeInterval
    ) -> SharedDictationImmediateContinuationRollback? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                state.activePartID == abandonedPartID,
                state.pendingPartIDs?.contains(priorPartID) == true
            else {
                return nil
            }

            let previousState = state
            state.activePartID = priorPartID
            state.pendingPartIDs?.removeAll { $0 == priorPartID }
            state.continuationRequested = false
            state.pausedBoundaryActive = false
            guard saveLedgerUnlocked(state) else { return nil }

            let restoredElapsed = max(
                state.accumulatedDuration,
                max(0, elapsedDuration)
            )
            snapshot.phase = .transcribing
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = true
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            snapshot.elapsedDuration = restoredElapsed
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                return nil
            }
            return SharedDictationImmediateContinuationRollback(
                priorPartID: priorPartID,
                elapsedDuration: restoredElapsed
            )
        } ?? nil
    }

    /// Banks the file closed by Pause. A Control Center request that arrived
    /// during transcription wins only after the ledger is durable. A keyboard
    /// Send that arrived meanwhile leaves the snapshot transcribing so the
    /// caller can publish the full ordered assembly immediately.
    func completePausedPart(
        sessionID: UUID,
        partID: UUID,
        transcript: String,
        duration: TimeInterval,
        historyPersisted: Bool
    ) -> SharedDictationPausedPartCompletion? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                [.paused, .transcribing].contains(snapshot.phase),
                state.pausedBoundaryActive == true,
                state.activePartID == partID
            else {
                return nil
            }

            let previousState = state
            let assembly = assembled(
                state: state,
                partID: partID,
                transcript: transcript,
                duration: duration
            )
            if !state.bankedPartIDs.contains(partID) {
                state.bankedPartIDs.append(partID)
            }
            state.accumulatedTranscript = assembly.text
            state.accumulatedDuration = assembly.duration
            if state.activePartID == partID {
                state.activePartID = nil
            }

            // A keyboard Send can land in the same cross-process window as
            // Pause. Preserve that command at the boundary and let it win over
            // a later Control Center press instead of silently discarding the
            // user's insertion request.
            let shouldFinish = snapshot.phase == .transcribing
                || snapshot.command == .stop
            let shouldLaunch = !shouldFinish && state.continuationRequested
            if shouldFinish || shouldLaunch {
                state.continuationRequested = false
                state.pausedBoundaryActive = false
            }
            guard saveLedgerUnlocked(state) else { return .storageFailed }

            snapshot.historyPersisted = historyPersisted
            snapshot.hasRecoverableAudio = false
            snapshot.elapsedDuration = assembly.duration
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            if shouldFinish {
                snapshot.phase = .transcribing
                snapshot.command = .none
            }
            if shouldLaunch {
                snapshot.phase = .launching
                snapshot.command = .none
                snapshot.transcript = nil
                snapshot.errorMessage = nil
                snapshot.recoveryAction = nil
                snapshot.captureOwnerID = sessionID
                snapshot.captureLeaseUpdatedAt = Date()
                snapshot.startedAt = Date()
            }
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else {
                _ = saveLedgerUnlocked(previousState)
                return .storageFailed
            }

            if shouldFinish {
                return .finishing(assembly)
            }
            if shouldLaunch {
                return .launch(
                    SharedDictationContinuationLaunch(
                        snapshot: snapshot,
                        assembly: assembly
                    )
                )
            }
            return .waiting(assembly)
        } ?? nil
    }

    @discardableResult
    func requestContinuation(sessionID: UUID) -> Bool {
        withMainStateLock {
            let snapshot = loadMainSnapshotUnlocked()
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .transcribing
            else {
                return false
            }
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            state.continuationRequested = true
            return saveLedgerUnlocked(state)
        } ?? false
    }

    func assembly(
        sessionID: UUID,
        partID: UUID,
        transcript: String,
        duration: TimeInterval
    ) -> SharedDictationContinuationAssembly {
        withMainStateLock {
            let state = matchingLedgerUnlocked(sessionID: sessionID)
            return assembled(
                state: state,
                partID: partID,
                transcript: transcript,
                duration: duration
            )
        } ?? SharedDictationContinuationAssembly(
            text: Self.append(nil, transcript),
            duration: max(0, duration)
        )
    }

    /// Bank this part and move directly back to `launching`. The ledger write
    /// happens first and keeps the request bit set until the shared snapshot is
    /// durable. A crash at either write boundary is therefore replay-safe.
    func beginRequestedContinuation(
        sessionID: UUID,
        partID: UUID,
        transcript: String,
        duration: TimeInterval,
        historyPersisted: Bool
    ) -> SharedDictationContinuationLaunch? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            var state = matchingLedgerUnlocked(sessionID: sessionID)
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .transcribing,
                state.continuationRequested
            else {
                return nil
            }

            let assembly = assembled(
                state: state,
                partID: partID,
                transcript: transcript,
                duration: duration
            )
            if !state.bankedPartIDs.contains(partID) {
                state.bankedPartIDs.append(partID)
            }
            state.accumulatedTranscript = assembly.text
            state.accumulatedDuration = assembly.duration
            guard saveLedgerUnlocked(state) else { return nil }

            snapshot.phase = .launching
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.historyPersisted = historyPersisted
            snapshot.hasRecoverableAudio = false
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            snapshot.elapsedDuration = assembly.duration
            snapshot.startedAt = Date()
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else { return nil }

            state.continuationRequested = false
            if state.activePartID == partID {
                state.activePartID = nil
            }
            _ = saveLedgerUnlocked(state)
            return SharedDictationContinuationLaunch(
                snapshot: snapshot,
                assembly: assembly
            )
        } ?? nil
    }

    /// Competes with `markInsertionStarted` under the same advisory lock. If
    /// insertion already owns `.inserting`, this returns nil and leaves every
    /// byte alone. If continuation wins, the full completed transcript becomes
    /// the sidecar prefix before the keyboard can claim it.
    func reopenCompletedForContinuation(
        sessionID: UUID
    ) -> SharedDictationSnapshot? {
        withMainStateLock {
            var snapshot = loadMainSnapshotUnlocked()
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .completed,
                !hasLiveCaptureLease(snapshot),
                let transcript = snapshot.transcript,
                !transcript.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            else {
                return nil
            }

            var state = SharedDictationContinuationState.empty(
                sessionID: sessionID
            )
            state.accumulatedTranscript = transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            state.accumulatedDuration = max(0, snapshot.elapsedDuration ?? 0)
            guard saveLedgerUnlocked(state) else { return nil }

            snapshot.phase = .launching
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = false
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            snapshot.startedAt = Date()
            advanceRevision(&snapshot)
            guard saveMainSnapshotUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    func clear(sessionID: UUID) {
        _ = withMainStateLock {
            guard loadLedgerUnlocked()?.sessionID == sessionID else { return }
            if let ledgerURL {
                try? FileManager.default.removeItem(at: ledgerURL)
            }
            defaults?.removeObject(forKey: Self.ledgerDefaultsKey)
            _ = defaults?.synchronize()
        }
    }

    private func matchingLedgerUnlocked(
        sessionID: UUID
    ) -> SharedDictationContinuationState {
        guard
            let state = loadLedgerUnlocked(),
            state.sessionID == sessionID
        else {
            return .empty(sessionID: sessionID)
        }
        return state
    }

    private func assembled(
        state: SharedDictationContinuationState,
        partID: UUID,
        transcript: String,
        duration: TimeInterval
    ) -> SharedDictationContinuationAssembly {
        if state.bankedPartIDs.contains(partID) {
            return SharedDictationContinuationAssembly(
                text: state.accumulatedTranscript,
                duration: state.accumulatedDuration
            )
        }
        return SharedDictationContinuationAssembly(
            text: Self.append(state.accumulatedTranscript, transcript),
            duration: state.accumulatedDuration + max(0, duration)
        )
    }

    private static func append(_ existing: String?, _ next: String) -> String {
        let prefix = existing?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let suffix = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty { return suffix }
        if suffix.isEmpty { return prefix }
        return prefix + " " + suffix
    }

    private func loadMainSnapshotUnlocked() -> SharedDictationSnapshot {
        if
            let mainStateURL,
            let data = try? Data(contentsOf: mainStateURL),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        {
            return snapshot
        }
        defaults?.synchronize()
        guard
            let data = defaults?.data(
                forKey: SharedDictationConstants.storageKey
            ),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        else {
            return .idle
        }
        return snapshot
    }

    private func saveMainSnapshotUnlocked(
        _ snapshot: SharedDictationSnapshot
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else { return false }
        if let mainStateURL {
            do {
                try FileManager.default.createDirectory(
                    at: mainStateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: mainStateURL, options: [.atomic])
            } catch {
                return false
            }
        } else if defaults == nil {
            return false
        }
        defaults?.set(data, forKey: SharedDictationConstants.storageKey)
        _ = defaults?.synchronize()
        return true
    }

    private func loadLedgerUnlocked() -> SharedDictationContinuationState? {
        if
            let ledgerURL,
            let data = try? Data(contentsOf: ledgerURL),
            let state = try? JSONDecoder().decode(
                SharedDictationContinuationState.self,
                from: data
            )
        {
            return state
        }
        guard
            let data = defaults?.data(forKey: Self.ledgerDefaultsKey),
            let state = try? JSONDecoder().decode(
                SharedDictationContinuationState.self,
                from: data
            )
        else {
            return nil
        }
        return state
    }

    private func saveLedgerUnlocked(
        _ state: SharedDictationContinuationState
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(state) else { return false }
        if let ledgerURL {
            do {
                try FileManager.default.createDirectory(
                    at: ledgerURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: ledgerURL, options: [.atomic])
            } catch {
                return false
            }
        } else if defaults == nil {
            return false
        }
        defaults?.set(data, forKey: Self.ledgerDefaultsKey)
        _ = defaults?.synchronize()
        return true
    }

    private func advanceRevision(_ snapshot: inout SharedDictationSnapshot) {
        snapshot.revision = (snapshot.revision ?? 0) + 1
        snapshot.updatedAt = Date()
    }

    private func hasLiveCaptureLease(
        _ snapshot: SharedDictationSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard
            snapshot.captureOwnerID != nil,
            let updatedAt = snapshot.captureLeaseUpdatedAt
        else {
            return false
        }
        return now.timeIntervalSince(updatedAt) < 15
    }

    private var mainStateURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateFileName,
            isDirectory: false
        )
    }

    private var mainLockURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateLockFileName,
            isDirectory: false
        )
    }

    private var ledgerURL: URL? {
        storageDirectory?.appendingPathComponent(
            Self.ledgerFileName,
            isDirectory: false
        )
    }

    private func withMainStateLock<T>(_ operation: () -> T) -> T? {
        guard let mainLockURL else { return operation() }
        do {
            try FileManager.default.createDirectory(
                at: mainLockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        let descriptor = Darwin.open(
            mainLockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }
        return operation()
    }
}
