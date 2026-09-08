import Foundation

/// A deliberately small description of the previous app run.
///
/// `endedWithoutCleanTermination` is `nil` when there was no previous marker or
/// its marker was unreadable. Callers can therefore distinguish a proven crash
/// or force-quit from missing evidence instead of silently treating both alike.
struct MacPreviousSessionHealth: Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case noPreviousSession
        case clean
        case unclean
        case unreadable
    }

    let status: Status
    let startedAt: Date?
    let lastHeartbeatAt: Date?
    let cleanTerminationAt: Date?

    var endedWithoutCleanTermination: Bool? {
        switch status {
        case .clean:
            false
        case .unclean:
            true
        case .noPreviousSession, .unreadable:
            nil
        }
    }
}

enum MacSessionHealthMarkerError: Error, Equatable, LocalizedError {
    case applicationSupportUnavailable
    case sessionAlreadyActive
    case noActiveSession
    case markerUnreadable

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "Application Support is unavailable."
        case .sessionAlreadyActive:
            "A session is already active."
        case .noActiveSession:
            "There is no active session to update."
        case .markerUnreadable:
            "The active session marker is unreadable."
        }
    }
}

/// A crash- and force-quit detector backed by one atomic local marker.
///
/// Call `beginSession()` once during launch, `recordHeartbeat()` periodically,
/// and `markCleanTermination()` from the normal termination path. A running
/// marker left behind on the next launch proves the previous run did not reach
/// that clean path. The marker stores dates and a schema version only: never
/// transcript text, API-key state, audio, destinations, or device identifiers.
final class MacSessionHealthMarker {
    typealias Clock = () -> Date

    private let fileURL: URL?
    private let clock: Clock
    private let lock = NSLock()
    private var hasActiveSession = false

    /// `applicationSupportDirectory` is the app-specific container. Passing a
    /// scratch directory and a deterministic clock keeps lifecycle tests away
    /// from the user's real Application Support folder and wall clock.
    init(
        applicationSupportDirectory: URL? = nil,
        clock: @escaping Clock = { Date() },
        fileManager: FileManager = .default
    ) {
        self.clock = clock

        let directory = applicationSupportDirectory
            ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)
        fileURL = directory?.appending(
            path: "session-health.json",
            directoryHint: .notDirectory
        )
    }

    /// Starts this run and atomically replaces the prior marker.
    ///
    /// The returned value describes the marker that existed before this call.
    /// Even an unreadable prior marker is replaced, so one damaged file does
    /// not permanently disable health tracking for all later launches.
    @discardableResult
    func beginSession() throws -> MacPreviousSessionHealth {
        try withLock {
            guard !hasActiveSession else {
                throw MacSessionHealthMarkerError.sessionAlreadyActive
            }
            guard let fileURL else {
                throw MacSessionHealthMarkerError.applicationSupportUnavailable
            }

            let previous = Self.previousHealth(from: Self.loadMarker(from: fileURL))
            let now = clock()
            let marker = StoredSessionHealth(
                schemaVersion: 1,
                startedAt: now,
                lastHeartbeatAt: now,
                cleanTerminationAt: nil
            )
            try Self.writeMarker(marker, to: fileURL)
            hasActiveSession = true
            return previous
        }
    }

    /// Refreshes only the current run's liveness timestamp.
    func recordHeartbeat() throws {
        try withLock {
            guard hasActiveSession else {
                throw MacSessionHealthMarkerError.noActiveSession
            }
            guard let fileURL else {
                throw MacSessionHealthMarkerError.applicationSupportUnavailable
            }
            guard case let .record(marker) = Self.loadMarker(from: fileURL) else {
                throw MacSessionHealthMarkerError.markerUnreadable
            }
            guard marker.cleanTerminationAt == nil else {
                throw MacSessionHealthMarkerError.noActiveSession
            }

            let updated = StoredSessionHealth(
                schemaVersion: marker.schemaVersion,
                startedAt: marker.startedAt,
                lastHeartbeatAt: clock(),
                cleanTerminationAt: nil
            )
            try Self.writeMarker(updated, to: fileURL)
        }
    }

    /// Marks this run clean while retaining its start and last heartbeat.
    func markCleanTermination() throws {
        try withLock {
            guard hasActiveSession else {
                throw MacSessionHealthMarkerError.noActiveSession
            }
            guard let fileURL else {
                throw MacSessionHealthMarkerError.applicationSupportUnavailable
            }
            guard case let .record(marker) = Self.loadMarker(from: fileURL) else {
                throw MacSessionHealthMarkerError.markerUnreadable
            }
            guard marker.cleanTerminationAt == nil else {
                hasActiveSession = false
                throw MacSessionHealthMarkerError.noActiveSession
            }

            let updated = StoredSessionHealth(
                schemaVersion: marker.schemaVersion,
                startedAt: marker.startedAt,
                lastHeartbeatAt: marker.lastHeartbeatAt,
                cleanTerminationAt: clock()
            )
            try Self.writeMarker(updated, to: fileURL)
            hasActiveSession = false
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func previousHealth(from loaded: LoadedSessionHealth) -> MacPreviousSessionHealth {
        switch loaded {
        case .missing:
            MacPreviousSessionHealth(
                status: .noPreviousSession,
                startedAt: nil,
                lastHeartbeatAt: nil,
                cleanTerminationAt: nil
            )
        case .unreadable:
            MacPreviousSessionHealth(
                status: .unreadable,
                startedAt: nil,
                lastHeartbeatAt: nil,
                cleanTerminationAt: nil
            )
        case let .record(marker):
            MacPreviousSessionHealth(
                status: marker.cleanTerminationAt == nil ? .unclean : .clean,
                startedAt: marker.startedAt,
                lastHeartbeatAt: marker.lastHeartbeatAt,
                cleanTerminationAt: marker.cleanTerminationAt
            )
        }
    }

    private static func loadMarker(from fileURL: URL) -> LoadedSessionHealth {
        let data: Data
        do {
            guard let loaded = try MacPrivateStoreIO.readExistingData(at: fileURL) else {
                return .missing
            }
            data = loaded
        } catch {
            return .unreadable
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let marker = try? decoder.decode(StoredSessionHealth.self, from: data) else {
            return .unreadable
        }
        return .record(marker)
    }

    private static func writeMarker(
        _ marker: StoredSessionHealth,
        to fileURL: URL
    ) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)
        try MacPrivateStoreIO.writeAtomically(data, to: fileURL)
    }

    private static func defaultApplicationSupportDirectory(
        fileManager: FileManager
    ) -> URL? {
        guard
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return support.appending(path: "ElevenLabs", directoryHint: .isDirectory)
    }
}

private struct StoredSessionHealth: Codable {
    let schemaVersion: Int
    let startedAt: Date
    let lastHeartbeatAt: Date
    let cleanTerminationAt: Date?
}

private enum LoadedSessionHealth {
    case missing
    case record(StoredSessionHealth)
    case unreadable
}

/// A privacy-safe reading of the Mic Mode macOS applied while audio was
/// actually flowing. The system owns Mic Mode selection; ElevenLabs only
/// observes the user's preference and the active route result.
struct MacMicrophoneModeObservation: Codable, Equatable, Sendable {
    enum Source: String, Codable, Equatable, Sendable {
        case continuity
        case microphone

        var title: String {
            switch self {
            case .continuity: "iPhone Continuity microphone"
            case .microphone: "Mac microphone"
            }
        }
    }

    enum Mode: String, Codable, Equatable, Sendable {
        case standard
        case wideSpectrum
        case voiceIsolation
        case unknown

        var title: String {
            switch self {
            case .standard: "Standard"
            case .wideSpectrum: "Wide Spectrum"
            case .voiceIsolation: "Voice Isolation"
            case .unknown: "Unknown"
            }
        }
    }

    let observedAt: Date
    let source: Source
    let preferred: Mode
    let active: Mode

    var voiceIsolationIsActive: Bool { active == .voiceIsolation }

    var preferredModeIsActive: Bool { preferred == active }

    var resultTitle: String {
        if voiceIsolationIsActive {
            return "Voice Isolation active on the \(source.title)"
        }
        if preferred == .voiceIsolation {
            return "Voice Isolation selected, but \(active.title) is active"
        }
        return "\(active.title) active on the \(source.title)"
    }

    var detailText: String {
        "Selected \(preferred.title) · Active \(active.title) · observed during live audio"
    }
}

/// A bounded, privacy-safe runtime trail of the Mic Mode values macOS reported
/// while audio was flowing. Keeping this in Application Support makes physical
/// iPhone tests inspectable without requiring the ElevenLabs window to remain
/// open or asking the person running the test to interpret the result.
final class MacMicrophoneModeObservationStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let observations: [MacMicrophoneModeObservation]
    }

    private let fileURL: URL?
    private let maximumObservations: Int
    private let lock = NSLock()

    init(
        applicationSupportDirectory: URL? = nil,
        maximumObservations: Int = 50,
        fileManager: FileManager = .default
    ) {
        let directory = applicationSupportDirectory
            ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)
        fileURL = directory?.appending(
            path: "microphone-mode-observations.json",
            directoryHint: .notDirectory
        )
        self.maximumObservations = max(1, maximumObservations)
    }

    func load() -> [MacMicrophoneModeObservation] {
        withLock { Self.loadDocument(from: fileURL)?.observations ?? [] }
    }

    @discardableResult
    func append(
        _ observation: MacMicrophoneModeObservation
    ) throws -> [MacMicrophoneModeObservation] {
        try withLock {
            guard let fileURL else {
                throw MacSessionHealthMarkerError.applicationSupportUnavailable
            }
            let existing = Self.loadDocument(from: fileURL)?.observations ?? []
            let observations = Array(([observation] + existing).prefix(maximumObservations))
            let document = Document(schemaVersion: 1, observations: observations)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try MacPrivateStoreIO.writeAtomically(try encoder.encode(document), to: fileURL)
            return observations
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func loadDocument(from fileURL: URL?) -> Document? {
        guard let data = try? MacPrivateStoreIO.readExistingData(at: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Document.self, from: data)
    }

    private static func defaultApplicationSupportDirectory(
        fileManager: FileManager
    ) -> URL? {
        guard
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return support.appending(path: "ElevenLabs", directoryHint: .isDirectory)
    }
}

/// Privacy-safe evidence from the standalone Continuity route probe. The
/// probe's temporary recording is deleted before this value is persisted, and
/// this allow-list cannot carry a device ID, device name, file path, or audio.
struct MacVoiceIsolationProbeResult: Codable, Equatable, Sendable {
    enum Route: String, Codable, Equatable, Sendable {
        case singleDataOutputAssetWriter

        var title: String { "Single-output iPhone route" }
    }

    enum Status: String, Codable, Equatable, Sendable {
        case voiceIsolationActive
        case selectedButInactive
        case notSelected
        case noSamples
        case fileInvalid
        case failed
        case cancelled
    }

    enum FailureDomain: String, Codable, Equatable, Sendable {
        case probe
        case avFoundation
        case osStatus
        case cocoa
        case unknown
    }

    let startedAt: Date
    let completedAt: Date
    let route: Route
    let status: Status
    let preferredMode: MacMicrophoneModeObservation.Mode
    let activeMode: MacMicrophoneModeObservation.Mode
    let sampleBufferCount: UInt64
    let peakLevel: Double
    let playableDurationSeconds: TimeInterval?
    let fileByteCount: Int64
    let releaseConfirmed: Bool
    let failureDomain: FailureDomain?
    let failureCode: Int?

    init(
        startedAt: Date,
        completedAt: Date,
        route: Route = .singleDataOutputAssetWriter,
        status: Status,
        preferredMode: MacMicrophoneModeObservation.Mode,
        activeMode: MacMicrophoneModeObservation.Mode,
        sampleBufferCount: UInt64,
        peakLevel: Double,
        playableDurationSeconds: TimeInterval?,
        fileByteCount: Int64,
        releaseConfirmed: Bool,
        failureDomain: FailureDomain? = nil,
        failureCode: Int? = nil
    ) {
        self.startedAt = startedAt
        self.completedAt = max(completedAt, startedAt)
        self.route = route
        self.status = status
        self.preferredMode = preferredMode
        self.activeMode = activeMode
        self.sampleBufferCount = sampleBufferCount
        self.peakLevel = peakLevel.isFinite ? min(max(peakLevel, 0), 1) : 0
        if let playableDurationSeconds, playableDurationSeconds.isFinite {
            self.playableDurationSeconds = max(0, playableDurationSeconds)
        } else {
            self.playableDurationSeconds = nil
        }
        self.fileByteCount = max(0, fileByteCount)
        self.releaseConfirmed = releaseConfirmed
        self.failureDomain = failureDomain
        self.failureCode = failureCode
    }

    var resultTitle: String {
        switch status {
        case .voiceIsolationActive:
            "Confirmed: Voice Isolation is active on the probe route."
        case .selectedButInactive:
            "Voice Isolation was selected, but macOS kept \(activeMode.title) active."
        case .notSelected:
            "The route recorded audio, but Voice Isolation was not selected."
        case .noSamples:
            "The iPhone route connected but delivered no audio."
        case .fileInvalid:
            "Audio arrived, but the probe could not finalize a playable file."
        case .failed:
            "The iPhone route probe failed before it could confirm the mode."
        case .cancelled:
            "The iPhone route probe was cancelled."
        }
    }

    var detailText: String {
        let duration = playableDurationSeconds.map {
            String(format: "%.1f s playable", $0)
        } ?? "no playable file"
        let release = releaseConfirmed ? "yes" : "no"
        return "Selected \(preferredMode.title) · Active \(activeMode.title) · \(sampleBufferCount) buffers · peak \(Int((peakLevel * 100).rounded()))% · \(duration) · iPhone released \(release)"
    }
}

/// Bounded local probe history so Codex can inspect a physical test after the
/// Settings window closes. Only `MacVoiceIsolationProbeResult` is encodable.
final class MacVoiceIsolationProbeResultStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let results: [MacVoiceIsolationProbeResult]
    }

    private let fileURL: URL?
    private let maximumResults: Int
    private let lock = NSLock()

    init(
        applicationSupportDirectory: URL? = nil,
        maximumResults: Int = 20,
        fileManager: FileManager = .default
    ) {
        let directory = applicationSupportDirectory
            ?? Self.defaultApplicationSupportDirectory(fileManager: fileManager)
        fileURL = directory?.appending(
            path: "voice-isolation-probe-results.json",
            directoryHint: .notDirectory
        )
        self.maximumResults = max(1, maximumResults)
    }

    func load() -> [MacVoiceIsolationProbeResult] {
        withLock { Self.loadDocument(from: fileURL)?.results ?? [] }
    }

    @discardableResult
    func append(
        _ result: MacVoiceIsolationProbeResult
    ) throws -> [MacVoiceIsolationProbeResult] {
        try withLock {
            guard let fileURL else {
                throw MacSessionHealthMarkerError.applicationSupportUnavailable
            }
            let existing = Self.loadDocument(from: fileURL)?.results ?? []
            let results = Array(([result] + existing).prefix(maximumResults))
            let document = Document(schemaVersion: 1, results: results)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try MacPrivateStoreIO.writeAtomically(try encoder.encode(document), to: fileURL)
            return results
        }
    }

    private func withLock<Result>(_ operation: () throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private static func loadDocument(from fileURL: URL?) -> Document? {
        guard let data = try? MacPrivateStoreIO.readExistingData(at: fileURL) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Document.self, from: data)
    }

    private static func defaultApplicationSupportDirectory(
        fileManager: FileManager
    ) -> URL? {
        guard
            let support = try? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        else {
            return nil
        }
        return support.appending(path: "ElevenLabs", directoryHint: .isDirectory)
    }
}

/// The complete allow-list for an exported support snapshot.
///
/// This type intentionally cannot carry transcript bodies, recorded audio or
/// file paths, clipboard contents, accessibility-field text, device IDs,
/// credentials, API responses, or free-form failure details. Diagnostics are
/// assembled into these safe scalar fields rather than by encoding app state.
struct MacDiagnosticsSnapshot: Codable, Equatable, Sendable {
    struct App: Codable, Equatable, Sendable {
        let name: String
        let version: String
        let build: String
    }

    struct MacOS: Codable, Equatable, Sendable {
        let version: String
        let build: String?
    }

    struct Permissions: Codable, Equatable, Sendable {
        let microphone: Bool
        let accessibility: Bool
        let inputMonitoring: Bool
        let keyboardOutput: Bool
        let launchAtLogin: Bool

        init(
            microphone: Bool,
            accessibility: Bool,
            inputMonitoring: Bool,
            keyboardOutput: Bool = false,
            launchAtLogin: Bool
        ) {
            self.microphone = microphone
            self.accessibility = accessibility
            self.inputMonitoring = inputMonitoring
            self.keyboardOutput = keyboardOutput
            self.launchAtLogin = launchAtLogin
        }

        private enum CodingKeys: String, CodingKey {
            case microphone, accessibility, inputMonitoring, keyboardOutput, launchAtLogin
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                microphone: try container.decode(Bool.self, forKey: .microphone),
                accessibility: try container.decode(Bool.self, forKey: .accessibility),
                inputMonitoring: try container.decode(Bool.self, forKey: .inputMonitoring),
                keyboardOutput: try container.decodeIfPresent(Bool.self, forKey: .keyboardOutput) ?? false,
                launchAtLogin: try container.decode(Bool.self, forKey: .launchAtLogin)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(microphone, forKey: .microphone)
            try container.encode(accessibility, forKey: .accessibility)
            try container.encode(inputMonitoring, forKey: .inputMonitoring)
            try container.encode(keyboardOutput, forKey: .keyboardOutput)
            try container.encode(launchAtLogin, forKey: .launchAtLogin)
        }
    }

    struct Microphone: Codable, Equatable, Sendable {
        /// A closed transport vocabulary prevents an opaque hardware UID from
        /// accidentally being supplied in place of a human-readable category.
        enum Transport: String, Codable, Equatable, Sendable {
            case builtIn
            case continuityWired
            case continuityWireless
            case usb
            case bluetooth
            case virtual
            case aggregate
            case other
            case unknown
        }

        let transport: Transport
        /// Normalized input gain in the range 0...1, or nil when unavailable.
        let gain: Double?

        init(transport: Transport, gain: Double?) {
            self.transport = transport
            self.gain = Self.normalizedGain(gain)
        }

        private enum CodingKeys: String, CodingKey {
            // Accepted only to decode schema-1 exports. It is intentionally not
            // retained or re-encoded because device names can contain a full
            // personal name (and imported filenames used to occupy this slot).
            case name
            case transport
            case gain
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                transport: try container.decode(Transport.self, forKey: .transport),
                gain: try container.decodeIfPresent(Double.self, forKey: .gain)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(transport, forKey: .transport)
            try container.encodeIfPresent(gain, forKey: .gain)
        }

        private static func normalizedGain(_ gain: Double?) -> Double? {
            guard let gain, gain.isFinite else { return nil }
            return min(max(gain, 0), 1)
        }
    }

    struct ReliabilityAttempt: Codable, Equatable, Sendable {
        enum Outcome: String, Codable, Equatable, Sendable {
            case success
            case failure
        }

        enum Source: String, Codable, Equatable, Sendable {
            case continuity
            case microphone
            case imported
            case unknown
        }

        let occurredAt: Date
        let source: Source
        let recordingDurationSeconds: TimeInterval
        let transcriptionDurationSeconds: TimeInterval
        let outcome: Outcome

        init(
            occurredAt: Date,
            source: Source,
            recordingDurationSeconds: TimeInterval,
            transcriptionDurationSeconds: TimeInterval,
            outcome: Outcome
        ) {
            self.occurredAt = occurredAt
            self.source = source
            self.recordingDurationSeconds = recordingDurationSeconds
            self.transcriptionDurationSeconds = transcriptionDurationSeconds
            self.outcome = outcome
        }

        private enum CodingKeys: String, CodingKey {
            case occurredAt, source, microphoneName, recordingDurationSeconds
            case transcriptionDurationSeconds, outcome
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                occurredAt: try container.decode(Date.self, forKey: .occurredAt),
                source: try container.decodeIfPresent(Source.self, forKey: .source) ?? .unknown,
                recordingDurationSeconds: try container.decode(
                    TimeInterval.self,
                    forKey: .recordingDurationSeconds
                ),
                transcriptionDurationSeconds: try container.decode(
                    TimeInterval.self,
                    forKey: .transcriptionDurationSeconds
                ),
                outcome: try container.decode(Outcome.self, forKey: .outcome)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(occurredAt, forKey: .occurredAt)
            try container.encode(source, forKey: .source)
            try container.encode(recordingDurationSeconds, forKey: .recordingDurationSeconds)
            try container.encode(transcriptionDurationSeconds, forKey: .transcriptionDurationSeconds)
            try container.encode(outcome, forKey: .outcome)
        }
    }

    struct QueueCounts: Codable, Equatable, Sendable {
        let transcribingCount: Int
        let heldTranscriptCount: Int
        let retryCount: Int

        init(transcribingCount: Int, heldTranscriptCount: Int, retryCount: Int) {
            self.transcribingCount = max(0, transcribingCount)
            self.heldTranscriptCount = max(0, heldTranscriptCount)
            self.retryCount = max(0, retryCount)
        }

        private enum CodingKeys: String, CodingKey {
            case transcribingCount, heldTranscriptCount, pendingTranscriptionCount, retryCount
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                transcribingCount: try container.decodeIfPresent(
                    Int.self,
                    forKey: .transcribingCount
                ) ?? container.decodeIfPresent(
                    Int.self,
                    forKey: .pendingTranscriptionCount
                ) ?? 0,
                heldTranscriptCount: try container.decodeIfPresent(
                    Int.self,
                    forKey: .heldTranscriptCount
                ) ?? 0,
                retryCount: try container.decode(Int.self, forKey: .retryCount)
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(transcribingCount, forKey: .transcribingCount)
            try container.encode(heldTranscriptCount, forKey: .heldTranscriptCount)
            try container.encode(retryCount, forKey: .retryCount)
        }
    }

    let schemaVersion: Int
    let generatedAt: Date
    let app: App
    let macOS: MacOS
    let permissions: Permissions
    let microphones: [Microphone]
    let microphoneModeObservation: MacMicrophoneModeObservation?
    let voiceIsolationProbeResult: MacVoiceIsolationProbeResult?
    let reliabilityAttempts: [ReliabilityAttempt]
    let queueCounts: QueueCounts

    init(
        schemaVersion: Int = 3,
        generatedAt: Date,
        app: App,
        macOS: MacOS,
        permissions: Permissions,
        microphones: [Microphone],
        microphoneModeObservation: MacMicrophoneModeObservation? = nil,
        voiceIsolationProbeResult: MacVoiceIsolationProbeResult? = nil,
        reliabilityAttempts: [ReliabilityAttempt],
        queueCounts: QueueCounts
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.app = app
        self.macOS = macOS
        self.permissions = permissions
        self.microphones = microphones
        self.microphoneModeObservation = microphoneModeObservation
        self.voiceIsolationProbeResult = voiceIsolationProbeResult
        self.reliabilityAttempts = reliabilityAttempts
        self.queueCounts = queueCounts
    }
}

/// Stable, human-readable JSON generation plus an atomic file export.
enum MacDiagnosticsExporter {
    /// Pure data generation is separate from filesystem work so tests can
    /// decode or compare the exact support payload without creating a file.
    static func jsonData(for snapshot: MacDiagnosticsSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var data = try encoder.encode(snapshot)
        data.append(0x0A)
        return data
    }

    @discardableResult
    static func writeAtomically(
        _ snapshot: MacDiagnosticsSnapshot,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let data = try jsonData(for: snapshot)
        try MacAtomicFileWriter.write(data, to: fileURL, fileManager: fileManager)
        return fileURL
    }
}

/// All-or-nothing writer for the user-selected diagnostics export. Automatic
/// app-owned stores use `MacPrivateStoreIO` and its no-follow boundary instead.
enum MacAtomicFileWriter {
    static func write(
        _ data: Data,
        to fileURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try data.write(to: fileURL, options: .atomic)
    }
}
