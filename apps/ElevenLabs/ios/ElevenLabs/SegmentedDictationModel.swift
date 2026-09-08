import Foundation

/// Process-local capture state for one intent-driven dictation. Keeping the
/// transition table separate from AVFoundation makes duplicate Back Taps and
/// stale Live Activity commands deterministic even while an async transition
/// temporarily re-enters the main actor.
enum SegmentedDictationCaptureState: Equatable, Sendable {
    case idle
    case starting
    case recording
    case recoveringSilentCapture
    case pausing
    case paused
    case resuming
    case closing

    enum ToggleAction: Equatable, Sendable {
        case start
        case pause
        case resume
        case none
    }

    var toggleAction: ToggleAction {
        switch self {
        case .idle:
            .start
        case .recording:
            .pause
        case .paused:
            .resume
        case .starting,
             .recoveringSilentCapture,
             .pausing,
             .resuming,
             .closing:
            .none
        }
    }
}

enum SegmentedNoAudioRecoveryAction: Equatable, Sendable {
    case ignore
    case recycleCapture
    case reportPersistentSilence
}

/// A recorder can advance its clock while AVAudioSession delivers only
/// silence. Recycle that route once, then leave later silence non-destructive:
/// the user may intentionally wait before speaking and every audio segment
/// must remain available for recovery.
struct SegmentedNoAudioRecoveryPolicy: Sendable {
    private var didRecycleCapture = false

    mutating func action(
        for captureState: SegmentedDictationCaptureState
    ) -> SegmentedNoAudioRecoveryAction {
        guard captureState == .recording else { return .ignore }
        guard !didRecycleCapture else { return .reportPersistentSilence }
        didRecycleCapture = true
        return .recycleCapture
    }
}

struct SegmentedTranscriptPiece: Equatable, Sendable {
    let ordinal: Int
    let text: String
    let languageCode: String?
}

struct SegmentedTranscriptAssembly: Equatable, Sendable {
    let text: String
    let languageCode: String?
}

enum SegmentedTranscriptAssembler {
    /// Segment requests finish independently, so completion order is not spoken
    /// order. Normalize only the seams introduced by pause/resume and otherwise
    /// leave Scribe's punctuation and casing untouched.
    static func assemble(
        _ pieces: [SegmentedTranscriptPiece]
    ) -> SegmentedTranscriptAssembly? {
        let ordered = pieces.sorted {
            if $0.ordinal == $1.ordinal {
                return $0.text < $1.text
            }
            return $0.ordinal < $1.ordinal
        }
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }

        let languageCodes = Set(
            ordered.compactMap { piece -> String? in
                let code = piece.languageCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return code?.isEmpty == false ? code : nil
            }
        )
        return SegmentedTranscriptAssembly(
            text: text,
            languageCode: languageCodes.count == 1
                ? languageCodes.first
                : nil
        )
    }
}

enum SegmentedTranscriptFailurePolicy {
    /// One automatically recycled silent segment must not erase speech that a
    /// later segment captured. Every other failure remains terminal so network,
    /// authentication, and service errors are never mistaken for silence.
    static func canSkipSegment(_ error: any Error) -> Bool {
        guard let clientError = error as? ElevenLabsClientError else {
            return false
        }
        return clientError == .emptyTranscript
    }
}
