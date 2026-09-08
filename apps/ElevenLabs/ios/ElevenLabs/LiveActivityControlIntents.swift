import AppIntents
import Foundation
import WidgetKit

/// Stable identity shared by the WidgetKit declaration and every app-owned
/// intent that can change the control's value.
@available(iOS 18.0, *)
enum ElevenLabsDictationControlContract {
    static let kind = "com.pedro.ElevenLabs.control.dictation"

    @MainActor
    static func reload() {
        ControlCenter.shared.reloadControls(ofKind: kind)
    }
}

@MainActor
private func reloadDictationControlIfAvailable() {
    if #available(iOS 18.0, *) {
        ElevenLabsDictationControlContract.reload()
    }
}

/// Process-local handoff retained only for custom-URL compatibility with an
/// already-installed foreground-launching build. The current Control Widget
/// never submits this request or opens the containing app.
///
/// The system can run the intent before or after the foreground scene becomes
/// active. The pending bit covers the cold-launch order; the notification
/// covers an already-running scene. `consume()` makes the request exactly once
/// regardless of which callback wins the race.
@MainActor
enum ForegroundControlStartRequest {
    static let notification = Notification.Name(
        "com.pedro.ElevenLabs.foreground-control-start"
    )

    private static var isPending = false

    static func submit(
        notificationCenter: NotificationCenter = .default
    ) {
        isPending = true
        notificationCenter.post(name: notification, object: nil)
    }

    static func consume() -> Bool {
        guard isPending else { return false }
        isPending = false
        return true
    }

}

#if !ELEVENLABS_LIVE_ACTIVITY_EXTENSION && !ELEVENLABS_KEYBOARD_EXTENSION
enum DictationControlRequestedAction: String, Equatable, Sendable {
    case showLauncher = "show_launcher"
    case pause
    case resume
    case none
}

enum DictationControlTransition {
    static func action(
        requestedIsOn: Bool,
        phase: SharedDictationPhase
    ) -> DictationControlRequestedAction {
        if requestedIsOn {
            switch phase {
            case .paused:
                return .resume
            case .idle, .cancelled, .inserted, .handled, .failed:
                return .showLauncher
            case .launching, .starting, .recording, .pausing, .resuming,
                 .transcribing, .completed, .inserting, .deliveryBlocked:
                return .none
            }
        }

        return phase == .recording ? .pause : .none
    }
}

enum DictationControlIntentFailurePolicy {
    /// A terminal failure is already durable and visible through the Live
    /// Activity. Completing the SetValueIntent lets WidgetKit discard its
    /// optimistic Boolean and reload the provider's confirmed Off state.
    static func completesIntent(after phase: SharedDictationPhase) -> Bool {
        phase == .failed
    }
}

@MainActor
private func performDictationControlAction(
    _ action: DictationControlRequestedAction,
    store: SharedDictationStore
) async throws {
    let before = store.load()
    switch action {
    case .showLauncher:
        try await DictationEngine.shared.showIdleLauncher()

    case .pause:
        if SharedDictationIntentCommandRouter.routeToKeyboardOwner(
            .pause,
            sessionID: before.sessionID,
            store: store
        ) {
            _ = await ElevenLabsCoordinator.shared.model
                .performSharedIntentCommand(
                    .pause,
                    expectedSessionID: before.sessionID
                )
        } else {
            try await DictationEngine.shared.pause(
                expectedSessionID: before.sessionID
            )
        }

    case .resume:
        if before.sessionKind == .keyboardRoundTrip {
            // Compatibility only for a paused session created by an older
            // foreground-launching build.
            ElevenLabsCoordinator.shared.model.handleForegroundControlIntent()
        } else {
            try await DictationEngine.shared.resume(
                expectedSessionID: before.sessionID
            )
        }

    case .none:
        break
    }
}
#endif

/// The system supplies the requested Boolean value. Off prepares the persistent
/// Live Activity launcher, Recording pauses, and Paused resumes the same
/// durable segmented session. `AudioRecordingIntent` grants the recording
/// execution lane for pause and resume, while `LiveActivityIntent` permits the
/// idle launcher to be created without foregrounding Dictation Button.
@available(iOS 18.0, *)
struct ToggleDictationControlIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SetValueIntent
{
    static let title: LocalizedStringResource = "Dictation"
    static let description = IntentDescription(
        "Show the Live Activity launcher, or pause and continue an active dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.dynamic)]
    }

    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ELEVENLABS_LIVE_ACTIVITY_EXTENSION || ELEVENLABS_KEYBOARD_EXTENSION
        return .result()
        #else
        let store = SharedDictationStore()
        let requestedIsOn = value
        let before = store.load()
        let action = DictationControlTransition.action(
            requestedIsOn: requestedIsOn,
            phase: before.phase
        )
        Observability.logDictationControlTransition(
            action: action.rawValue,
            requestedIsOn: requestedIsOn,
            phase: before.phase.rawValue,
            outcome: "requested"
        )

        defer {
            ElevenLabsDictationControlContract.reload()
            ElevenLabsCoordinator.shared.sharedDictationDidChange()
        }

        do {
            try await performDictationControlAction(
                action,
                store: store
            )

            let after = store.load()
            if action == .showLauncher || after.phase == .recording {
                ElevenLabsCoordinator.shared.markControlCenterPractice()
            }
            Observability.logDictationControlTransition(
                action: action.rawValue,
                requestedIsOn: requestedIsOn,
                phase: after.phase.rawValue,
                outcome: "completed"
            )
            return .result()
        } catch {
            var surfacedError = error
            if
                (error as? AudioRecorderError)?
                    .requiresForegroundContinuation == true
            {
                Observability.logDictationControlTransition(
                    action: action.rawValue,
                    requestedIsOn: requestedIsOn,
                    phase: store.load().phase.rawValue,
                    outcome: "foreground_requested"
                )
                do {
                    let dialog: IntentDialog =
                        "Open Dictation Button to start the microphone."
                    if #available(iOS 26.0, *) {
                        try await continueInForeground(
                            dialog,
                            alwaysConfirm: false
                        )
                        let foregroundAction =
                            DictationControlTransition.action(
                                requestedIsOn: requestedIsOn,
                                phase: store.load().phase
                            )
                        try await performDictationControlAction(
                            foregroundAction,
                            store: store
                        )
                    } else {
                        let foregroundContinuation:
                            @MainActor @Sendable () async throws -> Void = {
                            let foregroundAction =
                                DictationControlTransition.action(
                                    requestedIsOn: requestedIsOn,
                                    phase: store.load().phase
                                )
                            try await performDictationControlAction(
                                foregroundAction,
                                store: store
                            )
                        }
                        try await requestToContinueInForeground(
                            dialog,
                            continuation: foregroundContinuation
                        )
                    }
                    let foregroundResult = store.load()
                    if action == .showLauncher || foregroundResult.phase == .recording {
                        ElevenLabsCoordinator.shared.markControlCenterPractice()
                    }
                    Observability.logDictationControlTransition(
                        action: action.rawValue,
                        requestedIsOn: requestedIsOn,
                        phase: foregroundResult.phase.rawValue,
                        outcome: "continued_in_foreground"
                    )
                    return .result()
                } catch {
                    surfacedError = error
                }
            }
            let failedPhase = store.load().phase
            Observability.logDictationControlTransition(
                action: action.rawValue,
                requestedIsOn: requestedIsOn,
                phase: failedPhase.rawValue,
                outcome: "failed"
            )
            Observability.logDictationIntentFailure(
                surfacedError,
                operation: "control_toggle_\(action.rawValue)"
            )
            if DictationControlIntentFailurePolicy.completesIntent(
                after: failedPhase
            ) {
                return .result()
            }
            throw surfacedError
        }
        #endif
    }
}

#if !ELEVENLABS_LIVE_ACTIVITY_EXTENSION && !ELEVENLABS_KEYBOARD_EXTENSION
/// Compatibility for iOS 18-25. iOS 26 uses the dynamic foreground mode and
/// `continueInForeground` directly from AppIntent.
@available(iOS 18.0, *)
extension ToggleDictationControlIntent: ForegroundContinuableIntent {}
#endif

/// Session-scoped controls embedded in the Live Activity. The same intent
/// declarations are compiled into the widget extension so WidgetKit can render
/// them, while `LiveActivityIntent` asks iOS to execute the app-target copy in
/// ElevenLabs's background process. The UUID guard makes a stranded card from
/// an older session harmless.
private protocol SessionScopedDictationIntent: AppIntent {
    var sessionID: String { get }
}

private extension SessionScopedDictationIntent {
    var parsedSessionID: UUID? { UUID(uuidString: sessionID) }
}

/// The idle Live Activity's explicit start action. Opening the containing app
/// gives the foreground recorder a normal microphone lifecycle; the compact
/// card uses the same URL so every idle presentation has one start behavior.
@available(iOS 18.0, *)
struct StartDictationFromLiveActivityIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Dictation"
    static let description = IntentDescription(
        "Open Dictation Button and start listening."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    init() {}

    func perform() async throws -> some IntentResult {
        .result(
            opensIntent: OpenURLIntent(
                URL(string: "elevenlabs://live-activity/start")!
            )
        )
    }
}

struct PauseDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Pause Dictation"
    static let description = IntentDescription(
        "Release the microphone and bank this segment without ending the dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ELEVENLABS_LIVE_ACTIVITY_EXTENSION || ELEVENLABS_KEYBOARD_EXTENSION
        return .result()
        #else
        defer { reloadDictationControlIfAvailable() }
        guard let parsedSessionID else { return .result() }
        if SharedDictationIntentCommandRouter.routeToKeyboardOwner(
            .pause,
            sessionID: parsedSessionID
        ) {
            _ = await ElevenLabsCoordinator.shared.model
                .performSharedIntentCommand(
                    .pause,
                    expectedSessionID: parsedSessionID
                )
            return .result()
        }
        do {
            try await DictationEngine.shared.pause(
                expectedSessionID: parsedSessionID
            )
            return .result()
        } catch {
            Observability.logDictationIntentFailure(
                error,
                operation: "live_activity_pause"
            )
            throw error
        }
        #endif
    }
}

struct ResumeDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Resume Dictation"
    static let description = IntentDescription(
        "Resume listening without ending the current dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {}

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ELEVENLABS_LIVE_ACTIVITY_EXTENSION || ELEVENLABS_KEYBOARD_EXTENSION
        return .result()
        #else
        defer { reloadDictationControlIfAvailable() }
        guard let parsedSessionID else { return .result() }
        let sharedSnapshot = SharedDictationStore().load()
        if
            sharedSnapshot.sessionID == parsedSessionID,
            sharedSnapshot.sessionKind == .keyboardRoundTrip,
            sharedSnapshot.phase == .paused
        {
            // Compatibility only for a card rendered by an older build. New
            // paused activities have no Resume button because continuation is
            // intentionally foregrounded through Control Center.
            Observability.logDictationContinuation(
                event: "control_center_continue",
                outcome: "use_control_center"
            )
            return .result()
        }
        do {
            try await DictationEngine.shared.resume(
                expectedSessionID: parsedSessionID
            )
            return .result()
        } catch {
            Observability.logDictationIntentFailure(
                error,
                operation: "live_activity_resume"
            )
            throw error
        }
        #endif
    }
}

struct CancelDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Cancel Dictation"
    static let description = IntentDescription(
        "Stop and discard the current dictation."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ELEVENLABS_LIVE_ACTIVITY_EXTENSION || ELEVENLABS_KEYBOARD_EXTENSION
        return .result()
        #else
        defer { reloadDictationControlIfAvailable() }
        guard let parsedSessionID else { return .result() }
        if SharedDictationIntentCommandRouter.routeToKeyboardOwner(
            .cancel,
            sessionID: parsedSessionID
        ) {
            _ = await ElevenLabsCoordinator.shared.model
                .performSharedIntentCommand(
                    .cancel,
                    expectedSessionID: parsedSessionID
                )
            return .result()
        }
        await DictationEngine.shared.cancel(
            expectedSessionID: parsedSessionID
        )
        return .result()
        #endif
    }
}

/// Intent-backed wakeup for the keyboard's Send button. The keyboard records
/// cursor evidence and writes the shared Stop command, then asks
/// the system to perform this app-target copy so a suspended app can finish the
/// transcription without taking over the screen. Delivery follows the live
/// keyboard document proxy when the transcript is ready.
struct StopAndInsertDictationIntent:
    AudioRecordingIntent,
    LiveActivityIntent,
    SessionScopedDictationIntent
{
    static let title: LocalizedStringResource = "Send Dictation"
    static let description = IntentDescription(
        "Finish this dictation for insertion through the active Dictation Button keyboard."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    static let isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "Dictation Session")
    var sessionID: String

    init() {
        sessionID = ""
    }

    init(sessionID: UUID) {
        self.sessionID = sessionID.uuidString
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if ELEVENLABS_LIVE_ACTIVITY_EXTENSION || ELEVENLABS_KEYBOARD_EXTENSION
        return .result()
        #else
        defer { reloadDictationControlIfAvailable() }
        guard let parsedSessionID else { return .result() }
        let sharedSnapshot = SharedDictationStore().load()
        if
            sharedSnapshot.sessionID == parsedSessionID,
            sharedSnapshot.sessionKind == .keyboardRoundTrip
        {
            _ = SharedDictationIntentCommandRouter.routeToKeyboardOwner(
                .stop,
                sessionID: parsedSessionID
            )
            _ = await ElevenLabsCoordinator.shared.model
                .performSharedIntentCommand(
                    .stop,
                    expectedSessionID: parsedSessionID
                )
            return .result()
        }
        do {
            try await DictationEngine.shared.stop(
                expectedSessionID: parsedSessionID
            )
            return .result()
        } catch {
            Observability.logDictationIntentFailure(
                error,
                operation: "stop_and_insert"
            )
            throw error
        }
        #endif
    }
}
