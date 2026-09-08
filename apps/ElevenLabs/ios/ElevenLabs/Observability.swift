import Foundation
import Sentry
#if os(iOS)
import UIKit
#endif

/// Remote observability for ElevenLabs, shared by the macOS app and the iPhone
/// containing app.
///
/// Nothing is sent unless a valid DSN is configured, so a build without one is
/// completely silent rather than partially instrumented.
/// Product logs keep only privacy-safe counts, internal correlation IDs, and
/// allowlisted state. Dictated text and document context never leave device.
enum Observability {
    /// Info.plist key holding the DSN. `SENTRY_DSN` overrides it for local runs.
    private static let dsnInfoPlistKey = "SentryDSN"

    private static let stateLock = NSLock()
    nonisolated(unsafe) private static var isEnabled = false

    static var enabled: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isEnabled
    }

    /// Reads the configured DSN, rejecting placeholders and non-HTTPS values the
    /// way Nova does, so an unsubstituted build variable cannot half-enable the
    /// SDK.
    static func resolveDSN(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> String? {
        let candidates = [
            environment["SENTRY_DSN"],
            bundle.object(forInfoDictionaryKey: dsnInfoPlistKey) as? String,
        ]

        for candidate in candidates {
            guard
                let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty,
                let url = URL(string: value),
                url.scheme == "https",
                let user = url.user,
                !user.isEmpty
            else { continue }

            return value
        }

        return nil
    }

    /// Starts the SDK once. Returns `false` when no DSN is configured, which is
    /// a supported state rather than a failure.
    @discardableResult
    static func start(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard !isEnabled else { return true }
        guard let dsn = resolveDSN(environment: environment, bundle: bundle) else {
            return false
        }

        let release = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        SentrySDK.start { options in
            options.dsn = dsn
            // Logs are still behind `experimental` in sentry-cocoa 8.x; the
            // top-level `options.enableLogs` only exists from 9.x onward.
            options.experimental.enableLogs = true
            // Explicit product events carry their own correlation fields.
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.maxBreadcrumbs = 0
            #if DEBUG
            options.environment = "debug"
            #else
            options.environment = "production"
            #endif

            if let release, let build {
                options.releaseName = "elevenlabs@\(release)+\(build)"
            }

            // Screenshots and view hierarchies would capture dictated text
            // rendered on screen. They must stay off.
            #if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            #endif

            // Errors and logs only. Performance tracing is not worth the
            // battery, bandwidth, or event volume for this app.
            options.tracesSampleRate = 0
        }

        isEnabled = true
        return true
    }

    // MARK: - State logs

    static func logStarted(surface: String) {
        guard enabled else { return }
        SentrySDK.logger.info(
            "elevenlabs.started",
            attributes: ["surface": surface]
        )
    }

    /// Records the launch ordering needed to diagnose a transient
    /// dashboard/onboarding paint. `stage` is allowlisted so no scene, intent,
    /// host, or user-provided value can enter remote logs.
    static func logLaunchPresentation(
        stage: String,
        phase: String?,
        completedOnboarding: Bool,
        launchStateReady: Bool
    ) {
        guard enabled else { return }
        let allowedStages = [
            "first_bridge_snapshot",
            "control_intent_perform",
            "scene_active_grace",
        ]
        let allowedPhases = [
            "idle",
            "starting",
            "recording",
            "pausing",
            "paused",
            "resuming",
            "transcribing",
            "failed",
        ]
        var attributes: [String: Any] = [
            "stage": allowedStages.contains(stage) ? stage : "unknown",
            "completedOnboarding": String(completedOnboarding),
            "launchStateReady": String(launchStateReady),
        ]
        if let phase {
            attributes["phase"] = allowedPhases.contains(phase)
                ? phase
                : "unknown"
        }
        SentrySDK.logger.info(
            "elevenlabs.launch_presentation",
            attributes: attributes
        )
    }

    /// Reports what the previous run's health marker proved. `unclean` is the
    /// crash/force-quit signal that is otherwise only visible on this device.
    static func logPreviousSessionHealth(status: String, recoveredItems: Int) {
        guard enabled else { return }
        let attributes: [String: Any] = [
            "status": status,
            "recoveredItems": String(recoveredItems),
        ]

        if status == "unclean" {
            SentrySDK.logger.warn("elevenlabs.previous_session", attributes: attributes)
        } else {
            SentrySDK.logger.info("elevenlabs.previous_session", attributes: attributes)
        }
    }

    static func logCleanTermination() {
        guard enabled else { return }
        SentrySDK.logger.info("elevenlabs.clean_termination")
    }

    static func logDictationFinished(
        outcome: String,
        durationMs: Int,
        characterCount: Int,
        sessionID: UUID? = nil
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "outcome": outcome,
            "durationMs": String(durationMs),
            "characterCount": String(characterCount),
        ]
        if let sessionID {
            attributes["sessionID"] = sessionID.uuidString
        }
        SentrySDK.logger.info(
            "elevenlabs.dictation_finished",
            attributes: attributes
        )
    }

    static func logTranscriptionCompleted(
        characterCount: Int,
        surface: String,
        sessionID: UUID?,
        partID: UUID?,
        requestedLanguage: String,
        detectedLanguage: String?,
        languageProbability: Double?,
        durationMs: Int
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "surface": surface,
            "characterCount": String(max(0, characterCount)),
            "requestedLanguage": requestedLanguage,
            "durationMs": String(max(0, durationMs)),
        ]
        if let sessionID {
            attributes["sessionID"] = sessionID.uuidString
        }
        if let partID {
            attributes["partID"] = partID.uuidString
        }
        if let detectedLanguage {
            attributes["detectedLanguage"] = detectedLanguage
        }
        if let languageProbability {
            attributes["languageProbability"] = String(languageProbability)
        }
        SentrySDK.logger.info(
            "elevenlabs.transcription_completed",
            attributes: attributes
        )
    }

    #if os(iOS)
    static func flushKeyboardInsertionTelemetry(
        store: KeyboardInsertionTelemetryStore = .init()
    ) {
        guard enabled, let record = store.pendingForReporting() else { return }
        let formatter = ISO8601DateFormatter()
        var attributes: [String: Any] = [
            "attemptID": record.id.uuidString,
            "sessionID": record.sessionID.uuidString,
            "outcome": record.outcome.rawValue,
            "characterCount": String(record.transcript.count),
            "startedAt": formatter.string(from: record.startedAt),
        ]
        if let value = record.deliverySource {
            attributes["deliverySource"] = value.rawValue
        }
        if let value = record.returnBundleIdentifier {
            attributes["returnBundleIdentifier"] = value
        }
        if let value = record.finishedAt {
            attributes["finishedAt"] = formatter.string(from: value)
        }
        if let value = record.latencyMs {
            attributes["latencyMs"] = String(value)
        }
        if let value = record.documentIdentifierBefore {
            attributes["documentIdentifierBefore"] = value
        }
        if let value = record.documentIdentifierAfter {
            attributes["documentIdentifierAfter"] = value
        }
        if let value = record.documentChangeObserved {
            attributes["documentChangeObserved"] = String(value)
        }
        if record.outcome == .confirmed {
            SentrySDK.logger.info(
                "elevenlabs.keyboard_delivery",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.warn(
                "elevenlabs.keyboard_delivery",
                attributes: attributes
            )
        }
        store.markReported(record)
    }
    #endif

    @MainActor
    static func logDictationContinuation(
        event: String,
        outcome: String,
        durationMs: Int? = nil
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "event": event,
            "outcome": outcome,
            "applicationState": applicationState(),
        ]
        if let durationMs {
            attributes["durationMs"] = String(max(0, durationMs))
        }
        SentrySDK.logger.info(
            "elevenlabs.dictation_continuation",
            attributes: attributes
        )
    }

    /// One privacy-safe record for each system-control state transition. The
    /// values are closed enums supplied by product code; no transcript, audio,
    /// error description, or host identity crosses this boundary.
    static func logDictationControlTransition(
        action: String,
        requestedIsOn: Bool,
        phase: String,
        outcome: String
    ) {
        guard enabled else { return }
        let allowedActions = [
            "show_launcher",
            "start",
            "pause",
            "resume",
            "none",
        ]
        let allowedPhases = [
            "idle",
            "launching",
            "starting",
            "recording",
            "pausing",
            "paused",
            "resuming",
            "transcribing",
            "completed",
            "inserting",
            "deliveryBlocked",
            "failed",
            "cancelled",
            "inserted",
            "handled",
        ]
        let allowedOutcomes = [
            "requested",
            "foreground_requested",
            "continued_in_foreground",
            "completed",
            "failed",
        ]
        SentrySDK.logger.info(
            "elevenlabs.dictation_control_transition",
            attributes: [
                "action": allowedActions.contains(action) ? action : "none",
                "requestedIsOn": String(requestedIsOn),
                "phase": allowedPhases.contains(phase) ? phase : "unknown",
                "outcome": allowedOutcomes.contains(outcome)
                    ? outcome
                    : "failed",
            ]
        )
    }

    /// Records the mandatory ActivityKit guard immediately before a resumed
    /// AudioRecordingIntent reactivates the microphone. Values are closed
    /// product state plus an opaque session identifier; no audio or transcript
    /// content is included.
    static func logLiveActivityRecordingPreflight(
        sessionID: UUID,
        phase: String,
        outcome: String
    ) {
        guard enabled else { return }
        let allowedPhases = ["starting", "resuming"]
        let allowedOutcomes = ["reused", "recreated", "failed"]
        SentrySDK.logger.info(
            "elevenlabs.live_activity_recording_preflight",
            attributes: [
                "sessionID": sessionID.uuidString,
                "phase": allowedPhases.contains(phase) ? phase : "unknown",
                "outcome": allowedOutcomes.contains(outcome)
                    ? outcome
                    : "failed",
            ]
        )
    }

    @MainActor
    static func logRealtimeTranscription(
        outcome: String,
        sessionID: UUID,
        characterCount: Int? = nil,
        durationMs: Int? = nil,
        reason: String? = nil
    ) {
        guard enabled else { return }
        let allowedOutcomes = ["started", "first_draft", "finished", "failed"]
        var attributes: [String: Any] = [
            "outcome": allowedOutcomes.contains(outcome)
                ? outcome
                : "unknown",
            "sessionID": sessionID.uuidString,
            "applicationState": applicationState(),
        ]
        if let characterCount {
            attributes["characterCount"] = String(max(0, characterCount))
        }
        if let durationMs {
            attributes["durationMs"] = String(max(0, durationMs))
        }
        if let reason {
            let allowed = CharacterSet.alphanumerics.union(
                CharacterSet(charactersIn: "_")
            )
            let normalized = String(
                reason.unicodeScalars
                    .filter { allowed.contains($0) }
                    .prefix(80)
            )
            attributes["reason"] = normalized.isEmpty
                ? "unknown"
                : normalized
        }
        if outcome == "failed" {
            SentrySDK.logger.warn(
                "elevenlabs.realtime_transcription",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.info(
                "elevenlabs.realtime_transcription",
                attributes: attributes
            )
        }
    }

    static func logTranscriptionFailed(
        reason: String,
        statusCode: Int?,
        message: String,
        surface: String? = nil,
        sessionID: UUID? = nil,
        partID: UUID? = nil,
        durationMs: Int? = nil,
        quality: AudioCaptureQualitySummary? = nil,
        preferredMicrophoneMode: String? = nil,
        activeMicrophoneMode: String? = nil
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "reason": reason,
            "message": message,
        ]
        if let statusCode {
            attributes["statusCode"] = String(statusCode)
        }
        if let surface {
            attributes["surface"] = surface
        }
        if let sessionID {
            attributes["sessionID"] = sessionID.uuidString
        }
        if let partID {
            attributes["partID"] = partID.uuidString
        }
        if let durationMs {
            attributes["durationMs"] = String(max(0, durationMs))
        }
        appendCaptureDetails(
            quality: quality,
            preferredMicrophoneMode: preferredMicrophoneMode,
            activeMicrophoneMode: activeMicrophoneMode,
            to: &attributes
        )
        SentrySDK.logger.error("elevenlabs.transcription_failed", attributes: attributes)
    }

    /// A successful transcript keeps its original audio in History while its
    /// exact capture statistics and microphone mode are attached to telemetry.
    static func logAudioDiagnosticRetained(_ record: AudioDiagnosticRecord) {
        guard enabled else { return }
        SentrySDK.logger.info(
            "elevenlabs.audio_diagnostic_retained",
            attributes: audioDiagnosticAttributes(record)
        )
    }

    static func logAudioDiagnosticArchiveFailure(reason: String) {
        guard enabled else { return }
        let allowed = [
            "audio_missing",
            "unsafe_source",
            "corrupt_record",
            "playback_failed",
            "storage",
        ]
        SentrySDK.logger.error(
            "elevenlabs.audio_diagnostic_archive_failed",
            attributes: ["reason": allowed.contains(reason) ? reason : "storage"]
        )
    }

    static func captureAudioDiagnosticReport(_ record: AudioDiagnosticRecord) {
        guard enabled else { return }
        let attributes = audioDiagnosticAttributes(record)
        SentrySDK.logger.warn(
            "elevenlabs.audio_diagnostic_reported_garbled",
            attributes: attributes
        )
        let issue = NSError(
            domain: "ElevenLabs.AudioDiagnostic",
            code: 2001,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "A retained dictation was reported as garbled.",
            ]
        )
        SentrySDK.capture(error: issue) { scope in
            scope.setTag(value: "reported_garbled", key: "operation")
            for (key, value) in attributes {
                scope.setTag(value: String(describing: value), key: key)
            }
        }
    }

    private static func audioDiagnosticAttributes(
        _ record: AudioDiagnosticRecord
    ) -> [String: Any] {
        var attributes: [String: Any] = [
            "signalClassification": record.quality.classification.rawValue,
            "activeMicrophoneMode": record.microphoneMode.active,
            "preferredMicrophoneMode": record.microphoneMode.preferred,
            "durationMs": String(
                max(0, Int((record.duration * 1_000).rounded()))
            ),
            "segmentCount": String(record.segments.count),
        ]
        appendCaptureDetails(
            quality: record.quality,
            preferredMicrophoneMode: nil,
            activeMicrophoneMode: nil,
            to: &attributes
        )
        if let languageProbability = record.languageProbability {
            attributes["languageProbability"] = String(languageProbability)
        }
        return attributes
    }

    /// Reports that one child segment contained no recognized speech while a
    /// later segment remains eligible to complete the parent dictation.
    static func logSegmentTranscriptionSkipped(
        surface: String,
        reason: String
    ) {
        guard enabled else { return }
        SentrySDK.logger.warn(
            "elevenlabs.segment_transcription_skipped",
            attributes: [
                "surface": surface,
                "reason": reason,
            ]
        )
    }

    /// Records the bounded recovery state and the exact capture measurements
    /// seen when the recorder clock advanced without audible speech.
    @MainActor
    static func logSilentCapture(
        surface: String,
        action: String,
        elapsedMs: Int,
        quality: AudioCaptureQualitySummary? = nil,
        preferredMicrophoneMode: String? = nil,
        activeMicrophoneMode: String? = nil
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "surface": surface,
            "applicationState": applicationState(),
            "action": action,
            "elapsedMs": String(max(0, elapsedMs)),
        ]
        appendCaptureDetails(
            quality: quality,
            preferredMicrophoneMode: preferredMicrophoneMode,
            activeMicrophoneMode: activeMicrophoneMode,
            to: &attributes
        )
        switch action {
        case "recycle_succeeded":
            SentrySDK.logger.info(
                "elevenlabs.silent_capture_recovery",
                attributes: attributes
            )
        case "recycle_started":
            SentrySDK.logger.warn(
                "elevenlabs.silent_capture_recovery",
                attributes: attributes
            )
        default:
            SentrySDK.logger.error(
                "elevenlabs.silent_capture_recovery",
                attributes: attributes
            )
        }
    }

    /// App Intents otherwise return errors only to iOS. Keep an operation-level
    /// record without serializing arbitrary error descriptions.
    @MainActor
    static func logDictationIntentFailure(
        _ error: any Error,
        operation: String
    ) {
        guard enabled else { return }
        var attributes: [String: Any] = [
            "operation": operation,
            "applicationState": applicationState(),
            "reason": "operationFailed",
        ]
        if let clientError = error as? ElevenLabsClientError {
            attributes["reason"] = clientError.category.rawValue
            if case let .api(statusCode, _) = clientError {
                attributes["statusCode"] = String(statusCode)
            }
        } else if let recorderError = error as? AudioRecorderError {
            let descriptor = AudioRecorderFailureDescriptor(error: recorderError)
            attributes["reason"] = descriptor.reason
            attributes["stage"] = descriptor.stage
            attributes["issueCode"] = String(descriptor.issueCode)
            if let systemDomain = descriptor.systemDomain {
                attributes["systemDomain"] = systemDomain
            }
            if let systemCode = descriptor.systemCode {
                attributes["systemCode"] = String(systemCode)
            }
        }
        SentrySDK.logger.error(
            "elevenlabs.dictation_intent_failed",
            attributes: attributes
        )
    }

    /// Confirms that ElevenLabs relinquished media focus after capture. A
    /// failed synchronous release is retried locally; only stable reason and
    /// numeric AVFoundation error categories leave the device.
    @MainActor
    static func logAudioSessionRelease(
        reason: String,
        outcome: String,
        attempt: Int,
        otherAudioWasPlaying: Bool,
        systemDomain: String? = nil,
        systemCode: Int? = nil,
        outputRouteBeforeRelease: String,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["reason"] = reason
        attributes["outcome"] = outcome
        attributes["attempt"] = String(max(1, attempt))
        attributes["otherAudioWasPlaying"] = String(otherAudioWasPlaying)
        attributes["outputRouteBeforeRelease"] = outputRouteBeforeRelease
        if let systemDomain {
            attributes["systemDomain"] = systemDomain
        }
        if let systemCode {
            attributes["systemCode"] = String(systemCode)
        }
        switch outcome {
        case "released":
            SentrySDK.logger.info(
                "elevenlabs.audio_session_release",
                attributes: attributes
            )
        case "retrying":
            SentrySDK.logger.warn(
                "elevenlabs.audio_session_release",
                attributes: attributes
            )
        default:
            SentrySDK.logger.error(
                "elevenlabs.audio_session_release",
                attributes: attributes
            )
        }
    }

    /// Tracks the public AVAudioSession state machine around configuration and
    /// activation. Attribute values are booleans and coarse route/category
    /// classes only; device names and identifiers never cross this boundary.
    @MainActor
    static func logAudioSessionTransition(
        stage: String,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        let allowedStages = [
            "before_configuration",
            "configured",
            "activated",
        ]
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["stage"] = allowedStages.contains(stage) ? stage : "unknown"
        SentrySDK.logger.info(
            "elevenlabs.audio_session_transition",
            attributes: attributes
        )
    }

    @MainActor
    static func logAudioRouteChanged(
        reason: String,
        previousOutputRoute: String,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["reason"] = reason
        attributes["previousOutputRoute"] = previousOutputRoute
        SentrySDK.logger.info(
            "elevenlabs.audio_route_changed",
            attributes: attributes
        )
    }

    @MainActor
    static func logAudioSpeakerFallbackFailed(
        systemDomain: String,
        systemCode: Int,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["systemDomain"] = systemDomain
        attributes["systemCode"] = String(systemCode)
        SentrySDK.logger.warn(
            "elevenlabs.audio_speaker_fallback_failed",
            attributes: attributes
        )
    }

    /// A successful deactivation is not proof that the interrupted app began
    /// playing again. This delayed observation records only iOS's public
    /// other-audio hint, never the player identity or media metadata.
    @MainActor
    static func logOtherAudioRecoveryObservation(
        reason: String,
        observationMilliseconds: Int,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["reason"] = reason
        attributes["observationMilliseconds"] = String(
            max(0, observationMilliseconds)
        )
        if snapshot.otherAudioIsPlayingNow {
            SentrySDK.logger.info(
                "elevenlabs.other_audio_recovery_observation",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.warn(
                "elevenlabs.other_audio_recovery_observation",
                attributes: attributes
            )
        }
    }

    /// A missing Live Activity must never serialize ActivityKit's arbitrary
    /// localized error, but it does need to be distinguishable from an audio
    /// capture failure when a device reports only the generic microphone UI.
    static func logLiveActivityFailure(operation: String) {
        guard enabled else { return }
        SentrySDK.logger.warn(
            "elevenlabs.live_activity_failed",
            attributes: ["operation": operation]
        )
    }

    /// Records only whether a protected return target existed and which
    /// lifecycle boundary supplied it. Host names, bundle identifiers, and
    /// process identifiers deliberately stay in the on-device diagnostics.
    @MainActor
    static func logLiveActivityHostResolution(
        available: Bool,
        evidence: String
    ) {
        guard enabled else { return }
        let attributes: [String: Any] = [
            "available": available ? "true" : "false",
            "evidence": evidence,
            "applicationState": applicationState(),
        ]
        if available {
            SentrySDK.logger.info(
                "elevenlabs.live_activity_host_resolution",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.warn(
                "elevenlabs.live_activity_host_resolution",
                attributes: attributes
            )
        }
    }

    @MainActor
    static func logHostReturn(didOpen: Bool, attemptCount: Int) {
        guard enabled else { return }
        let attributes: [String: Any] = [
            "outcome": didOpen ? "opened" : "failed",
            "attemptCount": String(max(0, attemptCount)),
            "applicationState": applicationState(),
        ]
        if didOpen {
            SentrySDK.logger.info(
                "elevenlabs.keyboard_host_return",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.warn(
                "elevenlabs.keyboard_host_return",
                attributes: attributes
            )
        }
    }

    /// Captures the throwing AVAudioEngine hardware-start boundary. The system
    /// domain and code explain a policy refusal without collecting audio, a
    /// file path, or any other user data.
    @MainActor
    static func logAudioRecorderStartAttempt(
        captureAttemptID: UUID,
        attempt: Int,
        elapsedMilliseconds: Int,
        outcome: AudioRecorderStartAttemptOutcome,
        action: AudioRecorderStartAttemptAction,
        retryDelayMilliseconds: Int?,
        systemFailure: AudioCaptureStartSystemFailure?,
        diagnostic: AudioSystemDiagnostic?,
        hadPriorSuccessfulRecorderStart: Bool,
        sessionWasRecycled: Bool,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["captureAttemptID"] =
            captureAttemptID.uuidString.lowercased()
        attributes["attempt"] = String(max(1, attempt))
        attributes["elapsedMilliseconds"] = String(
            max(0, elapsedMilliseconds)
        )
        attributes["outcome"] = outcome.rawValue
        attributes["retryAction"] = action.rawValue
        attributes["hadPriorSuccessfulRecorderStart"] = String(
            hadPriorSuccessfulRecorderStart
        )
        attributes["sessionWasRecycled"] = String(sessionWasRecycled)
        if let retryDelayMilliseconds {
            attributes["retryDelayMilliseconds"] = String(
                max(0, retryDelayMilliseconds)
            )
        }
        if let systemFailure {
            attributes["systemFailure"] = systemFailure.rawValue
        }
        if let diagnostic {
            attributes["systemDomain"] = diagnostic.domain.rawValue
            attributes["systemCode"] = String(diagnostic.code)
        }

        if outcome == .started {
            SentrySDK.logger.info(
                "elevenlabs.audio_engine_start_attempt",
                attributes: attributes
            )
        } else {
            SentrySDK.logger.warn(
                "elevenlabs.audio_engine_start_attempt",
                attributes: attributes
            )
        }
    }

    /// Records each bounded activation attempt so a physical trace can prove
    /// whether the app lost its background grant before recorder creation.
    @MainActor
    static func logAudioSessionActivationAttempt(
        captureAttemptID: UUID,
        context: String,
        attempt: Int,
        outcome: String,
        retryDelayMilliseconds: Int?,
        systemDomain: String?,
        systemCode: Int?,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        let allowedContexts = ["initial"]
        let allowedOutcomes = ["activated", "retrying", "failed"]
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["captureAttemptID"] =
            captureAttemptID.uuidString.lowercased()
        attributes["context"] = allowedContexts.contains(context)
            ? context
            : "unknown"
        attributes["attempt"] = String(max(1, attempt))
        attributes["outcome"] = allowedOutcomes.contains(outcome)
            ? outcome
            : "unknown"
        if let retryDelayMilliseconds {
            attributes["retryDelayMilliseconds"] = String(
                max(0, retryDelayMilliseconds)
            )
        }
        if let systemDomain {
            attributes["systemDomain"] = systemDomain
        }
        if let systemCode {
            attributes["systemCode"] = String(systemCode)
        }

        switch outcome {
        case "activated":
            SentrySDK.logger.info(
                "elevenlabs.audio_session_activation_attempt",
                attributes: attributes
            )
        case "retrying":
            SentrySDK.logger.warn(
                "elevenlabs.audio_session_activation_attempt",
                attributes: attributes
            )
        default:
            SentrySDK.logger.error(
                "elevenlabs.audio_session_activation_attempt",
                attributes: attributes
            )
        }
    }

    @MainActor
    static func logAudioCaptureStarted(
        surface: String,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        SentrySDK.logger.info(
            "elevenlabs.audio_capture_started",
            attributes: audioCaptureAttributes(
                surface: surface,
                snapshot: snapshot
            )
        )
    }

    /// Emits both a structured log and a grouped Sentry issue without passing
    /// AVFoundation's localized description. Only stable state categories,
    /// route classes, and whitelisted numeric system codes cross this boundary.
    @MainActor
    static func captureAudioFailure(
        surface: String,
        reason: String,
        stage: String,
        issueCode: Int,
        systemDomain: String?,
        systemCode: Int?,
        snapshot: AudioCaptureObservabilitySnapshot
    ) {
        guard enabled else { return }
        var attributes = audioCaptureAttributes(
            surface: surface,
            snapshot: snapshot
        )
        attributes["reason"] = reason
        attributes["stage"] = stage
        attributes["issueCode"] = String(issueCode)
        if let systemDomain {
            attributes["systemDomain"] = systemDomain
        }
        if let systemCode {
            attributes["systemCode"] = String(systemCode)
        }
        SentrySDK.logger.error(
            "elevenlabs.audio_capture_failed",
            attributes: attributes
        )

        let sanitizedError = NSError(
            domain: "ElevenLabs.AudioCapture",
            code: issueCode,
            userInfo: [
                NSLocalizedDescriptionKey: "Audio capture failed during \(stage).",
            ]
        )
        SentrySDK.capture(error: sanitizedError) { scope in
            scope.setTag(value: "audio_capture_start", key: "operation")
            scope.setTag(value: surface, key: "surface")
            scope.setTag(value: reason, key: "reason")
            scope.setTag(value: stage, key: "stage")
            scope.setTag(value: applicationState(), key: "application_state")
            scope.setTag(value: String(snapshot.attempts), key: "attempts")
            scope.setTag(value: snapshot.category, key: "audio_category")
            scope.setTag(
                value: snapshot.sessionActivationState,
                key: "audio_session_state"
            )
            scope.setTag(
                value: String(snapshot.otherAudioWasPlayingAtStart),
                key: "other_audio_playing"
            )
            scope.setTag(
                value: String(snapshot.mixingEnabled),
                key: "mixing_enabled"
            )
            scope.setTag(
                value: String(snapshot.duckingEnabled),
                key: "ducking_enabled"
            )
            scope.setTag(
                value: String(snapshot.bluetoothA2DPOutputEnabled),
                key: "bluetooth_a2dp_output_enabled"
            )
            scope.setTag(
                value: String(snapshot.defaultToSpeakerEnabled),
                key: "default_to_speaker_enabled"
            )
            scope.setTag(
                value: String(snapshot.speakerFallbackApplied),
                key: "speaker_fallback_applied"
            )
            scope.setTag(value: snapshot.inputRoute, key: "input_route")
            scope.setTag(value: snapshot.outputRoute, key: "output_route")
            if let systemDomain {
                scope.setTag(value: systemDomain, key: "system_domain")
            }
            if let systemCode {
                scope.setTag(value: String(systemCode), key: "system_code")
            }
        }
    }

    @MainActor
    private static func audioCaptureAttributes(
        surface: String,
        snapshot: AudioCaptureObservabilitySnapshot
    ) -> [String: Any] {
        var attributes = audioSessionAttributes(snapshot: snapshot)
        attributes["surface"] = surface
        return attributes
    }

    @MainActor
    private static func audioSessionAttributes(
        snapshot: AudioCaptureObservabilitySnapshot
    ) -> [String: Any] {
        [
            "applicationState": applicationState(),
            "attempts": String(snapshot.attempts),
            "sessionActivationState": snapshot.sessionActivationState,
            "category": snapshot.category,
            "otherAudioPlaying": String(snapshot.otherAudioWasPlayingAtStart),
            "otherAudioPlayingNow": String(snapshot.otherAudioIsPlayingNow),
            "secondaryAudioShouldBeSilenced": String(snapshot.secondaryAudioShouldBeSilenced),
            "mixingEnabled": String(snapshot.mixingEnabled),
            "duckingEnabled": String(snapshot.duckingEnabled),
            "bluetoothA2DPOutputEnabled": String(snapshot.bluetoothA2DPOutputEnabled),
            "defaultToSpeakerEnabled": String(snapshot.defaultToSpeakerEnabled),
            "speakerFallbackApplied": String(snapshot.speakerFallbackApplied),
            "inputRoute": snapshot.inputRoute,
            "outputRoute": snapshot.outputRoute,
        ]
    }

    @MainActor
    private static func applicationState() -> String {
        #if os(iOS)
        switch UIApplication.shared.applicationState {
        case .active:
            "active"
        case .inactive:
            "inactive"
        case .background:
            "background"
        @unknown default:
            "unknown"
        }
        #else
        "active"
        #endif
    }

    static func logTranscriptionFailure(
        _ error: Error,
        surface: String? = nil,
        sessionID: UUID? = nil,
        partID: UUID? = nil,
        durationMs: Int? = nil,
        quality: AudioCaptureQualitySummary? = nil,
        preferredMicrophoneMode: String? = nil,
        activeMicrophoneMode: String? = nil
    ) {
        guard enabled else { return }

        guard let clientError = error as? ElevenLabsClientError else {
            logTranscriptionFailed(
                reason: "unknown",
                statusCode: nil,
                message: String(describing: error),
                surface: surface,
                sessionID: sessionID,
                partID: partID,
                durationMs: durationMs,
                quality: quality,
                preferredMicrophoneMode: preferredMicrophoneMode,
                activeMicrophoneMode: activeMicrophoneMode
            )
            return
        }

        let statusCode: Int? = if case let .api(code, _) = clientError {
            code
        } else {
            nil
        }

        logTranscriptionFailed(
            reason: clientError.category.rawValue,
            statusCode: statusCode,
            message: clientError.localizedDescription,
            surface: surface,
            sessionID: sessionID,
            partID: partID,
            durationMs: durationMs,
            quality: quality,
            preferredMicrophoneMode: preferredMicrophoneMode,
            activeMicrophoneMode: activeMicrophoneMode
        )
    }

    private static func appendCaptureDetails(
        quality: AudioCaptureQualitySummary?,
        preferredMicrophoneMode: String?,
        activeMicrophoneMode: String?,
        to attributes: inout [String: Any]
    ) {
        if let quality {
            attributes["signalClassification"] =
                quality.classification.rawValue
            attributes["sampleCount"] = String(quality.sampleCount)
            attributes["audibleFraction"] = String(quality.audibleFraction)
            attributes["averageLevel"] = String(quality.averageLevel)
            attributes["peakLevel"] = String(quality.peakLevel)
            attributes["clippingFraction"] =
                String(quality.clippingFraction)
        }
        if let preferredMicrophoneMode {
            attributes["preferredMicrophoneMode"] = preferredMicrophoneMode
        }
        if let activeMicrophoneMode {
            attributes["activeMicrophoneMode"] = activeMicrophoneMode
        }
    }

    // MARK: - Errors

    /// Captures an error with a stable operation tag. The error's own
    /// description is sent, so only errors known to be free of transcript,
    /// audio, or key material may be passed here.
    static func capture(_ error: Error, operation: String) {
        guard enabled else { return }
        SentrySDK.capture(error: error) { scope in
            scope.setTag(value: operation, key: "operation")
        }
    }

    /// Flushes buffered events before the process exits.
    static func flush(timeout: TimeInterval = 2) {
        guard enabled else { return }
        SentrySDK.flush(timeout: timeout)
    }
}
