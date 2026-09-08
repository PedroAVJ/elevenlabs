import SwiftUI
import UIKit

enum Theme {
    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }

    static let background = adaptive(
        light: UIColor(red: 253 / 255, green: 252 / 255, blue: 252 / 255, alpha: 1),
        dark: .black
    )
    static let surface = adaptive(
        light: .white,
        dark: UIColor(red: 20 / 255, green: 19 / 255, blue: 18 / 255, alpha: 1)
    )
    static let surfaceRaised = adaptive(
        light: UIColor(red: 244 / 255, green: 242 / 255, blue: 240 / 255, alpha: 1),
        dark: UIColor(red: 28 / 255, green: 26 / 255, blue: 24 / 255, alpha: 1)
    )
    static let stroke = adaptive(
        light: UIColor(white: 0, alpha: 0.12),
        dark: UIColor(white: 1, alpha: 0.16)
    )
    static let accent = adaptive(light: .black, dark: .white)
    static let accentDeep = adaptive(
        light: UIColor(red: 28 / 255, green: 26 / 255, blue: 24 / 255, alpha: 1),
        dark: UIColor(red: 213 / 255, green: 210 / 255, blue: 206 / 255, alpha: 1)
    )
    static let onAccent = adaptive(light: .white, dark: .black)
    static let ink = adaptive(light: .black, dark: .white)
    static let inkMuted = adaptive(
        light: UIColor(red: 119 / 255, green: 113 / 255, blue: 105 / 255, alpha: 1),
        dark: UIColor(white: 1, alpha: 0.62)
    )
    static let inkTertiary = adaptive(
        light: UIColor(red: 151 / 255, green: 145 / 255, blue: 138 / 255, alpha: 1),
        dark: UIColor(white: 1, alpha: 0.42)
    )
    static let danger = adaptive(
        light: UIColor(red: 215 / 255, green: 0, blue: 21 / 255, alpha: 1),
        dark: UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
    )
    static let ice = Color(red: 74 / 255, green: 170 / 255, blue: 1)
    static let iceSoft = Color(red: 221 / 255, green: 242 / 255, blue: 1)
    static let iceDeep = Color(red: 0, green: 102 / 255, blue: 204 / 255)

    static func timeString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onAccent)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Capsule().fill(Theme.accent))
            .opacity(configuration.isPressed ? 0.78 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = Theme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().stroke(Theme.stroke))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("ios-onboarding-completed-v3")
    private var completedOnboarding = false
    @AppStorage("ios-onboarding-control-practiced-v2")
    private var practicedControlCenterStart = false
    @AppStorage("ios-onboarding-page-v3")
    private var onboardingPage = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            Group {
                if showsSessionHandoff {
                    SessionHandoffView(
                        model: model,
                        recorder: model.recorder
                    )
                } else if let errorMessage {
                    MinimalErrorView(model: model, message: errorMessage)
                } else if !completedOnboarding {
                    FirstRunOnboarding(
                        page: onboardingPage,
                        advance: {
                            onboardingPage = min(2, onboardingPage + 1)
                        },
                        openKeyboardSettings: model.openKeyboardSettings,
                        finish: {
                            onboardingPage = 2
                            completedOnboarding = true
                        }
                    )
                } else if model.isTranscribing {
                    SendingView()
                } else if !model.transcriptText.isEmpty {
                    MinimalTranscriptView(model: model)
                } else {
                    ReadyView()
                }
            }
            .transition(.opacity)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.24),
            value: showsSessionHandoff
        )
        .onChange(of: model.isPreparingKeyboardSession) { _, isPreparing in
            if isPreparing {
                practicedControlCenterStart = true
                onboardingPage = max(1, onboardingPage)
            }
        }
        .onChange(of: model.isRecording) { _, isRecording in
            if isRecording, model.isKeyboardDictation {
                practicedControlCenterStart = true
                onboardingPage = max(1, onboardingPage)
            }
        }
        .onAppear {
            if practicedControlCenterStart {
                onboardingPage = max(1, onboardingPage)
            }
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
                .presentationDragIndicator(.visible)
        }
    }

    private var errorMessage: String? {
        if case let .failed(message) = model.phase { return message }
        return nil
    }

    private var showsSessionHandoff: Bool {
        guard errorMessage == nil else { return false }
        return model.isPreparingKeyboardSession
            || model.isRecording
            || model.isPaused
            || model.isWaitingToContinue
            || (model.isKeyboardDictation && model.isTranscribing)
    }
}

private struct FirstRunOnboarding: View {
    let page: Int
    let advance: () -> Void
    let openKeyboardSettings: () -> Void
    let finish: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            OnboardingWordmark()
                .padding(.top, 14)

            Spacer(minLength: 24)

            switch page {
            case 0:
                controlCenterStep
            case 1:
                liveActivityStep
            default:
                keyboardStep
            }

            Spacer(minLength: 24)
        }
        .padding(.horizontal, 28)
    }

    private var controlCenterStep: some View {
        VStack(spacing: 28) {
            OnboardingProgress(current: 1)

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Theme.accent)
                    .frame(width: 112, height: 112)
                Image(systemName: "mic.fill")
                    .font(.system(size: 34, weight: .black))
                    .foregroundStyle(Theme.onAccent)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Add your Live Activity.")
                    .font(.system(size: 38, weight: .light))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text("Touch and hold Control Center, tap Add a Control, then choose Dictation Button.")
                    .font(.body)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Tap that control once. It only puts the ready Live Activity on screen.")
                .font(.subheadline)
                .foregroundStyle(Theme.inkTertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private var liveActivityStep: some View {
        VStack(spacing: 28) {
            OnboardingProgress(current: 2)

            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    OnboardingWaveform()
                    Text("Ready")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Image(systemName: "mic.fill")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(width: 282, height: 62)
                .background(Capsule().fill(.black))

                HStack(spacing: 7) {
                    Image(systemName: "hand.tap")
                    Text("Tap to start dictation")
                }
                .font(.caption)
                .foregroundStyle(Theme.inkTertiary)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Start from the Live Activity.")
                    .font(.system(size: 40, weight: .light))
                    .tracking(-1)
                    .foregroundStyle(Theme.ink)

                Text("Tap the Live Activity whenever you want to dictate. It opens Dictation Button and starts listening.")
                    .font(.body)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button("Next", action: advance)
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    private var keyboardStep: some View {
        VStack(spacing: 26) {
            OnboardingProgress(current: 3)

            ZStack {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 104, height: 104)
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 35, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .offset(x: -2, y: 2)
            }
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text("Send from the keyboard.")
                    .font(.system(size: 36, weight: .light))
                    .tracking(-0.9)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)

                Text("Add the Dictation Button keyboard and turn on Allow Full Access. It only sends the finished transcript.")
                    .font(.body)
                    .foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button("Open Keyboard Settings", action: openKeyboardSettings)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Done", action: finish)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }
}

private struct OnboardingWordmark: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform")
                .font(.caption.weight(.black))
            Text("Dictation Button")
                .font(.headline.weight(.semibold))
        }
        .foregroundStyle(Theme.ink)
        .accessibilityElement(children: .combine)
    }
}

private struct OnboardingProgress: View {
    let current: Int

    var body: some View {
        Text("\(current) OF 3")
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .tracking(1.3)
            .foregroundStyle(Theme.inkMuted)
            .accessibilityLabel("Step \(current) of 3")
    }
}

private struct OnboardingWaveform: View {
    private let levels: [CGFloat] = [0.26, 0.62, 0.92, 0.54, 0.78, 0.38, 0.66]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(.white)
                    .frame(width: 3, height: 5 + levels[index] * 15)
            }
        }
    }
}

private struct SessionHandoffView: View {
    fileprivate enum Stage: Equatable {
        case starting
        case recording
        case paused
        case sending
    }

    @ObservedObject var model: AppModel
    @ObservedObject var recorder: AudioRecorder

    private var stage: Stage {
        if model.isTranscribing || model.isWaitingToContinue { return .sending }
        if model.isPaused { return .paused }
        if model.isRecording { return .recording }
        return .starting
    }

    var body: some View {
        ZStack {
            handoffBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                sessionStatus
                    .padding(.top, 24)

                Spacer(minLength: 32)
                centerpiece
                Spacer(minLength: 32)

                if stage == .recording || stage == .paused {
                    SwipeBackCue(stage: stage)
                }
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 12)
        }
        .animation(.easeInOut(duration: 0.25), value: stage)
    }

    private var handoffBackground: Color {
        stage == .paused ? Theme.iceSoft : .black
    }

    private var foreground: Color {
        stage == .paused ? Theme.iceDeep : .white
    }

    private var sessionStatus: some View {
        HStack(spacing: 8) {
            if stage == .paused {
                Image(systemName: "snowflake")
                    .foregroundStyle(Theme.iceDeep)
            }

            Text(statusTitle)
                .font(.subheadline.weight(.semibold))

            if stage == .recording || stage == .paused {
                Text("·")
                    .foregroundStyle(foreground.opacity(0.44))
                Text(Theme.timeString(model.sessionElapsedDuration))
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .contentTransition(.numericText())
            }
        }
        .foregroundStyle(foreground)
        .accessibilityElement(children: .combine)
    }

    private var statusTitle: String {
        switch stage {
        case .starting: "Starting"
        case .recording: "Recording"
        case .paused: "Paused"
        case .sending: model.isWaitingToContinue ? "Continuing" : "Transcribing"
        }
    }

    @ViewBuilder
    private var centerpiece: some View {
        switch stage {
        case .starting:
            AmbientWaveform(tint: .white)
                .frame(height: 124)

        case .recording:
            ReactiveVoiceBars(level: recorder.level)
                .frame(height: 180)
                .accessibilityHidden(true)

        case .paused:
            VStack(spacing: 22) {
                Image(systemName: "snowflake")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.iceDeep)
                    .accessibilityHidden(true)
                FrozenVoiceBars()
                    .frame(height: 148)
                    .accessibilityHidden(true)
            }

        case .sending:
            VStack(spacing: 20) {
                ProcessingWaveform(tint: .white)
                    .frame(height: 92)
                Text(
                    model.isWaitingToContinue
                        ? "Keeping every word, then continuing."
                        : "Turning voice into text."
                )
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                model.isWaitingToContinue
                    ? "Finishing this transcript, then continuing"
                    : "Turning voice into text"
            )
        }
    }
}

private struct SwipeBackCue: View {
    let stage: SessionHandoffView.Stage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var travelsRight = false

    private var tint: Color {
        stage == .paused ? Theme.iceDeep : .white
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Swipe back")
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                    .frame(width: 134, height: 5)
                Capsule()
                    .fill(tint)
                    .frame(width: 52, height: 5)
                    .offset(x: travelsRight ? 82 : 0)
            }
            .frame(width: 134, height: 14)
            .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                travelsRight = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            stage == .paused
                ? "Swipe right along the bottom home bar to return. Listening is paused."
                : "Swipe right along the bottom home bar to return. Recording continues."
        )
    }
}

private struct ReactiveVoiceBars: View {
    let level: Float
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var samples: [Float] = Array(repeating: 0.025, count: 25)

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(samples.indices, id: \.self) { index in
                let shape = 0.58 + 0.42 * abs(sin(Double(index) * 1.29))
                let sample = Double(samples[index]) * shape
                Capsule(style: .continuous)
                    .fill(.white.opacity(0.72 + 0.28 * sample))
                    .frame(width: 6, height: 10 + 156 * sample)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: samples)
        .onChange(of: level) { _, newValue in
            let gated = max(0, min(1, (Double(newValue) - 0.025) / 0.30))
            let boosted = Float(pow(gated, 0.36))
            samples.removeFirst()
            samples.append(boosted)
        }
    }
}

private struct AmbientWaveform: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: reduceMotion)) { context in
            let frame = context.date.timeIntervalSinceReferenceDate * 5
            HStack(alignment: .center, spacing: 4.5) {
                ForEach(0..<22, id: \.self) { index in
                    let wave = 0.25 + 0.75 * abs(sin(frame + Double(index) * 0.64))
                    Capsule()
                        .fill(tint.opacity(0.28 + 0.72 * wave))
                        .frame(width: 6, height: 16 + 86 * wave)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ProcessingWaveform: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: reduceMotion)) { context in
            let frame = reduceMotion
                ? 0
                : context.date.timeIntervalSinceReferenceDate * 5.6
            HStack(alignment: .center, spacing: 5) {
                ForEach(0..<13, id: \.self) { index in
                    let distance = abs(Double(index) - 6) / 6
                    let pulse = 0.24 + 0.76 * abs(
                        sin(frame - Double(index) * 0.52)
                    )
                    let contour = 1 - 0.36 * distance
                    Capsule(style: .continuous)
                        .fill(tint.opacity(0.42 + 0.58 * pulse))
                        .frame(
                            width: 6,
                            height: 12 + 66 * pulse * contour
                        )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct FrozenVoiceBars: View {
    private let levels: [CGFloat] = [
        0.22, 0.36, 0.62, 0.44, 0.78, 0.48, 0.90, 0.58, 0.72, 0.38,
        0.84, 0.52, 0.68, 0.32, 0.76, 0.46, 0.88, 0.54, 0.70, 0.40,
    ]

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Theme.iceDeep.opacity(0.48 + 0.52 * levels[index]))
                    .frame(width: 5, height: 10 + levels[index] * 88)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ReadyView: View {
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.surface)
                    .frame(width: 112, height: 112)
                    .overlay(Circle().stroke(Theme.stroke))
                Image(systemName: "waveform")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
            Text("Ready")
                .font(.system(size: 42, weight: .light))
                .tracking(-1)
                .foregroundStyle(Theme.ink)
            Text("Tap the Live Activity to start. Use Control Center to show it again.")
                .font(.body)
                .foregroundStyle(Theme.inkMuted)
            Spacer()
            OnboardingWordmark()
                .padding(.bottom, 18)
        }
        .padding(.horizontal, 28)
        .accessibilityElement(children: .combine)
    }
}

private struct SendingView: View {
    var body: some View {
        VStack(spacing: 22) {
            ProcessingWaveform(tint: Theme.ink)
                .frame(height: 96)
            Text("Turning voice into text")
                .font(.title2.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Turning voice into text")
    }
}

private struct MinimalTranscriptView: View {
    @ObservedObject var model: AppModel
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(spacing: 16) {
            TextEditor(text: $model.transcriptText)
                .focused($isEditing)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 24).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 24).stroke(Theme.stroke))

            HStack(spacing: 12) {
                Button {
                    isEditing = false
                    model.copyTranscript()
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(PrimaryButtonStyle())

                Button(role: .destructive) {
                    isEditing = false
                    model.clearTranscript()
                } label: {
                    Image(systemName: "trash")
                        .font(.body.weight(.semibold))
                        .frame(width: 50, height: 50)
                }
                .buttonStyle(.bordered)
                .tint(Theme.danger)
            }
        }
        .padding(22)
    }
}

private struct MinimalErrorView: View {
    @ObservedObject var model: AppModel
    let message: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.body)
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 12) {
                if model.needsMicrophoneSettings {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            openURL(url)
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else if !model.hasAPIKey {
                    Button("Add API key") { model.showSettings = true }
                        .buttonStyle(PrimaryButtonStyle())
                } else if model.hasRecoverableRecording {
                    Button("Retry", action: model.retryAfterError)
                        .buttonStyle(PrimaryButtonStyle())
                    Button("Discard Audio", role: .destructive) {
                        model.discardRecoverableRecording()
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Theme.danger))
                } else {
                    Button("Dismiss", action: model.dismissError)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
            Spacer()
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
    }
}
