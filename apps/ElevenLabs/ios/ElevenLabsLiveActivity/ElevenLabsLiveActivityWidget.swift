import ActivityKit
import AppIntents
import Foundation
import SwiftUI
import WidgetKit

@main
struct ElevenLabsLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        ElevenLabsLiveActivityWidget()
        if #available(iOS 18.0, *) {
            ElevenLabsDictationControl()
        }
    }
}

/// WidgetKit changes the Boolean immediately on tap while the app-owned intent
/// performs the real audio transition. Keep the transitional presentation so
/// the fill and label acknowledge that optimistic value together, then let the
/// shared store reconcile them with the confirmed recorder state.
@available(iOS 18.0, *)
private enum DictationControlPresentation: Equatable, Sendable {
    case off
    case starting
    case recording
    case pausing
    case paused
    case resuming

    init(phase: SharedDictationPhase) {
        switch phase {
        case .starting: self = .starting
        case .recording: self = .recording
        case .pausing: self = .pausing
        case .paused: self = .paused
        case .resuming: self = .resuming
        case .idle, .launching, .transcribing, .completed,
             .inserting, .deliveryBlocked, .failed, .cancelled, .inserted,
             .handled:
            self = .off
        }
    }

    var isOn: Bool {
        self == .starting || self == .recording || self == .resuming
    }

    var status: LocalizedStringResource {
        switch self {
        case .off: "Off"
        case .starting: "Starting"
        case .recording: "Recording"
        case .pausing: "Pausing"
        case .paused: "Paused"
        case .resuming: "Resuming"
        }
    }

    func status(requestedIsOn: Bool) -> LocalizedStringResource {
        guard requestedIsOn != isOn else { return status }
        if requestedIsOn {
            switch self {
            case .paused, .pausing:
                return "Resuming"
            case .off:
                return "Showing"
            case .starting, .recording, .resuming:
                return "Starting"
            }
        }
        return "Pausing"
    }

    var systemImageName: String {
        switch self {
        case .off, .starting: "mic.fill"
        case .recording, .resuming: "waveform"
        case .pausing, .paused: "play.fill"
        }
    }

    func systemImageName(requestedIsOn: Bool) -> String {
        guard requestedIsOn != isOn else { return systemImageName }
        if requestedIsOn {
            switch self {
            case .paused, .pausing:
                return "waveform"
            case .off:
                return "waveform"
            case .starting, .recording, .resuming:
                return "mic.fill"
            }
        }
        return "play.fill"
    }
}

@available(iOS 18.0, *)
private struct DictationControlValueProvider: ControlValueProvider {
    let previewValue = DictationControlPresentation.off

    func currentValue() async throws -> DictationControlPresentation {
        return DictationControlPresentation(
            phase: SharedDictationStore().load().phase
        )
    }
}

/// WidgetKit owns all sizing and Liquid Glass treatment. Generic microphone,
/// waveform, and play symbols communicate state without borrowing a provider's
/// brand mark; the title and state text appear where the system has room.
@available(iOS 18.0, *)
struct ElevenLabsDictationControl: ControlWidget {
    static let kind = ElevenLabsDictationControlContract.kind

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: Self.kind,
            provider: DictationControlValueProvider()
        ) { presentation in
            ControlWidgetToggle(
                "Dictation",
                isOn: presentation.isOn,
                action: ToggleDictationControlIntent()
            ) { requestedIsOn in
                Label(
                    presentation.status(requestedIsOn: requestedIsOn),
                    systemImage: presentation.systemImageName(
                        requestedIsOn: requestedIsOn
                    )
                )
            }
            .tint(.red)
        }
        .displayName("Dictation Button")
        .description(
            "Show the Live Activity launcher, or pause and continue dictation."
        )
    }
}

private enum LAPalette {
    static let card = Color.black.opacity(0.94)
    static let preparing = Color(red: 1, green: 149 / 255, blue: 0)
    static let recording = Color(red: 215 / 255, green: 0, blue: 21 / 255)
    static let paused = Color(red: 94 / 255, green: 186 / 255, blue: 1)
    static let compactRecording = Color(
        red: 1,
        green: 69 / 255,
        blue: 58 / 255
    )
    static let compactRecordingPeak = Color(
        red: 1,
        green: 159 / 255,
        blue: 10 / 255
    )
    static let minimalMeterLow = Color(
        red: 111 / 255,
        green: 75 / 255,
        blue: 22 / 255
    )
    static let minimalMeterMid = Color(
        red: 185 / 255,
        green: 130 / 255,
        blue: 39 / 255
    )
    static let minimalMeterPeak = Color(
        red: 242 / 255,
        green: 195 / 255,
        blue: 92 / 255
    )
    static let compactPaused = Color(
        red: 99 / 255,
        green: 198 / 255,
        blue: 1
    )
    static let transcribing = Color.white
    static let completed = Color.white
    static let failed = Color(red: 1, green: 59 / 255, blue: 48 / 255)
    static let neutral = Color.white.opacity(0.62)
}

private extension ElevenLabsActivityAttributes.Phase {
    var tint: Color {
        switch self {
        case .idle: LAPalette.completed
        case .starting, .resuming: LAPalette.preparing
        case .recording: LAPalette.recording
        case .pausing, .paused: LAPalette.paused
        case .transcribing: LAPalette.transcribing
        case .completed: LAPalette.completed
        case .failed: LAPalette.failed
        case .cancelled: LAPalette.neutral
        }
    }

    var glyphName: String {
        switch self {
        case .idle: "waveform"
        case .starting, .recording, .pausing, .resuming: "waveform"
        case .paused: "snowflake"
        case .transcribing: "ellipsis"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .cancelled: "xmark"
        }
    }

    var hasControls: Bool {
        self == .recording || self == .paused
    }

    var compactTint: Color {
        switch self {
        case .recording: LAPalette.compactRecording
        case .paused: LAPalette.compactPaused
        default: tint
        }
    }
}

private func displayPhase(
    for context: ActivityViewContext<ElevenLabsActivityAttributes>
) -> ElevenLabsActivityAttributes.Phase {
    context.isStale ? .failed : context.state.phase
}

private func activityURL(
    phase: ElevenLabsActivityAttributes.Phase,
    sessionID: UUID
) -> URL {
    switch phase {
    case .idle:
        URL(string: "elevenlabs://live-activity/start")!
    case .starting, .recording, .pausing, .paused, .resuming, .transcribing,
         .completed, .failed, .cancelled:
        URL(
            string: "elevenlabs://live-activity/status?session=\(sessionID.uuidString)"
        )!
    }
}

/// The recording process advances `frame` with ActivityKit updates. Recording
/// uses the normalized microphone level as its amplitude, while preparation
/// stays deliberately smaller and orange so it never claims the mic is hot.
private struct WaveformMark: View {
    let phase: ElevenLabsActivityAttributes.Phase
    let frame: UInt8
    let audioLevel: Double?
    var height: CGFloat = 16
    var barCount = 9
    var fillsAvailableWidth = false

    private static let patterns: [[CGFloat]] = [
        [0.18, 0.30, 0.46, 0.72, 0.38, 0.84, 0.54, 0.94, 0.62, 0.42, 1.00, 0.48, 0.76, 0.34, 0.88, 0.58, 0.28, 0.68, 0.40, 0.24, 0.16],
        [0.36, 0.66, 0.24, 0.52, 0.90, 0.44, 0.72, 0.32, 0.82, 0.56, 0.38, 0.96, 0.60, 0.28, 0.78, 0.48, 0.92, 0.34, 0.64, 0.22, 0.42],
        [0.22, 0.42, 0.74, 0.34, 0.58, 0.98, 0.46, 0.80, 0.30, 0.68, 0.90, 0.52, 1.00, 0.40, 0.70, 0.26, 0.86, 0.56, 0.36, 0.62, 0.20],
        [0.48, 0.26, 0.62, 0.88, 0.38, 0.76, 0.50, 0.28, 0.94, 0.58, 0.82, 0.32, 0.68, 1.00, 0.44, 0.72, 0.24, 0.54, 0.90, 0.40, 0.18],
        [0.16, 0.54, 0.32, 0.78, 0.46, 0.92, 0.36, 0.64, 0.26, 0.84, 0.50, 1.00, 0.42, 0.74, 0.30, 0.88, 0.56, 0.68, 0.24, 0.44, 0.20],
        [0.30, 0.70, 0.40, 0.90, 0.22, 0.60, 0.82, 0.34, 0.52, 0.96, 0.46, 0.76, 0.28, 0.86, 0.58, 1.00, 0.38, 0.66, 0.48, 0.24, 0.18],
    ]

    private var visiblePattern: [CGFloat] {
        let pattern = Self.patterns[Int(frame) % Self.patterns.count]
        let count = min(pattern.count, max(3, barCount))
        let start = max(0, (pattern.count - count) / 2)
        return Array(pattern[start..<(start + count)])
    }

    private var barWidth: CGFloat {
        max(1.6, min(3, (height / 9).rounded()))
    }

    private var barSpacing: CGFloat {
        fillsAvailableWidth ? 3 : max(1.2, barWidth * 0.68)
    }

    private var ratios: [CGFloat] {
        if phase == .starting || phase == .pausing || phase == .resuming {
            return visiblePattern.map { 0.20 + ($0 * 0.30) }
        }
        let energy = CGFloat(min(1, max(0, audioLevel ?? 0.04)))
        let voiceBoost = pow(energy, 0.30)
        let amplitude = 0.28 + (voiceBoost * 0.72)
        return visiblePattern.map { max(0.12, $0 * amplitude) }
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: fillsAvailableWidth ? 0 : barSpacing
        ) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(phase.tint)
                    .frame(
                        width: barWidth,
                        height: height * ratios[index]
                    )
                if fillsAvailableWidth, index < ratios.count - 1 {
                    Spacer(minLength: max(2, barWidth))
                }
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .frame(height: height)
        .opacity(
            phase == .starting || phase == .pausing || phase == .resuming
                ? 0.78
                : 1
        )
    }
}

private struct FrozenWaveformMark: View {
    var height: CGFloat = 16
    var barCount = 9
    var fillsAvailableWidth = false

    private let pattern: [CGFloat] = [
        0.20, 0.34, 0.58, 0.42, 0.76, 0.50, 0.90, 0.62, 0.38, 0.82,
        1.00, 0.56, 0.72, 0.44, 0.88, 0.52, 0.30, 0.66, 0.40, 0.28, 0.18,
    ]

    private var ratios: [CGFloat] {
        let count = min(pattern.count, max(3, barCount))
        let start = max(0, (pattern.count - count) / 2)
        return Array(pattern[start..<(start + count)])
    }

    private var barWidth: CGFloat {
        max(1.6, min(3, (height / 9).rounded()))
    }

    private var barSpacing: CGFloat {
        fillsAvailableWidth ? 3 : max(1.2, barWidth * 0.68)
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: fillsAvailableWidth ? 0 : barSpacing
        ) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(LAPalette.paused)
                    .frame(
                        width: barWidth,
                        height: height * ratios[index]
                    )
                if fillsAvailableWidth, index < ratios.count - 1 {
                    Spacer(minLength: max(2, barWidth))
                }
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// ActivityKit content updates drive a real circular spinner immediately after
/// Send. The newest phase generation invalidates any queued recording waveform,
/// so minimal, compact, and expanded presentations switch together.
private struct TranscriptionProgressMark: View {
    let frame: UInt8
    var size: CGFloat = 17

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle()
                .stroke(
                    LAPalette.transcribing.opacity(0.24),
                    lineWidth: max(1.6, size * 0.13)
                )
            Circle()
                .trim(from: 0.06, to: 0.34)
                .stroke(
                    LAPalette.transcribing,
                    style: StrokeStyle(
                        lineWidth: max(1.6, size * 0.13),
                        lineCap: .round
                    )
                )
                .rotationEffect(
                    .degrees(
                        reduceMotion
                            ? -90
                            : Double(frame % 8) * 45 - 90
                    )
                )
                .animation(
                    reduceMotion ? nil : .linear(duration: 0.18),
                    value: frame
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct PhaseMark: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase
    var size: CGFloat = 15

    private var frame: UInt8 { state.visualizationFrame ?? 0 }

    var body: some View {
        Group {
            switch phase {
            case .idle:
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.9, weight: .bold))
                    .foregroundStyle(phase.tint)
            case .starting, .recording, .pausing, .resuming:
                WaveformMark(
                    phase: phase,
                    frame: frame,
                    audioLevel: state.audioLevel,
                    height: size
                )
            case .transcribing:
                TranscriptionProgressMark(frame: frame, size: size)
            case .paused, .completed, .failed, .cancelled:
                Image(systemName: phase.glyphName)
                    .font(.system(size: size * 0.9, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .accessibilityElement()
        .accessibilityLabel(phase.title)
    }
}

private struct SessionSignal: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase
    var height: CGFloat = 15
    var barCount = 9
    var fillsAvailableWidth = false

    var body: some View {
        HStack(spacing: fillsAvailableWidth ? 9 : max(4, height * 0.30)) {
            if phase == .recording {
                CompactStudioMeter(
                    state: state,
                    height: height,
                    barCount: barCount,
                    fillsAvailableWidth: fillsAvailableWidth
                )
            } else if phase == .paused {
                FrozenWaveformMark(
                    height: height,
                    barCount: barCount,
                    fillsAvailableWidth: fillsAvailableWidth
                )
            } else {
                PhaseMark(state: state, phase: phase, size: height)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.title)
    }
}

/// The selected compact Dynamic Island pair from Claude Design. ActivityKit
/// advances the frame and microphone energy; SwiftUI does not run an ambient
/// animation loop that the system could suspend.
private enum CompactMeterLevels {
    static let patterns: [[CGFloat]] = [
        [0.33, 0.61, 0.89, 0.44, 0.78, 1.00, 0.56, 0.72, 0.39],
        [0.50, 0.83, 0.39, 0.72, 0.94, 0.56, 0.78, 0.44, 0.67],
        [0.39, 0.67, 0.94, 0.50, 0.72, 0.89, 0.44, 0.78, 0.56],
        [0.61, 0.44, 0.78, 1.00, 0.56, 0.72, 0.89, 0.39, 0.67],
        [0.44, 0.72, 0.56, 0.89, 0.39, 0.94, 0.67, 0.50, 0.78],
        [0.56, 0.89, 0.44, 0.67, 1.00, 0.50, 0.72, 0.94, 0.39],
    ]

    static func ratios(
        frame: UInt8,
        audioLevel: Double?,
        meterLevels: [Double]?,
        barCount: Int
    ) -> [CGFloat] {
        let count = max(3, barCount)
        if let meterLevels, meterLevels.count >= 3 {
            let samples = meterLevels.map { CGFloat(min(1, max(0, $0))) }
            return (0..<count).map { index in
                let position = count == 1
                    ? 0
                    : CGFloat(index) * CGFloat(samples.count - 1)
                        / CGFloat(count - 1)
                let lower = min(samples.count - 1, Int(floor(position)))
                let upper = min(samples.count - 1, lower + 1)
                let fraction = position - CGFloat(lower)
                let rawLevel = samples[lower]
                    + ((samples[upper] - samples[lower]) * fraction)
                let gatedLevel = min(1, max(0, (rawLevel - 0.018) / 0.28))
                let voiceEnergy = pow(gatedLevel, 0.42)
                return 0.17 + (0.83 * voiceEnergy)
            }
        }
        let source = patterns[Int(frame) % patterns.count]
        let pattern = (0..<count).map { source[$0 % source.count] }
        let rawLevel = CGFloat(min(1, max(0, audioLevel ?? 0)))
        let gatedLevel = min(1, max(0, (rawLevel - 0.018) / 0.28))
        let voiceEnergy = pow(gatedLevel, 0.42)
        let silenceRatio: CGFloat = 0.17
        return pattern.map {
            min(1, silenceRatio + (($0 - silenceRatio) * voiceEnergy))
        }
    }
}

/// Apple Music-inspired voice meter for ActivityKit's 37 x 37 point detached
/// bubble. Six hairline columns use the real microphone envelope and linear
/// interpolation between committed ActivityKit samples. There is no ambient
/// animation loop and no decorative recording disc.
private struct MinimalRecordingMark: View {
    let state: ElevenLabsActivityAttributes.ContentState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let meterHeight: CGFloat = 17
    private let barWidth: CGFloat = 1.5
    private let barSpacing: CGFloat = 1.35
    private let markWidth: CGFloat = 15.75

    private var ratios: [CGFloat] {
        CompactMeterLevels.ratios(
            frame: state.visualizationFrame ?? 0,
            audioLevel: state.audioLevel,
            meterLevels: state.meterLevels,
            barCount: 6
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: barSpacing) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                LAPalette.minimalMeterLow,
                                LAPalette.minimalMeterMid,
                                LAPalette.minimalMeterPeak,
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(
                        width: barWidth,
                        height: max(3, meterHeight * ratios[index])
                    )
            }
        }
        .frame(width: markWidth, height: meterHeight)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.18),
            value: ratios
        )
        .accessibilityHidden(true)
    }
}

private struct CompactStudioMeter: View {
    let state: ElevenLabsActivityAttributes.ContentState
    var height: CGFloat = 18
    var barCount = 9
    var fillsAvailableWidth = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barWidth: CGFloat = 2.2
    private let barSpacing: CGFloat = 2.1

    private var ratios: [CGFloat] {
        CompactMeterLevels.ratios(
            frame: state.visualizationFrame ?? 0,
            audioLevel: state.audioLevel,
            meterLevels: state.meterLevels,
            barCount: barCount
        )
    }

    var body: some View {
        HStack(
            alignment: .center,
            spacing: fillsAvailableWidth ? 9 : barSpacing
        ) {
            ForEach(ratios.indices, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                LAPalette.compactRecording,
                                LAPalette.compactRecordingPeak,
                            ],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(
                        width: barWidth,
                        height: max(3, height * ratios[index])
                    )
            }
        }
        .frame(height: height)
        .frame(maxWidth: fillsAvailableWidth ? .infinity : nil)
        .animation(
            reduceMotion ? nil : .linear(duration: 0.20),
            value: ratios
        )
        .accessibilityHidden(true)
    }
}

private struct CompactSessionSignal: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase
    var height: CGFloat = 18
    var barCount = 9

    var body: some View {
        Group {
            switch phase {
            case .recording:
                CompactStudioMeter(
                    state: state,
                    height: height,
                    barCount: barCount
                )
            case .paused:
                Image(systemName: "snowflake")
                    .font(.system(size: height * 0.84, weight: .semibold))
                    .foregroundStyle(LAPalette.compactPaused)
                    .symbolRenderingMode(.monochrome)
            default:
                SessionSignal(
                    state: state,
                    phase: phase,
                    height: height,
                    barCount: barCount
                )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.title)
    }
}

private struct MinimalSessionSignal: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase

    private var frame: UInt8 { state.visualizationFrame ?? 0 }

    var body: some View {
        Group {
            switch phase {
            case .recording:
                MinimalRecordingMark(state: state)
            case .paused:
                Image(systemName: "snowflake")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(LAPalette.compactPaused)
                    .symbolRenderingMode(.monochrome)
            case .starting, .pausing, .resuming:
                WaveformMark(
                    phase: phase,
                    frame: frame,
                    audioLevel: nil,
                    height: 15,
                    barCount: 3
                )
            case .transcribing:
                TranscriptionProgressMark(frame: frame, size: 16)
            case .idle, .completed, .failed, .cancelled:
                Image(systemName: phase.glyphName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(phase.tint)
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .frame(width: 27, height: 27)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(phase.title)
    }
}

private struct ActivityDurationText: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase
    var font: Font = .caption.monospacedDigit().weight(.semibold)
    var tint: Color? = nil

    private var frozenDuration: String {
        let total = Int(max(0, state.elapsedDuration))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var body: some View {
        Group {
            if phase == .recording, let startedAt = state.recordingStartedAt {
                Text(
                    timerInterval: startedAt...Date.distantFuture,
                    countsDown: false,
                    showsHours: false
                )
            } else {
                Text(frozenDuration)
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(tint ?? phase.tint)
        .contentTransition(.numericText())
        .accessibilityLabel(
            phase == .paused
                ? "Paused at \(frozenDuration)"
                : "Recording time"
        )
    }
}

private struct DictationControlButton<Intent: AppIntent>: View {
    let title: String
    let systemImageName: String
    let tint: Color
    let intent: Intent
    let accessibilityLabel: String
    var accessibilityHint: String = ""

    var body: some View {
        Button(intent: intent) {
            HStack(spacing: 8) {
                Image(systemName: systemImageName)
                    .font(.system(size: 15, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(tint.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(tint.opacity(0.22), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }
}

private struct DictationControls: View {
    let phase: ElevenLabsActivityAttributes.Phase
    let sessionID: UUID

    var body: some View {
        if phase == .paused {
            VStack(spacing: 10) {
                VStack(spacing: 3) {
                    Text("Paused safely")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    Text("Open Control Center to continue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                DictationControlButton(
                    title: "Cancel",
                    systemImageName: "xmark",
                    tint: LAPalette.failed,
                    intent: CancelDictationIntent(sessionID: sessionID),
                    accessibilityLabel: "Cancel dictation",
                    accessibilityHint: "Stops and discards this dictation."
                )
            }
        } else {
            HStack(spacing: 10) {
                DictationControlButton(
                    title: "Pause",
                    systemImageName: "pause.fill",
                    tint: LAPalette.transcribing,
                    intent: PauseDictationIntent(sessionID: sessionID),
                    accessibilityLabel: "Pause dictation",
                    accessibilityHint: "Stops listening. Open Control Center to continue."
                )

                DictationControlButton(
                    title: "Cancel",
                    systemImageName: "xmark",
                    tint: LAPalette.failed,
                    intent: CancelDictationIntent(sessionID: sessionID),
                    accessibilityLabel: "Cancel dictation",
                    accessibilityHint: "Stops and discards this dictation."
                )
            }
        }
    }
}

private struct IdleStartButton: View {
    var body: some View {
        Link(destination: URL(string: "elevenlabs://live-activity/start")!) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Start dictation")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start dictation")
        .accessibilityHint(
            "Opens Dictation Button and starts listening."
        )
    }
}

private struct ActivityStateSurface: View {
    let state: ElevenLabsActivityAttributes.ContentState
    let phase: ElevenLabsActivityAttributes.Phase
    let sessionID: UUID

    var body: some View {
        if phase == .idle {
            IdleStartButton()
        } else if phase.hasControls {
            VStack(spacing: 14) {
                SessionSignal(
                    state: state,
                    phase: phase,
                    height: 34,
                    barCount: 21,
                    fillsAvailableWidth: true
                )
                DictationControls(phase: phase, sessionID: sessionID)
            }
        } else if [.starting, .pausing, .resuming].contains(phase) {
            HStack {
                Spacer()
                WaveformMark(
                    phase: phase,
                    frame: state.visualizationFrame ?? 0,
                    audioLevel: nil,
                    height: 26
                )
                Spacer()
            }
        } else if phase == .transcribing {
            HStack {
                Spacer()
                TranscriptionProgressMark(
                    frame: state.visualizationFrame ?? 0,
                    size: 30
                )
                Spacer()
            }
        } else {
            HStack {
                Spacer()
                PhaseMark(state: state, phase: phase, size: 18)
                Spacer()
            }
        }
    }
}

private struct DictationCard: View {
    let context: ActivityViewContext<ElevenLabsActivityAttributes>

    var body: some View {
        let phase = displayPhase(for: context)
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Dictation Button")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if phase == .recording || phase == .paused {
                    ActivityDurationText(
                        state: context.state,
                        phase: phase,
                        font: .body.monospacedDigit().weight(.semibold)
                    )
                } else {
                    Text(phase.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(phase.tint)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Dictation Button, \(phase.title)")

            ActivityStateSurface(
                state: context.state,
                phase: phase,
                sessionID: context.attributes.sessionID
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .widgetURL(
            activityURL(
                phase: phase,
                sessionID: context.attributes.sessionID
            )
        )
    }
}

struct ElevenLabsLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ElevenLabsActivityAttributes.self) { context in
            DictationCard(context: context)
                .activityBackgroundTint(LAPalette.card)
                .activitySystemActionForegroundColor(
                    displayPhase(for: context).tint
                )
        } dynamicIsland: { context in
            let phase = displayPhase(for: context)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("Dictation Button")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dictation Button, \(phase.title)")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if phase == .recording || phase == .paused {
                        ActivityDurationText(
                            state: context.state,
                            phase: phase,
                            font: .body.monospacedDigit().weight(.semibold)
                        )
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityStateSurface(
                        state: context.state,
                        phase: phase,
                        sessionID: context.attributes.sessionID
                    )
                    .padding(.top, 2)
                }
            } compactLeading: {
                CompactSessionSignal(
                    state: context.state,
                    phase: phase,
                    height: 18
                )
                    .accessibilityLabel("Dictation Button, \(phase.title)")
            } compactTrailing: {
                if phase == .recording || phase == .paused {
                    ActivityDurationText(
                        state: context.state,
                        phase: phase,
                        tint: phase.compactTint
                    )
                } else if phase == .transcribing {
                    TranscriptionProgressMark(
                        frame: context.state.visualizationFrame ?? 0,
                        size: 13
                    )
                    .accessibilityLabel("Transcribing dictation")
                }
            } minimal: {
                MinimalSessionSignal(
                    state: context.state,
                    phase: phase
                )
                    .accessibilityLabel("Dictation Button, \(phase.title)")
            }
            .keylineTint(phase.tint)
            .widgetURL(
                activityURL(
                    phase: phase,
                    sessionID: context.attributes.sessionID
                )
            )
        }
    }
}
