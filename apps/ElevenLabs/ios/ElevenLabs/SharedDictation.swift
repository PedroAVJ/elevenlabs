import CryptoKit
import Darwin
import Foundation

enum SharedDictationConstants {
    static let appGroupIdentifier: String = {
        let configuredIdentifier = Bundle.main.object(
            forInfoDictionaryKey: "ElevenLabsAppGroupIdentifier"
        ) as? String
        let normalizedIdentifier = configuredIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let normalizedIdentifier,
              !normalizedIdentifier.isEmpty,
              !normalizedIdentifier.contains("$(") else {
            return "group.com.example.ElevenLabs"
        }

        return normalizedIdentifier
    }()
    static let storageKey = "active-dictation-session-v1"
    static let stateFileName = "active-dictation-session-v2.json"
    static let stateLockFileName = "active-dictation-session-v2.lock"
    /// The App Group container is not reachable over `devicectl`, so each
    /// process also mirrors its session diagnostics into its own Documents
    /// directory. A device-only launch or return failure stays actionable
    /// without reproducing it while attached to Xcode.
    static let diagnosticsFileName = "last-dictation-session.json"
    static let diagnosticsHistoryFileName = "dictation-sessions.jsonl"
    static let hostApplicationIdentityKey = "host-application-identity-v1"
    static let visibleHostApplicationLeaseKey =
        "visible-host-application-lease-v1"
}

/// Privacy-safe evidence that a keyboard field was active and available for
/// delivery. UIKit inconsistently reports absent context as `nil` or an empty
/// string while a keyboard is removed and restored, so those representations
/// normalize to the same identity. The fingerprint remains useful for shared
/// diagnostics, but delivery always follows the keyboard's live document proxy.
enum InsertionContextFingerprint {
    static func make(
        documentIdentifier: UUID,
        textBeforeInput: String?,
        textAfterInput: String?,
        selectedText: String?,
        keyboardType: Int?
    ) -> String {
        let before = String((textBeforeInput ?? "").suffix(128))
        let after = String((textAfterInput ?? "").prefix(128))
        let selected = String((selectedText ?? "").prefix(128))
        let context = [
            documentIdentifier.uuidString,
            before,
            after,
            selected,
            String(keyboardType ?? 0),
        ].joined(separator: "\u{1F}")
        return SHA256.hash(data: Data(context.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// A host identity captured while the keyboard is still embedded in another
/// app. The process identifier is intentionally part of the record: a bundle
/// identifier by itself can become stale when the user changes apps.
struct HostApplicationIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32
    let capturedAt: Date
}

/// A deliberately short-lived keyboard-host breadcrumb. Some supported apps
/// expose the arbiter's exact bundle identifier while withholding the host PID.
/// That bundle is safe only for the Live Activity transition immediately after
/// the visible keyboard wrote it; it must never become a durable host identity.
struct VisibleHostApplicationLease: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let processIdentifier: Int32?
    let capturedAt: Date
}

/// A process-local arbiter value is usable only when UIKit published it after
/// the current keyboard appearance began and the host process stayed stable.
/// Keeping this policy in the shared target makes the stale-host boundary
/// directly testable without loading UIKit's private keyboard classes.
enum HostApplicationCapturePolicy {
    static func canonicalSupportedBundleIdentifier(
        _ candidate: String?,
        supportedBundleIdentifiers: [String]
    ) -> String? {
        guard let candidate else { return nil }
        let normalized = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return supportedBundleIdentifiers.first {
            $0.lowercased() == normalized
        }
    }

    static func supportedIdentity(
        _ identity: HostApplicationIdentity?,
        supportedBundleIdentifiers: [String]
    ) -> HostApplicationIdentity? {
        guard
            let identity,
            canonicalSupportedBundleIdentifier(
                identity.bundleIdentifier,
                supportedBundleIdentifiers: supportedBundleIdentifiers
            ) != nil
        else {
            return nil
        }
        return identity
    }

    static func baselineGeneration(
        currentGeneration: UInt64,
        cleanBoundaryGeneration: UInt64?,
        processHasEstablishedAppearance: Bool
    ) -> UInt64 {
        if let cleanBoundaryGeneration {
            return cleanBoundaryGeneration
        }
        return processHasEstablishedAppearance ? currentGeneration : 0
    }

    static func accepts(
        candidateBundleIdentifier: String,
        captureGeneration: UInt64,
        appearanceBaselineGeneration: UInt64,
        expectedProcessIdentifier: Int32?,
        currentProcessIdentifier: Int32?,
        previousIdentity: HostApplicationIdentity?
    ) -> Bool {
        guard
            let expectedProcessIdentifier,
            expectedProcessIdentifier > 1,
            currentProcessIdentifier == expectedProcessIdentifier
        else {
            return false
        }
        guard captureGeneration > appearanceBaselineGeneration else {
            return false
        }

        // UIKit can deliver a destination callback after the prior host has
        // already disappeared. Never bind that prior bundle to a new PID.
        if rejectsPreviousHost(
            candidateBundleIdentifier: candidateBundleIdentifier,
            expectedProcessIdentifier: expectedProcessIdentifier,
            previousIdentity: previousIdentity
        ) {
            return false
        }
        return true
    }

    /// The visible-keyboard lease may carry a missing PID, but only when the
    /// arbiter callback belongs to the current appearance generation. A real
    /// PID, when available, retains all of the durable identity safeguards.
    static func acceptsVisibleLease(
        candidateBundleIdentifier: String,
        captureGeneration: UInt64,
        appearanceBaselineGeneration: UInt64,
        expectedProcessIdentifier: Int32?,
        currentProcessIdentifier: Int32?,
        previousIdentity: HostApplicationIdentity?
    ) -> Bool {
        guard
            captureGeneration > appearanceBaselineGeneration,
            currentProcessIdentifier == expectedProcessIdentifier
        else {
            return false
        }

        guard let expectedProcessIdentifier else {
            return true
        }
        guard expectedProcessIdentifier > 1 else { return false }
        return !rejectsPreviousHost(
            candidateBundleIdentifier: candidateBundleIdentifier,
            expectedProcessIdentifier: expectedProcessIdentifier,
            previousIdentity: previousIdentity
        )
    }

    static func rejectsPreviousHost(
        candidateBundleIdentifier: String,
        expectedProcessIdentifier: Int32,
        previousIdentity: HostApplicationIdentity?
    ) -> Bool {
        guard
            let previousIdentity,
            previousIdentity.processIdentifier != expectedProcessIdentifier
        else {
            return false
        }
        return previousIdentity.bundleIdentifier.caseInsensitiveCompare(
            candidateBundleIdentifier
        ) == .orderedSame
    }
}

/// Cross-process handoff for one immediate Live Activity transition. Unlike
/// `HostApplicationIdentityCache`, this accepts a missing PID because its
/// four-second lifetime is continuously refreshed only by a visible keyboard.
struct VisibleHostApplicationLeaseCache: @unchecked Sendable {
    static let maximumAge: TimeInterval = 4

    private let defaults: UserDefaults?
    private let storageKey: String

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageKey: String =
            SharedDictationConstants.visibleHostApplicationLeaseKey
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        self.storageKey = storageKey
    }

    func load() -> VisibleHostApplicationLease? {
        guard
            let data = defaults?.data(forKey: storageKey),
            let lease = try? JSONDecoder().decode(
                VisibleHostApplicationLease.self,
                from: data
            ),
            !lease.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            lease.processIdentifier.map({ $0 > 1 }) ?? true
        else {
            return nil
        }
        return lease
    }

    func freshLease(
        now: Date = Date(),
        maximumAge: TimeInterval = Self.maximumAge
    ) -> VisibleHostApplicationLease? {
        guard let lease = load() else { return nil }
        let age = now.timeIntervalSince(lease.capturedAt)
        guard age >= -5, age <= maximumAge else { return nil }
        return lease
    }

    func save(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        capturedAt: Date = Date()
    ) {
        let identifier = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !identifier.isEmpty else { return }
        let normalizedProcessIdentifier = processIdentifier.flatMap {
            $0 > 1 ? $0 : nil
        }
        let lease = VisibleHostApplicationLease(
            bundleIdentifier: identifier,
            processIdentifier: normalizedProcessIdentifier,
            capturedAt: capturedAt
        )
        guard let data = try? JSONEncoder().encode(lease) else { return }
        defaults?.set(data, forKey: storageKey)
        _ = defaults?.synchronize()
    }

    func clear() {
        defaults?.removeObject(forKey: storageKey)
        _ = defaults?.synchronize()
    }
}

/// Carries a verified keyboard-host identity across extension termination and
/// app upgrades. Reads require the exact live host PID and a short age window;
/// there is deliberately no bundle-only fallback.
struct HostApplicationIdentityCache: @unchecked Sendable {
    /// This is only a last-resort bridge across a short extension restart. A
    /// small lease sharply limits PID-reuse risk; live host evidence wins.
    static let defaultMaximumAge: TimeInterval = 60

    private let defaults: UserDefaults?
    private let storageKey: String

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageKey: String = SharedDictationConstants.hostApplicationIdentityKey
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        self.storageKey = storageKey
    }

    func load() -> HostApplicationIdentity? {
        guard
            let data = defaults?.data(forKey: storageKey),
            let identity = try? JSONDecoder().decode(
                HostApplicationIdentity.self,
                from: data
            ),
            identity.processIdentifier > 1,
            !identity.bundleIdentifier.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
        else {
            return nil
        }
        return identity
    }

    func matchingIdentity(
        processIdentifier: Int32?,
        now: Date = Date(),
        maximumAge: TimeInterval = Self.defaultMaximumAge
    ) -> HostApplicationIdentity? {
        guard
            let processIdentifier,
            processIdentifier > 1,
            let identity = load(),
            identity.processIdentifier == processIdentifier
        else {
            return nil
        }
        let age = now.timeIntervalSince(identity.capturedAt)
        guard age >= -5, age <= maximumAge else { return nil }
        return identity
    }

    func save(
        bundleIdentifier: String,
        processIdentifier: Int32,
        capturedAt: Date = Date()
    ) {
        let identifier = bundleIdentifier.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard processIdentifier > 1, !identifier.isEmpty else { return }
        let identity = HostApplicationIdentity(
            bundleIdentifier: identifier,
            processIdentifier: processIdentifier,
            capturedAt: capturedAt
        )
        guard let data = try? JSONEncoder().encode(identity) else { return }
        defaults?.set(data, forKey: storageKey)
        _ = defaults?.synchronize()
    }

    func clear() {
        defaults?.removeObject(forKey: storageKey)
        _ = defaults?.synchronize()
    }
}

enum SharedDictationPhase: String, Codable {
    case idle
    case launching
    case starting
    case recording
    case pausing
    case paused
    case resuming
    case transcribing
    case completed
    /// The extension persisted its intent to insert before touching the host
    /// field. If it dies here, automatic replay would risk duplicate text.
    case inserting
    /// A transcript from an older build was preserved for explicit recovery.
    /// Current keyboard delivery follows the live document proxy instead.
    case deliveryBlocked
    case failed
    case cancelled
    case inserted
    case handled

    /// The containing app owns every phase that depends on its recorder or a
    /// transcription task continuing to make progress. A paused dictation is
    /// deliberately different: all hot audio is already journaled, so iOS may
    /// suspend the process until the next intent without making the session
    /// abandoned.
    var isContainingAppOwned: Bool {
        switch self {
        case .launching, .starting, .recording, .pausing, .resuming,
             .transcribing:
            true
        case .idle, .paused, .completed, .inserting, .deliveryBlocked,
             .failed, .cancelled, .inserted, .handled:
            false
        }
    }

    /// Active capture phases and recoverable failures keep the session's
    /// microphone lease until the recorder or recovery path explicitly
    /// releases it. Delivery and closed terminal phases still block replacement
    /// through their phase, but must not strand a lease that prevents the next
    /// legitimate session after they are handled.
    var retainsSessionCaptureLease: Bool {
        switch self {
        case .launching, .starting, .recording, .pausing, .paused, .resuming,
             .transcribing, .failed:
            true
        case .idle, .completed, .inserting, .deliveryBlocked, .cancelled,
             .inserted, .handled:
            false
        }
    }

    /// The keyboard uses the app's heartbeat to turn an abandoned active phase
    /// into a recoverable failure instead of waiting forever.
    var containingAppAbandonmentTimeout: TimeInterval {
        switch self {
        case .launching, .starting, .resuming:
            // Permission sheets and cold app launches are user-paced.
            90
        case .recording, .pausing, .transcribing:
            15
        case .idle, .paused, .completed, .inserting, .deliveryBlocked,
             .failed, .cancelled, .inserted, .handled:
            0
        }
    }

    /// A background session starts without a destination. While the extension
    /// is resident, it may attach privacy-safe evidence of the currently
    /// focused insertion point for diagnostics. Delivery still uses the live
    /// document proxy when the completed transcript is ready.
    var allowsKeyboardInsertionContextClaim: Bool {
        switch self {
        case .starting, .recording, .pausing, .paused, .resuming,
             .transcribing, .completed:
            true
        case .idle, .launching, .inserting, .deliveryBlocked, .failed,
             .cancelled, .inserted, .handled:
            false
        }
    }
}

enum SharedDictationRecoveryAction: String, Codable {
    case openContainingApp
    case retryTranscription
    case insertHere
    case reviewPossibleInsertion
}

enum SharedDictationDeliverySource: String, Codable, Equatable, Sendable {
    case realtimeDraft
    case batch
}

enum SharedBatchCompletionPublishResult: Equatable, Sendable {
    case publishedBatch
    case realtimeDeliveryOwnsSession
    case rejected
}

enum SharedDictationCommand: String, Codable, Hashable {
    case none
    case pause
    case resume
    case stop
    case cancel
    case retry
}

enum SharedDictationSessionKind: String, Codable, Hashable {
    /// The protected keyboard → containing app → host switchback lane, whose
    /// recorder and command monitor live in AppModel.
    case keyboardRoundTrip
    /// The Back Tap/App Intent lane, whose ordered segment manifest is owned by
    /// DictationEngine and whose controls live in the Live Activity.
    case segmentedIntent
}

/// Live Activity, Control Center, and Back Tap intents execute in the app
/// process, but a keyboard round-trip recorder is owned by `AppModel`, not by
/// `DictationEngine`. Route those controls through the existing locked App
/// Group command lane so every surface controls the process that actually owns
/// the microphone. Segmented intent sessions deliberately fall through to
/// `DictationEngine` instead.
enum SharedDictationIntentCommandRouter {
    static func routeToggleToKeyboardOwner(
        store: SharedDictationStore = SharedDictationStore()
    ) -> Bool {
        let snapshot = store.load()
        let command: SharedDictationCommand
        switch snapshot.phase {
        case .recording:
            command = .pause
        case .paused:
            command = .resume
        default:
            return false
        }
        return routeToKeyboardOwner(
            command,
            sessionID: snapshot.sessionID,
            store: store
        )
    }

    static func routeToKeyboardOwner(
        _ command: SharedDictationCommand,
        sessionID: UUID,
        store: SharedDictationStore = SharedDictationStore()
    ) -> Bool {
        let snapshot = store.load()
        guard
            snapshot.sessionID == sessionID,
            snapshot.sessionKind == .keyboardRoundTrip,
            allowedCommands(for: snapshot.phase).contains(command)
        else {
            return false
        }

        // A keyboard button writes its command synchronously before triggering
        // the intent-backed wakeup. Treat that same unacknowledged command as
        // already routed instead of creating a duplicate sequence entry.
        if
            snapshot.command == command,
            (snapshot.commandSequence ?? 0)
                > (snapshot.acknowledgedCommandSequence ?? 0)
        {
            return true
        }
        return store.send(command, sessionID: sessionID)
    }

    private static func allowedCommands(
        for phase: SharedDictationPhase
    ) -> Set<SharedDictationCommand> {
        switch phase {
        case .recording:
            [.pause, .stop, .cancel]
        case .paused:
            [.resume, .stop, .cancel]
        default:
            []
        }
    }
}

struct SharedDictationSnapshot: Codable, Equatable {
    var sessionID: UUID
    var phase: SharedDictationPhase
    var command: SharedDictationCommand
    /// Optional so snapshots written before the two engines were distinguished
    /// remain decodable. Every newly created session writes an explicit kind.
    var sessionKind: SharedDictationSessionKind? = nil
    var transcript: String?
    /// Best-effort Scribe Realtime text displayed inside the keyboard while
    /// the journaled recording continues toward the quality-first batch pass.
    /// Optional fields keep snapshots from previous builds decodable.
    var realtimeTranscript: String? = nil
    /// True only when the batch worker has reached the final protected source
    /// for this delivery. Older continuation parts may still refine in order,
    /// but they cannot be sent early without skipping newer recorded audio.
    var realtimeDraftSendable: Bool? = nil
    /// Set only at the atomic insertion boundary. Batch completion consults
    /// this after a fast live-draft send so it can never insert a second copy.
    var deliverySource: SharedDictationDeliverySource? = nil
    var errorMessage: String?
    /// Whether a History row contains this transcript. `false` is expected
    /// when the user selected the Never retention policy.
    var historyPersisted: Bool? = nil
    /// True only when a private, journaled audio file can be retried after the
    /// process exits. Ordinary setup failures remain safely dismissible.
    var hasRecoverableAudio: Bool? = nil
    /// Privacy-safe proof that an active keyboard text field claimed delivery.
    /// Stop & Insert refreshes it at the tap's cursor, and automatic insertion
    /// requires that exact context to remain current through transcription.
    var insertionContextFingerprint: String? = nil
    var recoveryAction: SharedDictationRecoveryAction? = nil
    /// Monotonic counters make cross-process state changes diagnosable and let
    /// the recorder consume each command at most once.
    var revision: UInt64? = nil
    var commandSequence: UInt64? = nil
    var acknowledgedCommandSequence: UInt64? = nil
    /// Cross-entry-point microphone lease. Manual in-app recording does not
    /// need a keyboard-delivery session, but it must still exclude a Back Tap
    /// or App Intent from opening a second AVAudioSession recorder.
    var captureOwnerID: UUID? = nil
    var captureLeaseUpdatedAt: Date? = nil
    var returnBundleIdentifier: String?
    var returnProcessIdentifier: Int32?
    var hostResolutionAttempts: [String]?
    var launchAttempts: [String]?
    var successfulLaunchRoute: String?
    var returnAttempts: [String]?
    var incomingURLDeliveryRoute: String?
    var incomingURLSourceApplication: String?
    /// Historical diagnostic for the retired background-pasteboard experiment.
    /// Keep it optional so sessions written by older builds still decode.
    var clipboardLanded: Bool? = nil
    /// Hot-microphone time already completed before the current segment.
    /// Optional for snapshots written by older builds.
    var elapsedDuration: TimeInterval? = nil
    var startedAt: Date
    var updatedAt: Date

    static var idle: SharedDictationSnapshot {
        SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .idle,
            command: .none,
            sessionKind: nil,
            transcript: nil,
            errorMessage: nil,
            historyPersisted: nil,
            hasRecoverableAudio: nil,
            insertionContextFingerprint: nil,
            recoveryAction: nil,
            revision: 0,
            commandSequence: 0,
            acknowledgedCommandSequence: 0,
            captureOwnerID: nil,
            captureLeaseUpdatedAt: nil,
            returnBundleIdentifier: nil,
            returnProcessIdentifier: nil,
            hostResolutionAttempts: nil,
            launchAttempts: nil,
            successfulLaunchRoute: nil,
            returnAttempts: nil,
            incomingURLDeliveryRoute: nil,
            incomingURLSourceApplication: nil,
            elapsedDuration: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
    }
}

struct SharedDictationStore: @unchecked Sendable {
    private let defaults: UserDefaults?
    private let storageDirectory: URL?
    private let requiresSharedContainer: Bool

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageDirectory: URL? = nil
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        requiresSharedContainer =
            suiteName == SharedDictationConstants.appGroupIdentifier
        if let storageDirectory {
            self.storageDirectory = storageDirectory
        } else if suiteName == SharedDictationConstants.appGroupIdentifier {
            self.storageDirectory = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName
            )
        } else {
            // Tests and previews can continue to use isolated UserDefaults.
            self.storageDirectory = nil
        }
    }

    var isAvailable: Bool {
        storageDirectory != nil
            || (!requiresSharedContainer && defaults != nil)
    }

    var isCaptureLeaseActive: Bool {
        let snapshot = load()
        return hasLiveCaptureLease(snapshot)
    }

    func load() -> SharedDictationSnapshot {
        withStateLock { loadUnlocked() } ?? loadUnlocked()
    }

    @discardableResult
    func begin(
        returnBundleIdentifier: String?,
        returnProcessIdentifier: Int32? = nil,
        insertionContextFingerprint: String? = nil
    ) -> SharedDictationSnapshot? {
        withStateLock {
            let previous = loadUnlocked()
            guard [
                SharedDictationPhase.idle,
                .inserted,
                .handled,
                .cancelled,
            ].contains(previous.phase) else {
                return nil
            }
            guard !hasLiveCaptureLease(previous) else { return nil }
            let sessionID = UUID()
            let snapshot = SharedDictationSnapshot(
                sessionID: sessionID,
                phase: .launching,
                command: .none,
                sessionKind: .keyboardRoundTrip,
                transcript: nil,
                errorMessage: nil,
                historyPersisted: nil,
                hasRecoverableAudio: nil,
                insertionContextFingerprint: insertionContextFingerprint,
                recoveryAction: nil,
                revision: (previous.revision ?? 0) + 1,
                commandSequence: 0,
                acknowledgedCommandSequence: 0,
                captureOwnerID: sessionID,
                captureLeaseUpdatedAt: Date(),
                returnBundleIdentifier: returnBundleIdentifier,
                returnProcessIdentifier: returnProcessIdentifier,
                hostResolutionAttempts: nil,
                launchAttempts: nil,
                successfulLaunchRoute: nil,
                returnAttempts: nil,
                incomingURLDeliveryRoute: nil,
                incomingURLSourceApplication: nil,
                elapsedDuration: nil,
                startedAt: Date(),
                updatedAt: Date()
            )
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    /// Atomically turns a keyboard launch into the one foreground capture
    /// attempt for that session. URL delivery and scene activation may both
    /// observe the same launch, so the phase transition and lease renewal must
    /// happen under the same cross-process lock.
    ///
    /// A late URL may arrive after the keyboard's launch watchdog publishes a
    /// failure. That failure is claimable only while this exact session still
    /// owns a live lease. A recorder failure releases the lease first, making
    /// every subsequently queued launch a harmless no-op that cannot replace
    /// the original error.
    func claimLaunchingSession(
        sessionID: UUID
    ) -> SharedDictationSnapshot? {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID else { return nil }

            switch snapshot.phase {
            case .launching:
                // Older snapshots predate the capture-owner fields. The
                // session identifier itself is sufficient to adopt those.
                guard
                    snapshot.captureOwnerID == nil
                        || snapshot.captureOwnerID == sessionID
                else {
                    return nil
                }
            case .failed:
                guard
                    snapshot.captureOwnerID == sessionID,
                    snapshot.hasRecoverableAudio == false,
                    hasLiveCaptureLease(snapshot)
                else {
                    return nil
                }
            default:
                return nil
            }

            snapshot.phase = .starting
            snapshot.errorMessage = nil
            snapshot.hasRecoverableAudio = nil
            snapshot.recoveryAction = nil
            snapshot.captureOwnerID = sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    /// Start an intent-driven session while iOS grants background capture.
    /// Publishing `starting` keeps the keyboard truthful until the recorder
    /// proves that the microphone is live. Never replace a completed transcript
    /// that the keyboard has not inserted yet.
    @discardableResult
    func beginBackgroundSession(
        returnBundleIdentifier: String? = nil,
        returnProcessIdentifier: Int32? = nil
    ) -> SharedDictationSnapshot? {
        withStateLock {
            let current = loadUnlocked()
            // A Back Tap/intent and the keyboard can arrive together. Session
            // creation is a compare-and-swap: only terminal sessions may be
            // replaced, so neither entry point can steal an active recorder or
            // a recoverable failed delivery from the other.
            guard [
                SharedDictationPhase.idle,
                .inserted,
                .handled,
                .cancelled,
            ].contains(current.phase) else {
                return nil
            }
            guard !hasLiveCaptureLease(current) else { return nil }

            var snapshot = SharedDictationSnapshot.idle
            snapshot.phase = .starting
            snapshot.sessionKind = .segmentedIntent
            snapshot.revision = (current.revision ?? 0) + 1
            snapshot.captureOwnerID = snapshot.sessionID
            snapshot.captureLeaseUpdatedAt = Date()
            snapshot.returnBundleIdentifier = returnBundleIdentifier
            snapshot.returnProcessIdentifier = returnProcessIdentifier
            guard saveUnlocked(snapshot) else { return nil }
            return snapshot
        } ?? nil
    }

    @discardableResult
    func setPhase(
        _ phase: SharedDictationPhase,
        sessionID: UUID,
        transcript: String? = nil,
        errorMessage: String? = nil,
        historyPersisted: Bool? = nil,
        hasRecoverableAudio: Bool? = nil,
        recoveryAction: SharedDictationRecoveryAction? = nil,
        clipboardLanded: Bool? = nil,
        elapsedDuration: TimeInterval? = nil,
        startedAt: Date? = nil
    ) -> Bool {
        update(sessionID: sessionID) { snapshot in
            if let startedAt {
                snapshot.startedAt = startedAt
            } else if phase == .recording && snapshot.phase != .recording {
                snapshot.startedAt = Date()
            }
            snapshot.phase = phase
            snapshot.transcript = transcript
            if phase != .transcribing {
                snapshot.realtimeDraftSendable = false
            }
            snapshot.errorMessage = errorMessage
            snapshot.historyPersisted = historyPersisted
            if let hasRecoverableAudio {
                snapshot.hasRecoverableAudio = hasRecoverableAudio
            }
            snapshot.recoveryAction = recoveryAction
            snapshot.clipboardLanded = clipboardLanded
            if let elapsedDuration {
                snapshot.elapsedDuration = max(0, elapsedDuration)
            }
        }
    }

    /// Compare-and-swap phase transition for cross-process ownership changes.
    /// Recovery can be offered by the foreground app at the same moment an App
    /// Intent rehydrates the background engine; only the process that still
    /// sees the expected phase may claim the parent session.
    @discardableResult
    func transitionPhase(
        from expectedPhases: [SharedDictationPhase],
        to phase: SharedDictationPhase,
        sessionID: UUID,
        transcript: String? = nil,
        errorMessage: String? = nil,
        historyPersisted: Bool? = nil,
        hasRecoverableAudio: Bool? = nil,
        recoveryAction: SharedDictationRecoveryAction? = nil,
        elapsedDuration: TimeInterval? = nil,
        startedAt: Date? = nil
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard expectedPhases.contains(snapshot.phase) else { return false }
            if let startedAt {
                snapshot.startedAt = startedAt
            } else if phase == .recording && snapshot.phase != .recording {
                snapshot.startedAt = Date()
            }
            snapshot.phase = phase
            snapshot.transcript = transcript
            if phase != .transcribing {
                snapshot.realtimeDraftSendable = false
            }
            snapshot.errorMessage = errorMessage
            snapshot.historyPersisted = historyPersisted
            if let hasRecoverableAudio {
                snapshot.hasRecoverableAudio = hasRecoverableAudio
            }
            snapshot.recoveryAction = recoveryAction
            if let elapsedDuration {
                snapshot.elapsedDuration = max(0, elapsedDuration)
            }
            return true
        }
    }

    /// Atomically verifies both ownership and the heartbeat cutoff before a
    /// keyboard declares a containing-app session abandoned. A heartbeat that
    /// lands at the timeout boundary therefore wins instead of being replaced
    /// by a stale read followed by an unconditional failure write.
    @discardableResult
    func failAbandonedSession(
        sessionID: UUID,
        phases: Set<SharedDictationPhase>,
        updatedAtOrBefore cutoff: Date,
        errorMessage: String,
        hasRecoverableAudio: Bool,
        recoveryAction: SharedDictationRecoveryAction?
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                phases.contains(snapshot.phase),
                snapshot.updatedAt <= cutoff
            else {
                return false
            }
            snapshot.phase = .failed
            snapshot.transcript = nil
            snapshot.errorMessage = errorMessage
            snapshot.hasRecoverableAudio = hasRecoverableAudio
            snapshot.recoveryAction = recoveryAction
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            return true
        }
    }

    func setReturnBundleIdentifier(
        _ bundleIdentifier: String,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.returnBundleIdentifier = bundleIdentifier
        }
    }

    /// Publishes a live preview without making it a delivery result. Realtime
    /// failures are deliberately invisible here: the durable batch lane keeps
    /// recording and remains the default insertion owner.
    @discardableResult
    func updateRealtimeTranscript(
        _ transcript: String,
        sessionID: UUID
    ) -> Bool {
        let normalized = transcript.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else { return false }
        return updateIf(
            sessionID: sessionID,
            mirrorsDiagnostics: false
        ) { snapshot in
            guard
                [.recording, .paused, .transcribing].contains(snapshot.phase),
                snapshot.deliverySource == nil
            else {
                return false
            }
            guard snapshot.realtimeTranscript != normalized else {
                return false
            }
            snapshot.realtimeTranscript = normalized
            return true
        }
    }

    @discardableResult
    func setRealtimeDraftSendable(
        _ isSendable: Bool,
        sessionID: UUID
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                snapshot.phase == .transcribing,
                snapshot.deliverySource == nil
            else {
                return false
            }
            guard snapshot.realtimeDraftSendable != isSendable else {
                return false
            }
            snapshot.realtimeDraftSendable = isSendable
            return true
        }
    }

    /// Claims the low-latency draft as the one insertion result while batch
    /// transcription continues in the containing app. Returning the claimed
    /// text from inside the lock keeps the keyboard from inserting a stale
    /// value read before another process won the delivery race.
    func claimRealtimeDraftForInsertion(sessionID: UUID) -> String? {
        withStateLock {
            var snapshot = loadUnlocked()
            guard
                snapshot.sessionID == sessionID,
                snapshot.phase == .transcribing,
                snapshot.deliverySource == nil,
                snapshot.realtimeDraftSendable == true,
                let transcript = snapshot.realtimeTranscript?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !transcript.isEmpty
            else {
                return nil
            }
            snapshot.phase = .inserting
            snapshot.command = .none
            snapshot.transcript = transcript
            snapshot.deliverySource = .realtimeDraft
            snapshot.realtimeDraftSendable = false
            snapshot.errorMessage = "Dictation Button may already have inserted this live draft. Review the field before inserting again."
            snapshot.recoveryAction = .reviewPossibleInsertion
            if snapshot.captureOwnerID == sessionID {
                snapshot.captureOwnerID = nil
                snapshot.captureLeaseUpdatedAt = nil
            }
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return nil }
            return transcript
        } ?? nil
    }

    /// Publishes the quality-first result only if realtime delivery did not
    /// already cross the insertion boundary. The winning source remains stable
    /// across extension termination, insertion confirmation, and batch races.
    func publishBatchCompletion(
        sessionID: UUID,
        transcript: String,
        historyPersisted: Bool,
        elapsedDuration: TimeInterval
    ) -> SharedBatchCompletionPublishResult {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID else { return .rejected }

            if
                snapshot.deliverySource == .realtimeDraft,
                [
                    SharedDictationPhase.completed,
                    .inserting,
                    .deliveryBlocked,
                    .inserted,
                    .handled,
                ].contains(snapshot.phase)
            {
                snapshot.historyPersisted = historyPersisted
                snapshot.hasRecoverableAudio = false
                snapshot.elapsedDuration = max(0, elapsedDuration)
                snapshot.captureOwnerID = nil
                snapshot.captureLeaseUpdatedAt = nil
                advanceRevision(&snapshot)
                guard saveUnlocked(snapshot) else { return .rejected }
                return .realtimeDeliveryOwnsSession
            }

            guard
                snapshot.phase == .transcribing,
                snapshot.deliverySource == nil
            else {
                return .rejected
            }
            let normalized = transcript.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !normalized.isEmpty else { return .rejected }
            snapshot.phase = .completed
            snapshot.command = .none
            snapshot.transcript = normalized
            snapshot.realtimeTranscript = nil
            snapshot.realtimeDraftSendable = false
            snapshot.errorMessage = nil
            snapshot.historyPersisted = historyPersisted
            snapshot.hasRecoverableAudio = false
            snapshot.recoveryAction = nil
            snapshot.elapsedDuration = max(0, elapsedDuration)
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return .rejected }
            return .publishedBatch
        } ?? .rejected
    }

    /// Once the live draft owns insertion, a failed refinement is no longer a
    /// recoverable delivery failure. Retire only the audio/recovery metadata;
    /// keep the insertion phase and transcript untouched so an in-flight
    /// keyboard confirmation remains exactly-once.
    @discardableResult
    func settleRealtimeDeliveryAfterBatchFailure(
        sessionID: UUID,
        elapsedDuration: TimeInterval
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                snapshot.deliverySource == .realtimeDraft,
                [
                    SharedDictationPhase.completed,
                    .inserting,
                    .deliveryBlocked,
                    .inserted,
                    .handled,
                ].contains(snapshot.phase)
            else {
                return false
            }
            snapshot.historyPersisted = false
            snapshot.hasRecoverableAudio = false
            snapshot.elapsedDuration = max(0, elapsedDuration)
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            return true
        }
    }

    func setReturnApplicationIdentity(
        bundleIdentifier: String,
        processIdentifier: Int32?,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.returnBundleIdentifier = bundleIdentifier
            snapshot.returnProcessIdentifier = processIdentifier
        }
    }

    func setIncomingURLContext(
        deliveryRoute: String,
        sourceApplication: String?,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.incomingURLDeliveryRoute = deliveryRoute
            snapshot.incomingURLSourceApplication = sourceApplication ?? "<nil>"
        }
    }

    func setLaunchDiagnostics(
        _ attempts: [String],
        successfulRoute: String?,
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.launchAttempts = attempts
            snapshot.successfulLaunchRoute = successfulRoute
        }
    }

    func setHostResolutionDiagnostics(
        _ attempts: [String],
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.hostResolutionAttempts = attempts
        }
    }

    func setReturnDiagnostics(
        _ attempts: [String],
        sessionID: UUID
    ) {
        update(sessionID: sessionID) { snapshot in
            snapshot.returnAttempts = attempts
        }
    }

    /// Refresh `updatedAt` without changing anything else. The containing app
    /// owns every active phase, so a session that stops being touched is one
    /// whose process is gone.
    func touch(sessionID: UUID) {
        update(sessionID: sessionID) { _ in }
    }

    @discardableResult
    func send(_ command: SharedDictationCommand, sessionID: UUID) -> Bool {
        update(sessionID: sessionID) { snapshot in
            snapshot.command = command
            snapshot.commandSequence = (snapshot.commandSequence ?? 0) + 1
        }
    }

    /// Reserve the microphone for a foreground recording without creating a
    /// keyboard-delivery session. The lease expires if its owner stops
    /// heartbeating, so a force-quit cannot block dictation forever.
    @discardableResult
    func acquireCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard
                [.idle, .inserted, .handled, .cancelled]
                    .contains(snapshot.phase),
                !hasLiveCaptureLease(snapshot)
                    || snapshot.captureOwnerID == ownerID
            else {
                return false
            }
            snapshot.captureOwnerID = ownerID
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    func renewCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.captureOwnerID == ownerID else { return false }
            snapshot.captureLeaseUpdatedAt = Date()
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    func releaseCaptureLease(ownerID: UUID) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.captureOwnerID == ownerID else { return false }
            snapshot.captureOwnerID = nil
            snapshot.captureLeaseUpdatedAt = nil
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    /// An App Intent starts outside the extension process. An active control
    /// surface can attach privacy-safe cursor evidence before, during, or
    /// immediately after transcription. Stop replaces an earlier observation
    /// synchronously, but the live document proxy remains the delivery target.
    @discardableResult
    func claimInsertionContext(
        sessionID: UUID,
        fingerprint: String,
        replacingExistingClaim: Bool = false
    ) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                snapshot.phase.allowsKeyboardInsertionContextClaim,
                snapshot.insertionContextFingerprint == nil
                    || replacingExistingClaim
            else {
                return false
            }
            snapshot.insertionContextFingerprint = fingerprint
            return true
        }
    }

    /// Atomically consumes a keyboard command. Polling the same snapshot twice
    /// cannot trigger two retries, and a heartbeat can no longer overwrite a
    /// command written between its read and write.
    func takePendingCommand(
        sessionID: UUID,
        accepting allowedCommands: Set<SharedDictationCommand>
    ) -> SharedDictationCommand {
        withStateLock {
            var snapshot = loadUnlocked()
            guard
                snapshot.sessionID == sessionID,
                snapshot.command != .none,
                allowedCommands.contains(snapshot.command)
            else {
                return .none
            }

            let command = snapshot.command
            snapshot.command = .none
            snapshot.acknowledgedCommandSequence = snapshot.commandSequence
            advanceRevision(&snapshot)
            guard saveUnlocked(snapshot) else { return .none }
            return command
        } ?? .none
    }

    /// Persist the insertion boundary before mutating the host document. A
    /// crash after this point becomes an explicit recovery choice instead of
    /// silently replaying text into the field.
    @discardableResult
    func markInsertionStarted(sessionID: UUID) -> Bool {
        updateIf(sessionID: sessionID) { snapshot in
            guard
                snapshot.phase == .completed,
                snapshot.transcript?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
            else {
                return false
            }
            snapshot.phase = .inserting
            snapshot.command = .none
            snapshot.realtimeDraftSendable = false
            if snapshot.deliverySource == nil {
                snapshot.deliverySource = .batch
            }
            snapshot.errorMessage = "Dictation Button may already have inserted this dictation. Review the field before inserting again."
            snapshot.recoveryAction = .reviewPossibleInsertion
            return true
        }
    }

    func blockDelivery(sessionID: UUID, message: String) {
        update(sessionID: sessionID) { snapshot in
            guard snapshot.phase == .completed else { return }
            snapshot.phase = .deliveryBlocked
            snapshot.command = .none
            snapshot.errorMessage = message
            snapshot.recoveryAction = .insertHere
        }
    }

    /// Explicit recovery for a durable transcript from an older build, or after
    /// an uncertain prior insertion. It deliberately returns to `completed`;
    /// the caller immediately records `inserting` again before touching the
    /// document proxy.
    func allowExplicitInsertion(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            guard [.deliveryBlocked, .inserting].contains(snapshot.phase) else {
                return
            }
            snapshot.phase = .completed
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
            snapshot.hasRecoverableAudio = nil
        }
    }

    func markInserted(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.phase = .inserted
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.realtimeTranscript = nil
            snapshot.realtimeDraftSendable = false
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
            snapshot.hasRecoverableAudio = nil
        }
    }

    /// A History copy/open/delete is an explicit fallback delivery when the
    /// keyboard cannot insert (for example, in a secure field).
    func markHandled(sessionID: UUID) {
        update(sessionID: sessionID) { snapshot in
            snapshot.phase = .handled
            snapshot.command = .none
            snapshot.transcript = nil
            snapshot.realtimeTranscript = nil
            snapshot.realtimeDraftSendable = false
            snapshot.errorMessage = nil
            snapshot.recoveryAction = nil
        }
    }

    @discardableResult
    func reset(sessionID: UUID) -> Bool {
        withStateLock {
            let current = loadUnlocked()
            guard current.sessionID == sessionID else { return false }
            var idle = SharedDictationSnapshot.idle
            idle.revision = (current.revision ?? 0) + 1
            return saveUnlocked(idle)
        } ?? false
    }

    /// Clears only a failed setup attempt that cannot contain user audio and
    /// no longer owns the recorder. This lets an updated or relaunched app
    /// repair stale launch state without racing a late, still-live launch or
    /// discarding a recoverable recording.
    @discardableResult
    func resetNonrecoverableFailure(sessionID: UUID) -> Bool {
        withStateLock {
            let current = loadUnlocked()
            guard
                current.sessionID == sessionID,
                current.phase == .failed,
                current.hasRecoverableAudio != true,
                !hasLiveCaptureLease(current)
            else {
                return false
            }
            var idle = SharedDictationSnapshot.idle
            idle.revision = (current.revision ?? 0) + 1
            return saveUnlocked(idle)
        } ?? false
    }

    @discardableResult
    private func update(
        sessionID: UUID,
        mutation: (inout SharedDictationSnapshot) -> Void
    ) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID else { return false }
            mutation(&snapshot)
            if snapshot.captureOwnerID == sessionID {
                if snapshot.phase.retainsSessionCaptureLease {
                    snapshot.captureLeaseUpdatedAt = Date()
                } else {
                    snapshot.captureOwnerID = nil
                    snapshot.captureLeaseUpdatedAt = nil
                }
            }
            advanceRevision(&snapshot)
            return saveUnlocked(snapshot)
        } ?? false
    }

    @discardableResult
    private func updateIf(
        sessionID: UUID,
        mirrorsDiagnostics: Bool = true,
        mutation: (inout SharedDictationSnapshot) -> Bool
    ) -> Bool {
        withStateLock {
            var snapshot = loadUnlocked()
            guard snapshot.sessionID == sessionID, mutation(&snapshot) else {
                return false
            }
            if snapshot.captureOwnerID == sessionID {
                if snapshot.phase.retainsSessionCaptureLease {
                    snapshot.captureLeaseUpdatedAt = Date()
                } else {
                    snapshot.captureOwnerID = nil
                    snapshot.captureLeaseUpdatedAt = nil
                }
            }
            advanceRevision(&snapshot)
            return saveUnlocked(
                snapshot,
                mirrorsDiagnostics: mirrorsDiagnostics
            )
        } ?? false
    }

    private func loadUnlocked() -> SharedDictationSnapshot {
        // The JSON file plus flock is the source of truth in production. The
        // defaults value remains a migration/fallback path for older installs
        // and isolated unit-test suites.
        if
            let stateURL,
            let data = try? Data(contentsOf: stateURL),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        {
            // Once the locked app-group file exists it is authoritative. The
            // defaults mirror is written second and may legitimately lag if a
            // process dies between the two writes.
            return snapshot
        }

        defaults?.synchronize()
        guard
            let data = defaults?.data(
                forKey: SharedDictationConstants.storageKey
            ),
            let snapshot = try? JSONDecoder().decode(
                SharedDictationSnapshot.self,
                from: data
            )
        else {
            return .idle
        }
        return snapshot
    }

    @discardableResult
    private func saveUnlocked(
        _ snapshot: SharedDictationSnapshot,
        mirrorsDiagnostics: Bool = true
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return false
        }
        if let stateURL {
            do {
                try FileManager.default.createDirectory(
                    at: stateURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: stateURL, options: [.atomic])
            } catch {
                return false
            }
        } else {
            guard defaults != nil else { return false }
        }
        defaults?.set(data, forKey: SharedDictationConstants.storageKey)
        // Ensure Stop/Cancel is visible immediately to a background recorder.
        defaults?.synchronize()
        if mirrorsDiagnostics {
            mirrorDiagnostics(snapshot)
        }
        return true
    }

    private var stateURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateFileName,
            isDirectory: false
        )
    }

    private var lockURL: URL? {
        storageDirectory?.appendingPathComponent(
            SharedDictationConstants.stateLockFileName,
            isDirectory: false
        )
    }

    private func advanceRevision(_ snapshot: inout SharedDictationSnapshot) {
        snapshot.revision = (snapshot.revision ?? 0) + 1
        snapshot.updatedAt = Date()
    }

    private func hasLiveCaptureLease(
        _ snapshot: SharedDictationSnapshot,
        now: Date = Date()
    ) -> Bool {
        guard
            snapshot.captureOwnerID != nil,
            let updatedAt = snapshot.captureLeaseUpdatedAt
        else {
            return false
        }
        return now.timeIntervalSince(updatedAt) < 15
    }

    private func withStateLock<T>(_ operation: () -> T) -> T? {
        guard let lockURL else { return operation() }
        do {
            try FileManager.default.createDirectory(
                at: lockURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return nil
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_EXLOCK,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return nil }
        // `O_EXLOCK` acquires the advisory lock atomically with open; closing
        // the descriptor releases it on every Darwin platform.
        defer { Darwin.close(descriptor) }
        return operation()
    }

    private func mirrorDiagnostics(_ snapshot: SharedDictationSnapshot) {
        guard
            let directory = FileManager.default.urls(
                for: .documentDirectory,
                in: .userDomainMask
            ).first
        else {
            return
        }

        var mirrored = snapshot
        // The mirror exists to explain routes, never to keep dictated content
        // in cleartext outside the session.
        mirrored.transcript = snapshot.transcript.map { "<\($0.count) characters>" }
        mirrored.realtimeTranscript = snapshot.realtimeTranscript.map {
            "<\($0.count) characters>"
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(mirrored) else { return }
        try? data.write(
            to: directory.appendingPathComponent(
                SharedDictationConstants.diagnosticsFileName
            ),
            options: .atomic
        )

        // A reset overwrites the latest snapshot, which is exactly when the
        // preceding failure diagnostics matter most. Keep a bounded history so
        // a session can be reconstructed after it ends.
        appendToHistory(mirrored, in: directory)
    }

    private func appendToHistory(
        _ snapshot: SharedDictationSnapshot,
        in directory: URL
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard
            let line = try? encoder.encode(snapshot),
            var text = String(data: line, encoding: .utf8)
        else {
            return
        }
        text += "\n"

        let url = directory.appendingPathComponent(
            SharedDictationConstants.diagnosticsHistoryFileName
        )
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        existing += text
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 400 {
            existing = lines.suffix(400).joined(separator: "\n") + "\n"
        }
        try? existing.write(to: url, atomically: true, encoding: .utf8)
    }
}
