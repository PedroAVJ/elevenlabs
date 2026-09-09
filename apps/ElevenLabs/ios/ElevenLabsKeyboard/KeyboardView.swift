import AppIntents
import SwiftUI
import UIKit

private enum KBTheme {
    private static func adaptive(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(
            UIColor { traits in
                let channels = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(
                    red: channels.0,
                    green: channels.1,
                    blue: channels.2,
                    alpha: 1
                )
            }
        )
    }

    static let background = adaptive(
        light: (0.82, 0.83, 0.85),
        dark: (0.07, 0.07, 0.08)
    )
    static let surface = adaptive(
        light: (1.0, 1.0, 1.0),
        dark: (0.28, 0.28, 0.30)
    )
    static let ink = adaptive(
        light: (0.0, 0.0, 0.0),
        dark: (1.0, 1.0, 1.0)
    )
    static let inkMuted = adaptive(
        light: (0.45, 0.45, 0.47),
        dark: (0.72, 0.72, 0.74)
    )
    static let accent = adaptive(
        light: (0.0, 0.0, 0.0),
        dark: (1.0, 1.0, 1.0)
    )
    static let onAccent = adaptive(
        light: (1.0, 1.0, 1.0),
        dark: (0.0, 0.0, 0.0)
    )
    static let stroke = adaptive(
        light: (0.68, 0.69, 0.72),
        dark: (0.38, 0.38, 0.40)
    )
    static let danger = adaptive(
        light: (0.84, 0.0, 0.08),
        dark: (1.0, 0.23, 0.19)
    )
    static let preparing = Color(red: 1, green: 149 / 255, blue: 0)
    static let recording = Color(red: 215 / 255, green: 0, blue: 21 / 255)
}

private struct KBControlButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color
    var stroke: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(fill: Color, foreground: Color, stroke: Color? = nil) {
        self.fill = fill
        self.foreground = foreground
        self.stroke = stroke
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 46)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(fill)
            )
            .overlay {
                if let stroke {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(stroke)
                }
            }
            .opacity(configuration.isPressed ? 0.76 : 1)
            .scaleEffect(
                reduceMotion ? 1 : (configuration.isPressed ? 0.98 : 1)
            )
    }
}

/// A real animation can run while the keyboard is resident. It is intentionally
/// wordless, but the red/active and orange/preparing states match the Live
/// Activity so the same lifecycle reads the same on both surfaces.
private struct KBWaveform: View {
    let tint: Color
    var isActive = true
    var height: CGFloat = 18

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let patterns: [[CGFloat]] = [
        [0.24, 0.46, 0.72, 1.00, 0.68, 0.40, 0.22],
        [0.52, 0.84, 0.36, 0.62, 0.94, 0.48, 0.28],
        [0.88, 0.34, 0.58, 0.96, 0.42, 0.76, 0.30],
        [0.38, 0.66, 1.00, 0.48, 0.82, 0.32, 0.56],
    ]

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: 0.16,
                paused: reduceMotion || !isActive
            )
        ) { context in
            let frame = isActive
                ? Int(context.date.timeIntervalSinceReferenceDate * 6)
                : 0
            let ratios = Self.patterns[frame % Self.patterns.count]
            HStack(alignment: .center, spacing: 3) {
                ForEach(ratios.indices, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(tint)
                        .frame(width: 3, height: height * ratios[index])
                }
            }
            .frame(height: height)
        }
    }
}

private struct KBStateProgress: View {
    enum Kind {
        case preparing
        case sending
        case cancelling
    }

    let kind: Kind

    private var tint: Color {
        switch kind {
        case .preparing: KBTheme.preparing
        case .sending: KBTheme.accent
        case .cancelling: KBTheme.danger
        }
    }

    private var accessibilityLabel: String {
        switch kind {
        case .preparing: "Preparing dictation"
        case .sending: "Transcribing dictation"
        case .cancelling: "Cancelling dictation"
        }
    }

    @ViewBuilder
    var body: some View {
        switch kind {
        case .preparing:
            KBWaveform(tint: tint, height: 34)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
        case .sending, .cancelling:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.large)
                .tint(tint)
                .frame(height: 34)
                .accessibilityLabel(accessibilityLabel)
        }
    }
}

/// Runs the keyboard-side cursor claim before waking the containing app to
/// stop, transcribe, and insert. That ordering keeps Send attached to the text
/// field where the user tapped it.
private struct KBPreparedIntentButtonStyle: ButtonStyle {
    var fill: Color
    var foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

/// Polling may publish an unchanged shared snapshot while a finger is already
/// down. Keep the AppIntent button's identity stable across those parent view
/// updates so SwiftUI cannot replace the recognizer before the first release.
private struct KBStableSendButton: View, @MainActor Equatable {
    let model: KeyboardModel
    let sessionID: UUID
    let isPaused: Bool

    @State private var isSending = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
            && lhs.sessionID == rhs.sessionID
            && lhs.isPaused == rhs.isPaused
    }

    private func prepareSend() {
        guard !isSending else { return }
        // Latch both the local progress state and the durable App Group command
        // on touch-down. Even if iOS replaces the freshly presented keyboard's
        // release recognizer, the containing app still receives this first tap.
        isSending = true
        model.stopAndTranscribe(expectedSessionID: sessionID)
    }

    var body: some View {
        Button(
            intent: StopAndInsertDictationIntent(sessionID: sessionID)
        ) {
            if isSending {
                KBStateProgress(kind: .sending)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "paperplane.fill")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityHidden(true)
                    Text("Send")
                }
            }
        }
        .buttonStyle(
            KBPreparedIntentButtonStyle(
                fill: KBTheme.accent,
                foreground: KBTheme.onAccent
            )
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in prepareSend() }
        )
        .simultaneousGesture(
            TapGesture().onEnded { prepareSend() }
        )
        .accessibilityLabel(
            isSending ? "Transcribing dictation" : "Send dictation"
        )
        .accessibilityHint(
            isPaused
                ? "Transcribes the recorded segments and inserts the text here."
                : "Stops recording, transcribes, and inserts the text here."
        )
    }
}

private struct KBRealtimeSendButton: View {
    let model: KeyboardModel
    let sessionID: UUID

    var body: some View {
        Button {
            model.sendRealtimeDraft(expectedSessionID: sessionID)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "paperplane.fill")
                    .font(.subheadline.weight(.semibold))
                    .accessibilityHidden(true)
                Text("Send now")
            }
        }
        .buttonStyle(
            KBPreparedIntentButtonStyle(
                fill: KBTheme.accent,
                foreground: KBTheme.onAccent
            )
        )
        .disabled(!model.canSendRealtimeDraft)
        .accessibilityLabel("Send live draft now")
        .accessibilityHint(
            "Inserts the live transcript immediately instead of waiting for the refined batch result."
        )
    }
}

/// Recording starts from Control Center. The keyboard renders the best current
/// live draft, then lets the user either wait for automatic batch delivery or
/// insert that draft immediately while refinement continues.
struct KeyboardView: View {
    @ObservedObject var model: KeyboardModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let keyboardSetupStatusStore = KeyboardSetupStatusStore()
    @State private var uppercase = false

    var body: some View {
        VStack(spacing: 6) {
            if !model.hasFullAccess {
                localKeyboard
            } else if let errorMessage {
                errorPanel(errorMessage)
            } else {
                controlSurface
            }
            localEditingRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KBTheme.background.ignoresSafeArea())
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: model.effectivePhase
        )
        .onChange(of: model.effectivePhase) { _, phase in
            announceStatusChange(phaseAnnouncement(for: phase))
        }
        .onAppear {
            keyboardSetupStatusStore.record(
                hasFullAccess: model.hasFullAccess
            )
        }
        .onChange(of: model.hasFullAccess) { _, hasFullAccess in
            keyboardSetupStatusStore.record(hasFullAccess: hasFullAccess)
        }
    }

    @ViewBuilder
    private var controlSurface: some View {
        Group {
            if model.isCancelling {
                KBStateProgress(kind: .cancelling)
            } else if model.isPausing {
                brandedStatus {
                    KBStateProgress(kind: .preparing)
                    Text("Pausing microphone…")
                        .font(.caption)
                        .foregroundStyle(KBTheme.inkMuted)
                }
            } else if [.recording, .paused].contains(model.snapshot.phase) {
                // Keep the same AppIntent button mounted after the keyboard
                // writes its optimistic Stop command on touch-down. Replacing
                // it with a separate progress view before touch-up can cancel
                // the system wakeup action on the very first tap.
                draftSurface(
                    status: model.snapshot.phase == .paused
                        ? "Paused"
                        : "Live",
                    isLive: model.snapshot.phase == .recording
                ) {
                    sendButton
                }
            } else if model.isStarting {
                brandedStatus {
                    KBStateProgress(kind: .preparing)
                    Text(model.startingStatusText)
                        .font(.caption)
                        .foregroundStyle(KBTheme.inkMuted)
                }
            } else if model.isTranscribing, model.realtimeDraft != nil {
                draftSurface(status: "Refining", isLive: false) {
                    KBRealtimeSendButton(
                        model: model,
                        sessionID: model.snapshot.sessionID
                    )
                }
            } else if model.isTranscribing || model.isInserting {
                brandedStatus {
                    KBStateProgress(kind: .sending)
                    Text("Refining…")
                        .font(.caption)
                        .foregroundStyle(KBTheme.inkMuted)
                }
            } else if model.recentlyInserted {
                brandedStatus {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(KBTheme.ink)
                    Text("Sent")
                        .font(.caption)
                        .foregroundStyle(KBTheme.inkMuted)
                }
            } else {
                brandedStatus {
                    Image(systemName: "paperplane")
                        .font(.title2.weight(.light))
                        .foregroundStyle(KBTheme.inkMuted)
                        .accessibilityHidden(true)
                    Text("Start from Live Activity")
                        .font(.caption)
                        .foregroundStyle(KBTheme.inkMuted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func draftSurface<Action: View>(
        status: String,
        isLive: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Dictation Button")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KBTheme.ink)
                Spacer()
                if isLive {
                    Circle()
                        .fill(KBTheme.recording)
                        .frame(width: 7, height: 7)
                } else if status == "Refining" {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(KBTheme.inkMuted)
                }
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KBTheme.inkMuted)
            }

            liveDraftText
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            action()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var liveDraftText: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.realtimeDraft ?? "Listening…")
                        .font(.body)
                        .foregroundStyle(
                            model.realtimeDraft == nil
                                ? KBTheme.inkMuted
                                : KBTheme.ink
                        )
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear
                        .frame(height: 1)
                        .id("live-draft-end")
                }
            }
            .scrollIndicators(.hidden)
            .onAppear {
                proxy.scrollTo("live-draft-end", anchor: .bottom)
            }
            .onChange(of: model.realtimeDraft) { _, _ in
                proxy.scrollTo("live-draft-end", anchor: .bottom)
            }
        }
        .accessibilityLabel(model.realtimeDraft ?? "Listening")
    }

    private func brandedStatus<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            Text("Dictation Button")
                .font(.caption.weight(.semibold))
                .foregroundStyle(KBTheme.ink)
            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private var sendButton: some View {
        let sessionID = model.snapshot.sessionID
        return KBStableSendButton(
            model: model,
            sessionID: sessionID,
            isPaused: model.snapshot.phase == .paused
        )
        .equatable()
    }

    private var fullAccessPanel: some View {
        statusShell {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 25))
                .foregroundStyle(KBTheme.accent)
            Text("Allow Full Access")
                .font(.headline)
                .foregroundStyle(KBTheme.ink)
            Text("Enable it in Settings › General › Keyboard › Keyboards › Dictation Button so these controls can share dictation state.")
                .font(.caption)
                .foregroundStyle(KBTheme.inkMuted)
                .multilineTextAlignment(.center)
            Button("Open Dictation Button", action: model.openElevenLabs)
                .buttonStyle(
                    KBControlButtonStyle(
                        fill: KBTheme.accent,
                        foreground: KBTheme.onAccent
                    )
                )
        }
    }

    private var localKeyboard: some View {
        VStack(spacing: 5) {
            Text("Typing stays on device. Full Access enables dictation sharing.")
                .font(.caption2)
                .foregroundStyle(KBTheme.inkMuted)
                .padding(.top, 6)
            ForEach(["qwertyuiop", "asdfghjkl", "zxcvbnm"], id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row).map(String.init), id: \.self) { letter in
                        localKey(uppercase ? letter.uppercased() : letter) {
                            model.typeLocalCharacter(uppercase ? letter.uppercased() : letter)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 5)
    }

    private var localEditingRow: some View {
        HStack(spacing: 5) {
            localKey("🌐", label: "Next keyboard", action: model.nextKeyboard)
            if !model.hasFullAccess {
                localKey("⇧", label: "Shift") { uppercase.toggle() }
            }
            localKey(".", label: "Period") { model.typeLocalCharacter(".") }
            localKey("Space") { model.typeLocalCharacter(" ") }
            localKey("↵", label: "Return") { model.typeLocalCharacter("\n") }
            localKey("⌫", label: "Delete", action: model.deleteLocalCharacterBeforeCursor)
        }
        .padding(.horizontal, 5)
        .padding(.bottom, 6)
    }

    private func localKey(
        _ title: String,
        label: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, minHeight: 39)
                .background(KBTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                .foregroundStyle(KBTheme.ink)
        }
        .accessibilityLabel(label ?? title)
    }

    private func errorPanel(_ message: String) -> some View {
        statusShell {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(KBTheme.danger)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KBTheme.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)

            HStack(spacing: 8) {
                if model.didFail && model.localError == nil {
                    Button(model.recoveryButtonTitle, action: model.retry)
                        .buttonStyle(
                            KBControlButtonStyle(
                                fill: KBTheme.surface,
                                foreground: KBTheme.ink,
                                stroke: KBTheme.stroke
                            )
                        )
                }
                if model.canDismissError {
                    Button(
                        model.errorDismissalButtonTitle,
                        action: model.dismissError
                    )
                    .buttonStyle(
                        KBControlButtonStyle(
                            fill: KBTheme.accent,
                            foreground: KBTheme.onAccent
                        )
                    )
                }
            }
        }
    }

    private var errorMessage: String? {
        if let localError = model.localError { return localError }
        if model.didFail {
            return model.snapshot.errorMessage ?? "Dictation failed. Try again."
        }
        return nil
    }

    private func statusShell<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(spacing: 10) {
            Spacer(minLength: 4)
            content()
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 6)
    }

    private func phaseAnnouncement(for phase: SharedDictationPhase) -> String? {
        switch phase {
        case .launching: return "Opening Dictation Button"
        case .starting: return "Starting microphone"
        case .recording: return "Listening"
        case .pausing: return "Pausing microphone"
        case .paused:
            return "Dictation paused"
        case .resuming: return "Resuming microphone"
        case .transcribing: return "Transcribing"
        // The insertion sequence is one user-visible event. Announcing each
        // bookkeeping phase talks over the text actually landing in the field.
        case .completed, .inserting: return nil
        case .deliveryBlocked: return "Transcript ready for explicit insertion"
        case .inserted: return "Inserted at the cursor"
        case .failed: return errorMessage ?? "Dictation failed"
        case .cancelled: return "Dictation cancelled"
        case .idle, .handled: return nil
        }
    }

    private func announceStatusChange(_ status: String?) {
        guard let status, UIAccessibility.isVoiceOverRunning else { return }
        var announcement = AttributedString(status)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(announcement)
        )
    }
}
