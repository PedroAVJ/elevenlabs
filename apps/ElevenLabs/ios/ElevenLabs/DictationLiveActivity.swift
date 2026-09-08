@preconcurrency import ActivityKit
import Foundation

struct LiveActivityStartReadiness {
    static func permitsRequest(
        hasObservedActiveScene: Bool,
        applicationIsActive: Bool
    ) -> Bool {
        hasObservedActiveScene && applicationIsActive
    }
}

/// Serializes the ActivityKit lifecycle across independent heartbeat and
/// terminal tasks. Cancellation alone cannot stop an update that was already
/// suspended inside ActivityKit; a closed session must reject that late write
/// even when the same Activity has already been repurposed as the idle launcher.
struct LiveActivitySessionGate {
    private var activeSessionID: UUID?
    private var closedSessionIDs: Set<UUID> = []

    mutating func begin(sessionID: UUID) {
        closedSessionIDs.remove(sessionID)
        activeSessionID = sessionID
    }

    mutating func close(sessionID: UUID) {
        closedSessionIDs.insert(sessionID)
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
    }

    mutating func permitsUpdate(
        sessionID: UUID,
        persistedPhase: ElevenLabsActivityAttributes.Phase
    ) -> Bool {
        guard !closedSessionIDs.contains(sessionID) else { return false }
        if activeSessionID == sessionID {
            return true
        }
        guard
            activeSessionID == nil,
            [.starting, .recording, .pausing, .paused, .resuming, .transcribing]
                .contains(persistedPhase)
        else {
            return false
        }

        // A new app process can adopt an ActivityKit session that survived its
        // predecessor, but idle and terminal cards can never become active.
        activeSessionID = sessionID
        return true
    }
}

/// A queued ActivityKit write cannot be cancelled once it is suspended inside
/// the framework. Generations still let a newer semantic state invalidate any
/// older write that has not entered ActivityKit yet, so a recording heartbeat
/// cannot sit in front of an optimistic Send transition.
struct LiveActivityUpdateGate {
    private var latestGenerationBySessionID: [UUID: UInt64] = [:]

    mutating func begin(sessionID: UUID) {
        latestGenerationBySessionID[sessionID] = 0
    }

    mutating func announce(sessionID: UUID) -> UInt64 {
        let generation = (latestGenerationBySessionID[sessionID] ?? 0) &+ 1
        latestGenerationBySessionID[sessionID] = generation
        return generation
    }

    func permits(sessionID: UUID, generation: UInt64) -> Bool {
        latestGenerationBySessionID[sessionID] == generation
    }

    mutating func close(sessionID: UUID) {
        latestGenerationBySessionID[sessionID] = nil
    }
}

enum LiveActivityRecordingPreflightAction: Equatable {
    case reuse
    case recreate
}

struct LiveActivityRecordingPreflight {
    static func action(
        expectedSessionID: UUID,
        activitySessionID: UUID?,
        activityState: ActivityState?,
        contentPhase: ElevenLabsActivityAttributes.Phase?
    ) -> LiveActivityRecordingPreflightAction {
        guard
            activitySessionID == expectedSessionID,
            isRunning(activityState),
            let contentPhase,
            [
                ElevenLabsActivityAttributes.Phase.starting,
                .recording,
                .pausing,
                .paused,
                .resuming,
                .transcribing,
            ].contains(contentPhase)
        else {
            return .recreate
        }
        return .reuse
    }

    static func isRunning(_ state: ActivityState?) -> Bool {
        switch state {
        case .active, .stale:
            true
        default:
            false
        }
    }
}

@MainActor
final class DictationLiveActivity {
    enum LiveActivityError: LocalizedError {
        case disabled
        case couldNotStart(String)

        var errorDescription: String? {
            switch self {
            case .disabled:
                "Enable Live Activities for Dictation Button in Settings."
            case let .couldNotStart(message):
                "The recording indicator could not start: \(message)"
            }
        }
    }

    private var activity: Activity<ElevenLabsActivityAttributes>?
    private var recordingStartedAtBySessionID: [UUID: Date] = [:]
    private var elapsedDurationBySessionID: [UUID: TimeInterval] = [:]
    private var visualizationFrameBySessionID: [UUID: UInt8] = [:]
    private var audioLevelBySessionID: [UUID: Double] = [:]
    private var meterLevelsBySessionID: [UUID: [Double]] = [:]
    private var isEnsuringLauncher = false
    private var sessionGate = LiveActivitySessionGate()
    private var updateGate = LiveActivityUpdateGate()
    private var activityUpdateTail: Task<Void, Never>?

    /// Keeps one neutral launcher available when no dictation owns ActivityKit.
    /// Control Center and safe app activation both converge here, so repeated
    /// requests reuse the same card and remove only duplicate or stale cards.
    func ensureIdleLauncher() async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.disabled
        }
        guard !isEnsuringLauncher else { return }
        isEnsuringLauncher = true
        defer { isEnsuringLauncher = false }
        await activityUpdateTail?.value

        let existingActivities = Activity<ElevenLabsActivityAttributes>.activities
        for existing in existingActivities {
            sessionGate.close(sessionID: existing.attributes.sessionID)
            updateGate.close(sessionID: existing.attributes.sessionID)
        }
        if let existingLauncher = existingActivities.first(where: {
            $0.content.state.phase == .idle
                && LiveActivityRecordingPreflight.isRunning($0.activityState)
        }) {
            activity = existingLauncher
            clearSessionState()
            for existing in existingActivities
            where existing.id != existingLauncher.id {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        for existing in existingActivities {
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        activity = nil
        clearSessionState()

        let sessionID = UUID()
        let attributes = ElevenLabsActivityAttributes(
            sessionID: sessionID,
            startedAt: Date()
        )
        let content = ActivityContent(
            state: ElevenLabsActivityAttributes.ContentState(phase: .idle),
            staleDate: nil
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            throw LiveActivityError.couldNotStart(error.localizedDescription)
        }
    }

    /// App activation may adopt and deduplicate an already-armed launcher, but
    /// only an explicit Control Center action or terminal session may create it.
    func maintainIdleLauncherIfPresent() async {
        guard Activity<ElevenLabsActivityAttributes>.activities.contains(
            where: { $0.content.state.phase == .idle }
        ) else {
            return
        }
        try? await ensureIdleLauncher()
    }

    /// `AudioRecordingIntent` requires a Live Activity for the entire capture.
    /// Without it, iOS stops recording as soon as the intent returns.
    func start(sessionID: UUID, startedAt: Date) async throws {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            throw LiveActivityError.disabled
        }
        await activityUpdateTail?.value

        // A process termination can strand the old indicator even though its
        // recorder is gone. There can only be one ElevenLabs dictation.
        for existing in Activity<ElevenLabsActivityAttributes>.activities {
            sessionGate.close(sessionID: existing.attributes.sessionID)
            await existing.end(nil, dismissalPolicy: .immediate)
        }
        clearSessionState()

        let attributes = ElevenLabsActivityAttributes(
            sessionID: sessionID,
            startedAt: startedAt
        )
        let content = ActivityContent(
            state: ElevenLabsActivityAttributes.ContentState(
                phase: .starting,
                recordingStartedAt: nil,
                elapsedDuration: 0,
                visualizationFrame: 0,
                audioLevel: nil,
                meterLevels: nil
            ),
            staleDate: staleDate(for: .starting)
        )
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            sessionGate.begin(sessionID: sessionID)
            updateGate.begin(sessionID: sessionID)
        } catch {
            throw LiveActivityError.couldNotStart(error.localizedDescription)
        }
    }

    /// Reuses a surviving recording activity or recreates it before an
    /// `AudioRecordingIntent` is allowed to reactivate the microphone. A user
    /// or the system can dismiss the paused card while the durable segmented
    /// session remains resumable; updating a dismissed `Activity` object is a
    /// no-op, and returning from the intent with active audio then traps inside
    /// AppIntents.
    func prepareForRecording(
        sessionID: UUID,
        startedAt: Date,
        phase: ElevenLabsActivityAttributes.Phase,
        elapsedDuration: TimeInterval
    ) async throws {
        await activityUpdateTail?.value
        let candidate = activityForPreflight(sessionID: sessionID)
        let action = LiveActivityRecordingPreflight.action(
            expectedSessionID: sessionID,
            activitySessionID: candidate?.attributes.sessionID,
            activityState: candidate?.activityState,
            contentPhase: candidate?.content.state.phase
        )

        do {
            switch action {
            case .reuse:
                activity = candidate
                sessionGate.begin(sessionID: sessionID)
                updateGate.begin(sessionID: sessionID)
            case .recreate:
                try await start(sessionID: sessionID, startedAt: startedAt)
            }

            await update(
                phase,
                sessionID: sessionID,
                elapsedDuration: elapsedDuration
            )
            guard currentActivity(for: sessionID) != nil else {
                throw LiveActivityError.couldNotStart(
                    "The activity ended before recording resumed."
                )
            }
            Observability.logLiveActivityRecordingPreflight(
                sessionID: sessionID,
                phase: phase.rawValue,
                outcome: action == .reuse ? "reused" : "recreated"
            )
        } catch {
            Observability.logLiveActivityRecordingPreflight(
                sessionID: sessionID,
                phase: phase.rawValue,
                outcome: "failed"
            )
            throw error
        }
    }

    func update(
        _ phase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID,
        recordingStartedAt: Date? = nil,
        elapsedDuration: TimeInterval? = nil,
        audioLevel: Double? = nil,
        meterLevels: [Double]? = nil,
        advancesVisualization: Bool = false
    ) async {
        let updateGeneration = updateGate.announce(sessionID: sessionID)
        let precedingUpdate = activityUpdateTail
        let queuedUpdate = Task { @MainActor [weak self] in
            await precedingUpdate?.value
            guard
                let self,
                let activity = self.currentActivity(for: sessionID),
                self.sessionGate.permitsUpdate(
                    sessionID: sessionID,
                    persistedPhase: activity.content.state.phase
                ),
                self.updateGate.permits(
                    sessionID: sessionID,
                    generation: updateGeneration
                )
            else {
                return
            }
            if advancesVisualization {
                self.visualizationFrameBySessionID[sessionID] =
                    (self.visualizationFrameBySessionID[sessionID] ?? 0) &+ 1
            }
            if let elapsedDuration {
                self.elapsedDurationBySessionID[sessionID] = max(
                    0,
                    elapsedDuration
                )
            }
            if phase == .recording {
                if let recordingStartedAt {
                    let bankedDuration =
                        self.elapsedDurationBySessionID[sessionID] ?? 0
                    self.recordingStartedAtBySessionID[sessionID] =
                        recordingStartedAt.addingTimeInterval(-bankedDuration)
                } else if self.recordingStartedAtBySessionID[sessionID] == nil {
                    let bankedDuration =
                        self.elapsedDurationBySessionID[sessionID] ?? 0
                    self.recordingStartedAtBySessionID[sessionID] =
                        Date().addingTimeInterval(-bankedDuration)
                }
                if let audioLevel {
                    self.audioLevelBySessionID[sessionID] = min(
                        1,
                        max(0, audioLevel)
                    )
                }
                if let meterLevels {
                    self.meterLevelsBySessionID[sessionID] = Array(
                        meterLevels.prefix(21)
                    ).map { min(1, max(0, $0)) }
                }
            } else {
                // Paused minimal UI is a snowflake, never a stale meter frame.
                // Clearing the last level also prevents future designs from
                // accidentally presenting old microphone energy as live.
                self.audioLevelBySessionID[sessionID] = nil
                self.meterLevelsBySessionID[sessionID] = nil
            }
            await activity.update(
                ActivityContent(
                    state: ElevenLabsActivityAttributes.ContentState(
                        phase: phase,
                        recordingStartedAt:
                            self.recordingStartedAtBySessionID[sessionID],
                        elapsedDuration:
                            self.elapsedDurationBySessionID[sessionID] ?? 0,
                        visualizationFrame:
                            self.visualizationFrameBySessionID[sessionID] ?? 0,
                        audioLevel: self.audioLevelBySessionID[sessionID],
                        meterLevels: self.meterLevelsBySessionID[sessionID]
                    ),
                    staleDate: self.staleDate(for: phase)
                )
            )
        }
        activityUpdateTail = queuedUpdate
        await queuedUpdate.value
    }

    /// Advances real ActivityKit content instead of relying on a perpetual
    /// SwiftUI loop, which the system doesn't guarantee for Live Activities.
    func advanceVisualization(
        _ phase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID,
        audioLevel: Double? = nil,
        meterLevels: [Double]? = nil
    ) async {
        await update(
            phase,
            sessionID: sessionID,
            audioLevel: audioLevel,
            meterLevels: meterLevels,
            advancesVisualization: true
        )
    }

    /// Active phases periodically extend a short deadline. If the app process
    /// is killed, ActivityKit marks the card stale instead of advertising a
    /// microphone that no longer exists. Paused is intentionally durable and
    /// has no deadline because it owns no microphone or process runtime.
    func refreshStaleness(
        _ phase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID
    ) async {
        guard [.starting, .recording, .pausing, .resuming].contains(phase) else {
            return
        }
        await update(phase, sessionID: sessionID)
    }

    func end(
        _ phase: ElevenLabsActivityAttributes.Phase,
        sessionID: UUID
    ) async {
        let activity = currentActivity(for: sessionID)
        let mayEnd = activity.map {
            sessionGate.permitsUpdate(
                sessionID: sessionID,
                persistedPhase: $0.content.state.phase
            )
        } ?? false
        // Close before waiting for the update queue. An update already inside
        // ActivityKit is allowed to finish, then the queued terminal write is
        // guaranteed to be the final state for this session.
        sessionGate.close(sessionID: sessionID)
        updateGate.close(sessionID: sessionID)

        guard let activity, mayEnd else {
            await activityUpdateTail?.value
            if phase.returnsToIdleLauncher {
                try? await ensureIdleLauncher()
            }
            return
        }

        let precedingUpdate = activityUpdateTail
        let terminalUpdate = Task { @MainActor [weak self] in
            await precedingUpdate?.value
            guard let self else { return }

            // Successful delivery and cancellation turn the exact same system
            // surface back into the persistent launcher. Closing the session
            // gates first prevents a delayed waveform write from reviving it.
            if phase.returnsToIdleLauncher {
                self.clearSessionState(for: sessionID)
                await activity.update(
                    ActivityContent(
                        state: ElevenLabsActivityAttributes.ContentState(
                            phase: .idle
                        ),
                        staleDate: nil
                    )
                )
                self.activity = activity
                return
            }

            let terminalContent = ActivityContent(
                state: ElevenLabsActivityAttributes.ContentState(
                    phase: phase,
                    recordingStartedAt:
                        self.recordingStartedAtBySessionID[sessionID],
                    elapsedDuration:
                        self.elapsedDurationBySessionID[sessionID] ?? 0,
                    visualizationFrame:
                        self.visualizationFrameBySessionID[sessionID] ?? 0,
                    audioLevel: self.audioLevelBySessionID[sessionID],
                    meterLevels: self.meterLevelsBySessionID[sessionID]
                ),
                staleDate: nil
            )
            await activity.update(terminalContent)
            self.clearSessionState(for: sessionID)
            self.activity = activity
        }
        activityUpdateTail = terminalUpdate
        await terminalUpdate.value

        // The user or system can dismiss a card while terminal work is queued.
        // Recreate the promised launcher while this caller still owns runtime.
        if
            phase.returnsToIdleLauncher,
            !Activity<ElevenLabsActivityAttributes>.activities.contains(
                where: {
                    $0.content.state.phase == .idle
                        && LiveActivityRecordingPreflight.isRunning(
                            $0.activityState
                        )
                }
            )
        {
            self.activity = nil
            try? await ensureIdleLauncher()
        }
    }

    private func currentActivity(
        for sessionID: UUID
    ) -> Activity<ElevenLabsActivityAttributes>? {
        let candidate = activityForPreflight(sessionID: sessionID)
        guard LiveActivityRecordingPreflight.isRunning(
            candidate?.activityState
        ) else {
            if activity?.attributes.sessionID == sessionID {
                activity = nil
            }
            return nil
        }
        activity = candidate
        return candidate
    }

    private func activityForPreflight(
        sessionID: UUID
    ) -> Activity<ElevenLabsActivityAttributes>? {
        if let systemActivity = Activity<ElevenLabsActivityAttributes>
            .activities.first(where: {
            $0.attributes.sessionID == sessionID
            })
        {
            return systemActivity
        }
        guard activity?.attributes.sessionID == sessionID else { return nil }
        return activity
    }

    private func staleDate(
        for phase: ElevenLabsActivityAttributes.Phase
    ) -> Date? {
        switch phase {
        case .idle:
            nil
        case .starting, .recording, .pausing, .resuming:
            // The engine refreshes every three seconds. Fifteen seconds leaves
            // room for ordinary scheduling jitter without masking a dead mic.
            Date().addingTimeInterval(15)
        case .transcribing:
            // Final transcription runs under a finite UIKit background task.
            Date().addingTimeInterval(45)
        case .paused, .completed, .failed, .cancelled:
            nil
        }
    }

    private func clearSessionState() {
        recordingStartedAtBySessionID.removeAll()
        elapsedDurationBySessionID.removeAll()
        visualizationFrameBySessionID.removeAll()
        audioLevelBySessionID.removeAll()
        meterLevelsBySessionID.removeAll()
    }

    private func clearSessionState(for sessionID: UUID) {
        recordingStartedAtBySessionID[sessionID] = nil
        elapsedDurationBySessionID[sessionID] = nil
        visualizationFrameBySessionID[sessionID] = nil
        audioLevelBySessionID[sessionID] = nil
        meterLevelsBySessionID[sessionID] = nil
    }
}
