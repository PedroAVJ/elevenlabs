import ActivityKit
import Foundation

struct ElevenLabsActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Mutable because microphone activation happens after the Live
        /// Activity is created. The timer must begin only once capture is real.
        var recordingStartedAt: Date?
        /// Total hot-microphone time already banked before the current segment.
        /// Pauses freeze this value; resumes use it to anchor a continuous timer
        /// without keeping the microphone alive.
        var elapsedDuration: TimeInterval
        /// A bounded frame advanced by the recording process. Live Activities
        /// don't run arbitrary looping animations, so changing real content is
        /// what lets WidgetKit animate the waveform and progress indicator.
        /// Optional keeps activities created by an older installed build
        /// decodable across an update.
        var visualizationFrame: UInt8?
        /// Normalized microphone energy for the widget's 0...1 meter range.
        var audioLevel: Double?
        /// Recent normalized envelope samples from the real microphone meter.
        /// This remains optional so a Live Activity created by an older binary
        /// can be decoded after an update.
        var meterLevels: [Double]?

        init(
            phase: Phase,
            recordingStartedAt: Date? = nil,
            elapsedDuration: TimeInterval = 0,
            visualizationFrame: UInt8? = nil,
            audioLevel: Double? = nil,
            meterLevels: [Double]? = nil
        ) {
            self.phase = phase
            self.recordingStartedAt = recordingStartedAt
            self.elapsedDuration = max(0, elapsedDuration)
            self.visualizationFrame = visualizationFrame
            self.audioLevel = audioLevel.map { min(1, max(0, $0)) }
            self.meterLevels = meterLevels.map {
                Array($0.prefix(21)).map { min(1, max(0, $0)) }
            }
        }
    }

    enum Phase: String, Codable, Hashable {
        case idle
        case starting
        case recording
        case pausing
        case paused
        case resuming
        case transcribing
        case completed
        case failed
        case cancelled

        var title: String {
            switch self {
            case .idle: "Ready"
            case .starting: "Starting"
            case .recording: "Recording"
            case .pausing: "Pausing"
            case .paused: "Paused"
            case .resuming: "Resuming"
            case .transcribing: "Transcribing"
            case .completed: "Transcript ready"
            case .failed: "Dictation failed"
            case .cancelled: "Cancelled"
            }
        }

        var systemImageName: String {
            switch self {
            case .idle: "mic.fill"
            case .starting: "waveform"
            case .recording: "waveform"
            case .pausing: "waveform"
            case .paused: "pause.fill"
            case .resuming: "waveform"
            case .transcribing: "ellipsis"
            case .completed: "checkmark"
            case .failed: "exclamationmark"
            case .cancelled: "xmark"
            }
        }

        /// Successful delivery and explicit cancellation close the recording
        /// session while preserving the Live Activity as the next launcher.
        var returnsToIdleLauncher: Bool {
            self == .completed || self == .cancelled
        }
    }

    var sessionID: UUID
    /// Creation time retained as immutable session metadata. Recording UI uses
    /// `ContentState.recordingStartedAt`, which is set after audio activation.
    var startedAt: Date
}
