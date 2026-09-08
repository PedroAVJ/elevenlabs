import Foundation

/// Extension-written proof that the bundled keyboard has actually appeared. iOS
/// does not expose a dependable containing-app API for enumerating enabled
/// third-party keyboards, so the extension reports its own real state through
/// the App Group instead of asking the user to confirm a setup checklist.
struct KeyboardSetupStatus: Codable, Equatable, Sendable {
    let hasFullAccess: Bool
    let observedAt: Date
}

struct KeyboardSetupResolution: Equatable, Sendable {
    let wasDetected: Bool
    let hasFullAccess: Bool
}

/// `UITextDocumentProxy.insertText` has no success return value. Keep the
/// shared transcript pending unless the live proxy reports either its document
/// callback or the expected suffix at the cursor after the mutation.
enum KeyboardInsertionAcknowledgementPolicy {
    static func confirmsMutation(
        insertedText: String,
        contextBeforeMutation: String?,
        contextAfterMutation: String?,
        documentChangeObserved: Bool
    ) -> Bool {
        if documentChangeObserved {
            return true
        }

        let probe = String(insertedText.suffix(32))
        guard
            !probe.isEmpty,
            contextAfterMutation != contextBeforeMutation
        else {
            return false
        }
        return contextAfterMutation?.hasSuffix(probe) == true
    }
}

struct KeyboardInsertionResult: Equatable, Sendable {
    let confirmed: Bool
    let documentIdentifierBefore: String
    let documentIdentifierAfter: String
    let contextBeforeMutation: String?
    let contextAfterMutation: String?
    let documentChangeObserved: Bool
}

enum KeyboardInsertionTelemetryOutcome: String, Codable, Equatable, Sendable {
    case attempting
    case confirmed
    case unconfirmed
}

struct KeyboardInsertionTelemetryRecord: Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let outcome: KeyboardInsertionTelemetryOutcome
    let transcript: String
    var deliverySource: SharedDictationDeliverySource? = nil
    let returnBundleIdentifier: String?
    let startedAt: Date
    let finishedAt: Date?
    let documentIdentifierBefore: String?
    let documentIdentifierAfter: String?
    let contextBeforeMutation: String?
    let contextAfterMutation: String?
    let documentChangeObserved: Bool?

    var reportSignature: String {
        "\(id.uuidString):\(outcome.rawValue)"
    }

    var latencyMs: Int? {
        guard let finishedAt else { return nil }
        return Int(
            (max(0, finishedAt.timeIntervalSince(startedAt)) * 1_000)
                .rounded()
        )
    }
}

/// The extension records the complete insertion trace in the App Group. The
/// containing app forwards it through the configured Sentry client on its next
/// activation, which keeps one correlation chain across two iOS processes.
struct KeyboardInsertionTelemetryStore: @unchecked Sendable {
    static let storageKey = "keyboard-insertion-telemetry-v1"
    static let reportedSignatureKey =
        "keyboard-insertion-telemetry-reported-signature-v1"

    private let defaults: UserDefaults?
    private let storageKey: String
    private let reportedSignatureKey: String

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageKey: String = Self.storageKey,
        reportedSignatureKey: String = Self.reportedSignatureKey
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        self.storageKey = storageKey
        self.reportedSignatureKey = reportedSignatureKey
    }

    @discardableResult
    func begin(
        sessionID: UUID,
        transcript: String,
        returnBundleIdentifier: String?,
        deliverySource: SharedDictationDeliverySource? = nil,
        now: Date = Date()
    ) -> UUID {
        let id = UUID()
        save(
            KeyboardInsertionTelemetryRecord(
                id: id,
                sessionID: sessionID,
                outcome: .attempting,
                transcript: transcript,
                deliverySource: deliverySource,
                returnBundleIdentifier: returnBundleIdentifier,
                startedAt: now,
                finishedAt: nil,
                documentIdentifierBefore: nil,
                documentIdentifierAfter: nil,
                contextBeforeMutation: nil,
                contextAfterMutation: nil,
                documentChangeObserved: nil
            )
        )
        return id
    }

    func finish(
        id: UUID,
        result: KeyboardInsertionResult,
        now: Date = Date()
    ) {
        guard let current = load(), current.id == id else { return }
        save(
            KeyboardInsertionTelemetryRecord(
                id: current.id,
                sessionID: current.sessionID,
                outcome: result.confirmed ? .confirmed : .unconfirmed,
                transcript: current.transcript,
                deliverySource: current.deliverySource,
                returnBundleIdentifier: current.returnBundleIdentifier,
                startedAt: current.startedAt,
                finishedAt: now,
                documentIdentifierBefore: result.documentIdentifierBefore,
                documentIdentifierAfter: result.documentIdentifierAfter,
                contextBeforeMutation: result.contextBeforeMutation,
                contextAfterMutation: result.contextAfterMutation,
                documentChangeObserved: result.documentChangeObserved
            )
        )
    }

    func pendingForReporting() -> KeyboardInsertionTelemetryRecord? {
        guard
            let record = load(),
            defaults?.string(forKey: reportedSignatureKey)
                != record.reportSignature
        else {
            return nil
        }
        return record
    }

    func markReported(_ record: KeyboardInsertionTelemetryRecord) {
        defaults?.set(record.reportSignature, forKey: reportedSignatureKey)
        _ = defaults?.synchronize()
    }

    func load() -> KeyboardInsertionTelemetryRecord? {
        guard
            let data = defaults?.data(forKey: storageKey),
            let record = try? JSONDecoder().decode(
                KeyboardInsertionTelemetryRecord.self,
                from: data
            )
        else {
            return nil
        }
        return record
    }

    private func save(_ record: KeyboardInsertionTelemetryRecord) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults?.set(data, forKey: storageKey)
        _ = defaults?.synchronize()
    }
}

struct KeyboardSetupStatusStore: @unchecked Sendable {
    static let storageKey = "keyboard-setup-status-v1"

    private let defaults: UserDefaults?
    private let storageKey: String
    private let legacyEvidenceKeys: [String]

    init(
        suiteName: String = SharedDictationConstants.appGroupIdentifier,
        storageKey: String = Self.storageKey,
        legacyEvidenceKeys: [String] = [
            SharedDictationConstants.hostApplicationIdentityKey,
            SharedDictationConstants.visibleHostApplicationLeaseKey,
        ]
    ) {
        defaults = UserDefaults(suiteName: suiteName)
        self.storageKey = storageKey
        self.legacyEvidenceKeys = legacyEvidenceKeys
    }

    func record(hasFullAccess: Bool, now: Date = Date()) {
        let status = KeyboardSetupStatus(
            hasFullAccess: hasFullAccess,
            observedAt: now
        )
        guard let data = try? JSONEncoder().encode(status) else { return }
        defaults?.set(data, forKey: storageKey)
        // The containing app can become active immediately after the keyboard
        // disappears. Flush this tiny signal so its first snapshot sees it.
        _ = defaults?.synchronize()
    }

    func load() -> KeyboardSetupStatus? {
        guard
            let data = defaults?.data(forKey: storageKey),
            let status = try? JSONDecoder().decode(
                KeyboardSetupStatus.self,
                from: data
            )
        else {
            return nil
        }
        return status
    }

    func resolution() -> KeyboardSetupResolution {
        if let status = load() {
            return KeyboardSetupResolution(
                wasDetected: true,
                hasFullAccess: status.hasFullAccess
            )
        }

        // Builds before this status existed already left extension evidence
        // only when the keyboard extension had appeared in a real host. Treat
        // that as a one-time migration so existing users do not see setup again.
        let hasLegacyEvidence = legacyEvidenceKeys.contains {
            defaults?.object(forKey: $0) != nil
        }
        return KeyboardSetupResolution(
            wasDetected: hasLegacyEvidence,
            hasFullAccess: hasLegacyEvidence
        )
    }
}
