import Combine
import Foundation
@preconcurrency import React
import UIKit

@MainActor
final class ElevenLabsCoordinator {
    static let shared = ElevenLabsCoordinator()

    let stateDidChange = PassthroughSubject<Void, Never>()

    private(set) lazy var model: AppModel = {
        let model = AppModel()
        bind(to: model)
        return model
    }()

    private var observers: Set<AnyCancellable> = []
    private var pendingNotification: DispatchWorkItem?
    private var pendingNotificationDelay: TimeInterval?
    private var notificationGeneration: UInt64 = 0
    private var launchStateReady = false
    private var didLogInitialBridgeSnapshot = false
    private var applicationActiveCancellable: AnyCancellable?
    private var launchStateReleaseTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let keyboardSetupStatusStore = KeyboardSetupStatusStore()

    private enum OnboardingKeys {
        static let completed = "ios-onboarding-completed-v3"
        static let legacyCompleted = "ios-onboarding-completed-v2"
        static let practicedControl = "ios-onboarding-control-practiced-v2"
    }

    private init() {
        applicationActiveCancellable = NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.scheduleInitialLaunchStateReady()
                    Observability.flushKeyboardInsertionTelemetry()
                    // Keyboard Settings and the extension communicate through
                    // the App Group, not AppModel. Always refresh the bridge on
                    // activation so real setup proof closes onboarding without
                    // a hidden Done tap or a synthetic in-app text field.
                    self.stateDidChange.send()
                }
            }
    }

    func snapshot() -> [String: Any] {
        model.history.reload()
        let sharedSnapshot = SharedDictationStore().load()
        let headlessPhase: SharedDictationPhase? = {
            guard sharedSnapshot.sessionKind == .segmentedIntent else {
                return nil
            }
            switch sharedSnapshot.phase {
            case .starting, .recording, .pausing, .paused, .resuming,
                 .transcribing, .failed:
                return sharedSnapshot.phase
            case .idle, .launching, .completed, .inserting,
                 .deliveryBlocked, .cancelled, .inserted, .handled:
                return nil
            }
        }()
        let phase: String
        let errorText: Any
        if let headlessPhase {
            phase = headlessPhase.rawValue
            errorText = (sharedSnapshot.errorMessage as Any?) ?? NSNull()
        } else {
            switch model.phase {
            case .idle:
                phase = "idle"
                errorText = NSNull()
            case .recording:
                phase = "recording"
                errorText = NSNull()
            case .paused:
                phase = "paused"
                errorText = NSNull()
            case .transcribing:
                phase = "transcribing"
                errorText = NSNull()
            case let .failed(message):
                phase = "failed"
                errorText = message
            }
        }

        let headlessDuration: TimeInterval? = headlessPhase.map { phase in
            let accumulated = max(0, sharedSnapshot.elapsedDuration ?? 0)
            guard phase == .recording else { return accumulated }
            return accumulated + max(
                0,
                Date().timeIntervalSince(sharedSnapshot.startedAt)
            )
        }
        let headlessSessionIsVisible = headlessPhase != nil

        let practicedControlCenterStart = defaults.bool(
            forKey: OnboardingKeys.practicedControl
        )
        let keyboardSetup = keyboardSetupStatusStore.resolution()
        let completedOnboarding = resolvedCompletedOnboarding(
            practicedControlCenterStart: practicedControlCenterStart,
            keyboardSetup: keyboardSetup
        )
        let result: [String: Any] = [
            "phase": phase,
            "errorText": errorText,
            "transcriptText": model.transcriptText,
            "language": languageDictionary(model.language),
            "languages": TranscriptionLanguage.supportedCases.map(languageDictionary),
            "cleanSpeech": model.cleanSpeech,
            "autoCopy": model.autoCopy,
            "hasAPIKey": model.hasAPIKey,
            "needsMicrophoneSettings": model.needsMicrophoneSettings,
            "recordingNotice": model.recordingNotice ?? NSNull(),
            "isPreparingKeyboardSession": model.isPreparingKeyboardSession
                || headlessPhase == .starting,
            "isKeyboardDictation": model.isKeyboardDictation
                || headlessSessionIsVisible,
            "hasRecoverableRecording": model.hasRecoverableRecording
                || (headlessPhase == .failed
                    && sharedSnapshot.hasRecoverableAudio == true),
            "duration": headlessDuration ?? model.sessionElapsedDuration,
            "level": headlessPhase == .recording
                ? DictationEngine.shared.recordingLevel
                : (model.isPaused
                    ? model.recorder.heldLevel
                    : model.recorder.level),
            "completedOnboarding": completedOnboarding,
            "practicedControlCenterStart": practicedControlCenterStart,
            "keyboardSetupDetected": keyboardSetup.wasDetected,
            "keyboardFullAccess": keyboardSetup.hasFullAccess,
            "history": model.history.items.map(historyDictionary),
            "historyRetention": model.history.retention.rawValue,
            "launchStateReady": launchStateReady,
        ]
        if !didLogInitialBridgeSnapshot {
            didLogInitialBridgeSnapshot = true
            Observability.logLaunchPresentation(
                stage: "first_bridge_snapshot",
                phase: phase,
                completedOnboarding: completedOnboarding,
                launchStateReady: launchStateReady
            )
        }
        return result
    }

    /// A headless Control Widget intent has no scene lifecycle callback. Keep
    /// an already-visible containing app and first-run onboarding synchronized
    /// through the same bridge event without constructing a second recorder.
    func sharedDictationDidChange() {
        stateDidChange.send()
    }

    func markControlCenterPractice() {
        defaults.set(true, forKey: OnboardingKeys.practicedControl)
        stateDidChange.send()
    }

    func completeOnboarding() {
        defaults.set(true, forKey: OnboardingKeys.completed)
        // Preserve rollback compatibility with build 16 while v3 remains the
        // canonical key shared with the former SwiftUI containing app.
        defaults.set(true, forKey: OnboardingKeys.legacyCompleted)
        stateDidChange.send()
    }

    func markInitialLaunchStateReady(stage: String) {
        guard !launchStateReady else { return }
        launchStateReleaseTask?.cancel()
        launchStateReleaseTask = nil
        launchStateReady = true
        Observability.logLaunchPresentation(
            stage: stage,
            phase: nil,
            completedOnboarding: resolvedCompletedOnboarding(),
            launchStateReady: true
        )
        stateDidChange.send()
    }

    func scheduleInitialLaunchStateReadyIfActive() {
        guard UIApplication.shared.applicationState == .active else { return }
        scheduleInitialLaunchStateReady()
    }

    /// A Control Center OpenIntent may run just after the scene becomes active.
    /// Hold only the initial idle presentation for a bounded interval; the
    /// intent cancels this task and releases the gate immediately after it has
    /// synchronously moved AppModel into its preparing state.
    private func scheduleInitialLaunchStateReady() {
        guard !launchStateReady, launchStateReleaseTask == nil else { return }
        launchStateReleaseTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(220))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            launchStateReleaseTask = nil
            markInitialLaunchStateReady(stage: "scene_active_grace")
        }
    }

    func setLanguage(_ rawValue: String) throws {
        guard let language = TranscriptionLanguage(rawValue: rawValue) else {
            throw NativeBridgeError.invalidLanguage
        }
        model.language = language
    }

    func historyItem(id: String) throws -> TranscriptItem {
        guard
            let uuid = UUID(uuidString: id),
            let item = model.history.items.first(where: { $0.id == uuid })
        else {
            throw NativeBridgeError.missingHistoryItem
        }
        return item
    }

    private func bind(to model: AppModel) {
        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleNotification() }
            .store(in: &observers)
        model.recorder.objectWillChange
            .sink { [weak self] _ in self?.scheduleNotification(delay: 0.08) }
            .store(in: &observers)
        model.history.objectWillChange
            .sink { [weak self] _ in self?.scheduleNotification() }
            .store(in: &observers)
        model.audioDiagnostics.objectWillChange
            .sink { [weak self] _ in self?.scheduleNotification() }
            .store(in: &observers)
    }

    private func scheduleNotification(delay: TimeInterval = 0.01) {
        if let pendingNotification {
            // Meter updates arrive at the same cadence as this bridge delay.
            // Cancelling and rescheduling on every sample could postpone the
            // React Native state event forever. Keep the earliest pending emit,
            // while still allowing a phase change to pre-empt a meter emit.
            guard delay < (pendingNotificationDelay ?? delay) else { return }
            pendingNotification.cancel()
        }
        notificationGeneration &+= 1
        let generation = notificationGeneration
        let notification = DispatchWorkItem { [weak self] in
            guard let self, generation == notificationGeneration else { return }
            pendingNotification = nil
            pendingNotificationDelay = nil
            if model.isPreparingKeyboardSession
                || (model.isRecording && model.isKeyboardDictation) {
                defaults.set(
                    true,
                    forKey: OnboardingKeys.practicedControl
                )
            }
            stateDidChange.send()
        }
        pendingNotification = notification
        pendingNotificationDelay = delay
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: notification
        )
    }

    private func languageDictionary(
        _ language: TranscriptionLanguage
    ) -> [String: Any] {
        [
            "rawValue": language.rawValue,
            "title": language.title,
        ]
    }

    private func resolvedCompletedOnboarding(
        practicedControlCenterStart: Bool? = nil,
        keyboardSetup: KeyboardSetupResolution? = nil
    ) -> Bool {
        if defaults.bool(forKey: OnboardingKeys.completed) {
            return true
        }
        if defaults.bool(forKey: OnboardingKeys.legacyCompleted) {
            defaults.set(true, forKey: OnboardingKeys.completed)
            return true
        }

        let practicedControlCenterStart = practicedControlCenterStart
            ?? defaults.bool(forKey: OnboardingKeys.practicedControl)
        let keyboardSetup = keyboardSetup
            ?? keyboardSetupStatusStore.resolution()
        guard practicedControlCenterStart, keyboardSetup.hasFullAccess else {
            return false
        }

        // Completion is derived from the two real system boundaries and then
        // persisted only to avoid replaying setup after later OS state churn.
        defaults.set(true, forKey: OnboardingKeys.completed)
        defaults.set(true, forKey: OnboardingKeys.legacyCompleted)
        return true
    }

    private func historyDictionary(_ item: TranscriptItem) -> [String: Any] {
        let diagnostic = model.audioDiagnostics.record(for: item.id)
        return [
            "id": item.id.uuidString,
            "text": item.text,
            "createdAt": ISO8601DateFormatter().string(from: item.createdAt),
            "languageCode": item.languageCode ?? NSNull(),
            "duration": item.duration,
            "hasAudio": diagnostic != nil,
            "audioPlaying": model.audioDiagnostics.playingHistoryID == item.id,
            "audioSignalLabel": diagnostic?.signalLabel ?? NSNull(),
            "microphoneModeLabel": diagnostic?.microphoneModeLabel ?? NSNull(),
        ]
    }
}

private enum NativeBridgeError: LocalizedError {
    case invalidLanguage
    case missingHistoryItem

    var errorDescription: String? {
        switch self {
        case .invalidLanguage:
            "That transcription language is not supported by this binary."
        case .missingHistoryItem:
            "That transcript is no longer in history."
        }
    }
}

private final class PromiseCallbacks: @unchecked Sendable {
    let resolve: RCTPromiseResolveBlock
    let reject: RCTPromiseRejectBlock

    init(
        resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock
    ) {
        self.resolve = resolve
        self.reject = reject
    }
}

@objc(ElevenLabsNative)
final class ElevenLabsNative: RCTEventEmitter, @unchecked Sendable {
    private var changeObserver: AnyCancellable?
    private var hasJavaScriptListeners = false

    override init() {
        super.init()
        DispatchQueue.main.async { [weak self] in
            self?.changeObserver = ElevenLabsCoordinator.shared.stateDidChange
                .sink { [weak self] _ in self?.emitSnapshot() }
        }
    }

    @objc
    override static func requiresMainQueueSetup() -> Bool { true }

    override func supportedEvents() -> [String] {
        ["ElevenLabsStateChanged"]
    }

    override func startObserving() {
        hasJavaScriptListeners = true
        DispatchQueue.main.async {
            ElevenLabsCoordinator.shared.scheduleInitialLaunchStateReadyIfActive()
        }
        emitSnapshot()
    }

    override func stopObserving() {
        hasJavaScriptListeners = false
    }

    @objc(getState:rejecter:)
    func getState(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {}
    }

    @objc(completeOnboarding:rejecter:)
    func completeOnboarding(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.completeOnboarding()
        }
    }

    @objc(openKeyboardSettings:rejecter:)
    func openKeyboardSettings(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.openKeyboardSettings()
        }
    }

    @objc(saveAPIKey:resolver:rejecter:)
    func saveAPIKey(
        _ value: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            try ElevenLabsCoordinator.shared.model.saveAPIKey(value)
        }
    }

    @objc(deleteAPIKey:rejecter:)
    func deleteAPIKey(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            try ElevenLabsCoordinator.shared.model.deleteAPIKey()
        }
    }

    @objc(setLanguage:resolver:rejecter:)
    func setLanguage(
        _ value: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            try ElevenLabsCoordinator.shared.setLanguage(value)
        }
    }

    @objc(setCleanSpeech:resolver:rejecter:)
    func setCleanSpeech(
        _ value: Bool,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.cleanSpeech = value
        }
    }

    @objc(setAutoCopy:resolver:rejecter:)
    func setAutoCopy(
        _ value: Bool,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.autoCopy = value
        }
    }

    @objc(setTranscriptText:resolver:rejecter:)
    func setTranscriptText(
        _ value: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.transcriptText = value
        }
    }

    @objc(copyTranscript:rejecter:)
    func copyTranscript(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.copyTranscript()
        }
    }

    @objc(clearTranscript:rejecter:)
    func clearTranscript(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.clearTranscript()
        }
    }

    @objc(retryAfterError:rejecter:)
    func retryAfterError(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.retryAfterError()
        }
    }

    @objc(discardRecoverableRecording:rejecter:)
    func discardRecoverableRecording(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.discardRecoverableRecording()
        }
    }

    @objc(dismissError:rejecter:)
    func dismissError(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.dismissError()
        }
    }

    @objc(copyHistoryItem:resolver:rejecter:)
    func copyHistoryItem(
        _ id: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            let item = try ElevenLabsCoordinator.shared.historyItem(id: id)
            ElevenLabsCoordinator.shared.model.copyHistoryItem(item)
        }
    }

    @objc(useHistoryItem:resolver:rejecter:)
    func useHistoryItem(
        _ id: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            let item = try ElevenLabsCoordinator.shared.historyItem(id: id)
            ElevenLabsCoordinator.shared.model.useHistoryItem(item)
        }
    }

    @objc(deleteHistoryItem:resolver:rejecter:)
    func deleteHistoryItem(
        _ id: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            let item = try ElevenLabsCoordinator.shared.historyItem(id: id)
            ElevenLabsCoordinator.shared.model.deleteHistoryItem(item)
        }
    }

    @objc(updateHistoryItem:text:resolver:rejecter:)
    func updateHistoryItem(
        _ id: String,
        text: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            guard let uuid = UUID(uuidString: id) else {
                throw NativeBridgeError.missingHistoryItem
            }
            guard ElevenLabsCoordinator.shared.model.history.updateText(
                id: uuid,
                text: text
            ) != nil else {
                throw NativeBridgeError.missingHistoryItem
            }
        }
    }

    @objc(toggleHistoryAudio:resolver:rejecter:)
    func toggleHistoryAudio(
        _ id: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            let item = try ElevenLabsCoordinator.shared.historyItem(id: id)
            try ElevenLabsCoordinator.shared.model.toggleHistoryAudio(item)
        }
    }

    @objc(reportHistoryAudioIssue:resolver:rejecter:)
    func reportHistoryAudioIssue(
        _ id: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            let item = try ElevenLabsCoordinator.shared.historyItem(id: id)
            try ElevenLabsCoordinator.shared.model.reportHistoryAudioIssue(item)
        }
    }

    @objc(clearHistory:rejecter:)
    func clearHistory(
        _ resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            ElevenLabsCoordinator.shared.model.clearHistory()
        }
    }

    @objc(setHistoryRetention:resolver:rejecter:)
    func setHistoryRetention(
        _ value: String,
        resolver resolve: @escaping RCTPromiseResolveBlock,
        rejecter reject: @escaping RCTPromiseRejectBlock
    ) {
        resolveState(resolve, reject: reject) {
            guard let policy = HistoryRetentionPolicy(rawValue: value) else {
                throw NativeBridgeError.invalidLanguage
            }
            ElevenLabsCoordinator.shared.model.setHistoryRetention(policy)
        }
    }

    private func resolveState(
        _ resolve: @escaping RCTPromiseResolveBlock,
        reject: @escaping RCTPromiseRejectBlock,
        action: @escaping @MainActor () throws -> Void
    ) {
        let callbacks = PromiseCallbacks(resolve: resolve, reject: reject)
        DispatchQueue.main.async {
            do {
                try action()
                callbacks.resolve(ElevenLabsCoordinator.shared.snapshot())
            } catch {
                callbacks.reject(
                    "native_action_failed",
                    error.localizedDescription,
                    error
                )
            }
        }
    }

    private func emitSnapshot() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.hasJavaScriptListeners else { return }
            self.sendEvent(
                withName: "ElevenLabsStateChanged",
                body: ElevenLabsCoordinator.shared.snapshot()
            )
        }
    }
}
