import Foundation

/// A short history of real microphone energy. Each value is a normalized
/// envelope sample. Keeping the last few samples lets
/// compact Live Activity bars describe the cadence of speech instead of
/// scaling an unrelated canned pattern with one scalar level.
struct VoiceMeterEnvelope: Equatable, Sendable {
    private(set) var levels: [Float]

    init(sampleCount: Int = 5) {
        levels = Array(repeating: 0, count: max(3, sampleCount))
    }

    @discardableResult
    mutating func observe(
        averageLevel: Float,
        peakLevel: Float
    ) -> [Float] {
        let average = min(1, max(0, averageLevel))
        let peak = min(1, max(0, peakLevel))
        let voiceEnergy = max(average, peak * 0.72)
        let previous = levels.last ?? 0
        let response: Float = voiceEnergy >= previous ? 0.72 : 0.30
        let smoothed = previous + ((voiceEnergy - previous) * response)
        levels.removeFirst()
        levels.append(min(1, max(0, smoothed)))
        return levels
    }

    mutating func reset() {
        levels = Array(repeating: 0, count: levels.count)
    }
}

enum AudioRecorderStartStage: String, Sendable {
    case interruption
    case preparation
    case recording
}

/// The temporary iPhone audio-session behavior used while capturing speech.
/// Keeping this policy independent of AVFoundation makes the product contract
/// directly testable even though AVAudioSession itself is unavailable to the
/// package's macOS logic tests.
struct AudioRecorderSessionPolicy: Equatable, Sendable {
    static let standard = AudioRecorderSessionPolicy(
        primaryConfiguration: .mediaPreservingPlayAndRecord,
        mixesWithOthers: true,
        ducksOthers: false,
        allowsBluetoothA2DPOutput: true,
        usesConditionalBuiltInSpeakerFallback: true
    )

    let primaryConfiguration: AudioRecorderSessionConfiguration
    let mixesWithOthers: Bool
    let ducksOthers: Bool
    let allowsBluetoothA2DPOutput: Bool
    let usesConditionalBuiltInSpeakerFallback: Bool
}

enum AudioRecorderSessionConfiguration: Equatable, Sendable {
    /// Keeps existing media alive at its current volume and allows a headless
    /// Control Center intent to activate capture while the app is backgrounded.
    /// `playAndRecord` keeps A2DP eligible; the input-only `record` category
    /// does not.
    case mediaPreservingPlayAndRecord
}

enum AudioRecorderOutputRouteKind: Equatable, Sendable {
    case none
    case receiver
    case speaker
    case external
}

/// Never force the speaker over a user-selected accessory. The only route
/// ElevenLabs corrects is play-and-record's built-in receiver fallback.
enum AudioRecorderOutputRoutePolicy {
    static func shouldApplySpeakerFallback(
        to route: AudioRecorderOutputRouteKind
    ) -> Bool {
        route == .receiver
    }
}

/// A preferred input can remain pinned even after iOS drops that input from
/// the active route. Treat the live route as the source of truth so a startup
/// retry repairs that stale preference instead of repeatedly constructing
/// recorders against a route with no input.
enum AudioRecorderInputRoutePolicy {
    static func shouldSetPreferredBuiltInInput(
        preferredInputIsBuiltIn: Bool,
        currentInputIsBuiltIn: Bool,
        forceReassertion: Bool
    ) -> Bool {
        forceReassertion
            || !preferredInputIsBuiltIn
            || !currentInputIsBuiltIn
    }
}

enum AudioRecorderStartRetryAction: Equatable, Sendable {
    /// Preserve the background recording grant, repair its input route, and
    /// try one fresh recorder after the route has had time to settle.
    case repairRouteKeepingSessionActive(afterMilliseconds: Int)
    case fail

    var delayMilliseconds: Int? {
        switch self {
        case let .repairRouteKeepingSessionActive(afterMilliseconds):
            afterMilliseconds
        case .fail:
            nil
        }
    }

    var observabilityName: String {
        switch self {
        case .repairRouteKeepingSessionActive:
            "repair_route_active"
        case .fail:
            "fail"
        }
    }
}

/// A throwing AVAudioEngine start reports the operating-system reason that
/// AVAudioRecorder's Boolean `record()` API hides. Policy errors are not
/// transient: while the intent is in the background, retrying the same call
/// cannot change whether iOS permits capture. Route repair remains available
/// only for the one typed state that says the session has not become active.
enum AudioCaptureStartFailureDecision: Equatable, Sendable {
    case continueInForeground
    case repairRouteKeepingSessionActive(afterMilliseconds: Int)
    case fail

    var observabilityAction: AudioRecorderStartAttemptAction {
        switch self {
        case .continueInForeground:
            .continueInForeground
        case .repairRouteKeepingSessionActive:
            .repairRouteKeepingSessionActive
        case .fail:
            .fail
        }
    }
}

enum AudioSystemErrorDomain: String, Equatable, Sendable {
    case osStatus = "os_status"
    case avFoundation = "av_foundation"
    case cocoa
    case posix
    case avfaudio
    case other
}

struct AudioSystemDiagnostic: Equatable, Sendable {
    let domain: AudioSystemErrorDomain
    let code: Int
}

enum AudioCaptureStartSystemFailure: String, Equatable, Sendable {
    case noError = "no_error"
    case mediaServicesFailed = "media_services_failed"
    case busy
    case incompatibleCategory = "incompatible_category"
    case cannotInterruptOthers = "cannot_interrupt_others"
    case missingEntitlement = "missing_entitlement"
    case siriIsRecording = "siri_is_recording"
    case cannotStartPlaying = "cannot_start_playing"
    case cannotStartRecording = "cannot_start_recording"
    case badParameter = "bad_parameter"
    case insufficientPriority = "insufficient_priority"
    case resourceNotAvailable = "resource_not_available"
    case unspecified
    case expiredSession = "expired_session"
    case sessionNotActive = "session_not_active"
    case unknownCode = "unknown_code"
}

struct AudioCaptureStartError: Error, Equatable, Sendable {
    let failure: AudioCaptureStartSystemFailure
    let diagnostic: AudioSystemDiagnostic
}

enum AudioRecorderStartAttemptOutcome: String, Equatable, Sendable {
    case started
    case engineStartFailed = "engine_start_failed"
}

enum AudioRecorderStartAttemptAction: String, Equatable, Sendable {
    case none
    case repairRouteKeepingSessionActive = "repair_route_active"
    case continueInForeground = "continue_foreground"
    case fail
}

enum AudioCaptureApplicationState: Equatable, Sendable {
    case active
    case inactive
    case background
}

enum AudioCaptureStartFailurePolicy {
    static func decision(
        failure: AudioCaptureStartSystemFailure,
        applicationState: AudioCaptureApplicationState,
        failedAttempt: Int,
        retryPolicy: AudioRecorderStartRetryPolicy
    ) -> AudioCaptureStartFailureDecision {
        switch failure {
        case .cannotInterruptOthers,
             .cannotStartPlaying,
             .cannotStartRecording,
             .insufficientPriority,
             .unspecified:
            return applicationState == .active
                ? .fail
                : .continueInForeground
        case .sessionNotActive:
            guard let delay = retryPolicy.delayMilliseconds(
                afterFailedAttempt: failedAttempt
            ) else {
                return .fail
            }
            return .repairRouteKeepingSessionActive(afterMilliseconds: delay)
        case .noError,
             .mediaServicesFailed,
             .busy,
             .incompatibleCategory,
             .missingEntitlement,
             .siriIsRecording,
             .badParameter,
             .resourceNotAvailable,
             .expiredSession,
             .unknownCode:
            return .fail
        }
    }
}

/// Bounded settling time for session activation and the one typed engine-start
/// failure (`sessionNotActive`) that can become true without changing runtime
/// policy. Other throwing start failures are surfaced immediately.
struct AudioRecorderStartRetryPolicy: Equatable, Sendable {
    static let standard = AudioRecorderStartRetryPolicy(
        retryDelaysMilliseconds: [250]
    )

    let retryDelaysMilliseconds: [Int]

    init(retryDelaysMilliseconds: [Int]) {
        self.retryDelaysMilliseconds = retryDelaysMilliseconds.map { max(0, $0) }
    }

    var maximumAttempts: Int {
        retryDelaysMilliseconds.count + 1
    }

    var totalRetryDelayMilliseconds: Int {
        retryDelaysMilliseconds.reduce(0, +)
    }

    /// `failedAttempt` is zero-based. A nil delay means the bounded retry
    /// budget is exhausted and the current failure must be surfaced.
    func delayMilliseconds(afterFailedAttempt failedAttempt: Int) -> Int? {
        guard retryDelaysMilliseconds.indices.contains(failedAttempt) else {
            return nil
        }
        return retryDelaysMilliseconds[failedAttempt]
    }

    func action(
        afterFailedAttempt failedAttempt: Int
    ) -> AudioRecorderStartRetryAction {
        guard let delay = delayMilliseconds(
            afterFailedAttempt: failedAttempt
        ) else {
            return .fail
        }

        return .repairRouteKeepingSessionActive(
            afterMilliseconds: delay
        )
    }
}

/// A recorder can finish synchronously while AVFoundation is still releasing
/// its last I/O object. Retry media-focus release for a short, bounded window
/// so an interrupted player receives the deactivation notification even when
/// the first call reports a transient busy state.
struct AudioSessionReleaseRetryPolicy: Equatable, Sendable {
    static let standard = AudioSessionReleaseRetryPolicy(
        retryDelaysMilliseconds: [120, 360, 720]
    )

    let retryDelaysMilliseconds: [Int]

    init(retryDelaysMilliseconds: [Int]) {
        self.retryDelaysMilliseconds = retryDelaysMilliseconds.map { max(0, $0) }
    }

    var maximumAttempts: Int { retryDelaysMilliseconds.count + 1 }

    func delayMilliseconds(afterFailedAttempt failedAttempt: Int) -> Int? {
        guard retryDelaysMilliseconds.indices.contains(failedAttempt) else {
            return nil
        }
        return retryDelaysMilliseconds[failedAttempt]
    }
}

struct AudioCaptureObservabilitySnapshot: Equatable, Sendable {
    let attempts: Int
    let sessionActivationState: String
    let category: String
    let otherAudioWasPlayingAtStart: Bool
    let otherAudioIsPlayingNow: Bool
    let secondaryAudioShouldBeSilenced: Bool
    let mixingEnabled: Bool
    let duckingEnabled: Bool
    let bluetoothA2DPOutputEnabled: Bool
    let defaultToSpeakerEnabled: Bool
    let speakerFallbackApplied: Bool
    let inputRoute: String
    let outputRoute: String
}

enum AudioCaptureSignalClassification: String, Codable, Equatable, Sendable {
    case noSamples = "no_samples"
    case mostlySilent = "mostly_silent"
    case quiet
    case healthy
    case clippingRisk = "clipping_risk"
}

/// Capture statistics used both for local recovery and remote diagnostics.
struct AudioCaptureQualitySummary: Codable, Equatable, Sendable {
    static let empty = AudioCaptureQualitySummary(
        sampleCount: 0,
        audibleFraction: 0,
        averageLevel: 0,
        peakLevel: 0,
        clippingFraction: 0,
        classification: .noSamples
    )

    let sampleCount: Int
    let audibleFraction: Double
    let averageLevel: Double
    let peakLevel: Double
    let clippingFraction: Double
    let classification: AudioCaptureSignalClassification

    var audibleFractionBucket: String {
        switch audibleFraction {
        case ..<0.05: "none"
        case ..<0.25: "low"
        case ..<0.70: "medium"
        default: "high"
        }
    }

    var peakLevelBucket: String {
        switch peakLevel {
        case ..<0.025: "silent"
        case ..<0.12: "quiet"
        case ..<0.50: "speech"
        case ..<0.90: "loud"
        default: "near_clipping"
        }
    }
}

/// Small, deterministic policy object so quality classification can be tested
/// without a live audio engine or a physical microphone.
struct AudioCaptureQualityTracker: Sendable {
    private(set) var sampleCount = 0
    private(set) var audibleSampleCount = 0
    private(set) var clippingSampleCount = 0
    private(set) var accumulatedLevel: Double = 0
    private(set) var peakLevel: Double = 0

    mutating func observe(
        normalizedLevel: Float,
        averagePowerDecibels: Float,
        peakPowerDecibels: Float
    ) {
        let level = Double(max(0, min(1, normalizedLevel.isFinite ? normalizedLevel : 0)))
        sampleCount += 1
        accumulatedLevel += level
        peakLevel = max(peakLevel, level)
        if averagePowerDecibels.isFinite, averagePowerDecibels >= -50 {
            audibleSampleCount += 1
        }
        if peakPowerDecibels.isFinite, peakPowerDecibels >= -1 {
            clippingSampleCount += 1
        }
    }

    var summary: AudioCaptureQualitySummary {
        guard sampleCount > 0 else { return .empty }
        let count = Double(sampleCount)
        let audibleFraction = Double(audibleSampleCount) / count
        let averageLevel = accumulatedLevel / count
        let clippingFraction = Double(clippingSampleCount) / count
        let classification: AudioCaptureSignalClassification
        if clippingFraction >= 0.03 {
            classification = .clippingRisk
        } else if audibleFraction < 0.05 {
            classification = .mostlySilent
        } else if audibleFraction < 0.25 || averageLevel < 0.08 {
            classification = .quiet
        } else {
            classification = .healthy
        }
        return AudioCaptureQualitySummary(
            sampleCount: sampleCount,
            audibleFraction: audibleFraction,
            averageLevel: averageLevel,
            peakLevel: peakLevel,
            clippingFraction: clippingFraction,
            classification: classification
        )
    }
}

struct AudioRecorderFailureDescriptor: Equatable, Sendable {
    let reason: String
    let stage: String
    let issueCode: Int
    let systemDomain: String?
    let systemCode: Int?
}

enum SessionElapsedDurationPolicy {
    static func total(
        accumulatedDuration: TimeInterval,
        liveRecorderDuration: TimeInterval,
        finalizedSegmentDuration: TimeInterval,
        isRecording: Bool,
        hasActiveRecordingReference: Bool
    ) -> TimeInterval {
        let accumulated = max(0, accumulatedDuration)
        if isRecording {
            return accumulated + max(0, liveRecorderDuration)
        }
        if hasActiveRecordingReference {
            return accumulated + max(0, finalizedSegmentDuration)
        }
        // Once a paused segment is banked, accumulatedDuration already includes
        // it. Ignore the engine's stale stopped duration instead of
        // showing that segment twice or resetting the next continuation to 0.
        return accumulated
    }
}
