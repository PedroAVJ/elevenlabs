import AVFoundation
import Combine
import Foundation

enum AudioDiagnosticsStoreError: Error {
    case audioMissing
    case unsafeSource
    case corruptRecord
    case playbackFailed

    var safeReason: String {
        switch self {
        case .audioMissing: "audio_missing"
        case .unsafeSource: "unsafe_source"
        case .corruptRecord: "corrupt_record"
        case .playbackFailed: "playback_failed"
        }
    }
}

struct AudioDiagnosticSource: Equatable, Sendable {
    let id: UUID
    let url: URL
}

struct AudioDiagnosticRecord: Codable, Equatable, Sendable {
    struct Segment: Codable, Equatable, Sendable {
        let id: UUID
        let fileName: String
        let byteCount: Int64
    }

    let historyID: UUID
    let createdAt: Date
    let duration: TimeInterval
    let quality: AudioCaptureQualitySummary
    let microphoneMode: AudioMicrophoneModeSnapshot
    let languageProbability: Double?
    let segments: [Segment]

    var signalLabel: String {
        switch quality.classification {
        case .noSamples: "Audio retained"
        case .mostlySilent: "Mostly silent"
        case .quiet: "Quiet capture"
        case .healthy: "Healthy level"
        case .clippingRisk: "Possible clipping"
        }
    }

    var microphoneModeLabel: String {
        switch microphoneMode.active {
        case "voice_isolation": "Voice Isolation"
        case "wide_spectrum": "Wide Spectrum"
        case "standard": "Standard"
        default: "Mic mode unknown"
        }
    }
}

/// Keeps successful source audio private and on-device so a garbled transcript
/// can be replayed and diagnosed after the recovery journal retires its copy.
/// No path or recording identifier leaves this store through observability.
@MainActor
final class AudioDiagnosticsStore: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var playingHistoryID: UUID?
    @Published private(set) var recordsByHistoryID: [UUID: AudioDiagnosticRecord] = [:]

    static let maximumStoredBytes: Int64 = 250 * 1_024 * 1_024

    let rootDirectory: URL

    private let fileManager: FileManager
    private let audioSession: AVAudioSession
    private var player: AVAudioPlayer?
    private var playbackQueue: [URL] = []

    convenience override init() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.temporaryDirectory
        self.init(
            rootDirectory: applicationSupport
                .appendingPathComponent("ElevenLabs", isDirectory: true)
                .appendingPathComponent("AudioDiagnostics", isDirectory: true),
            fileManager: fileManager,
            audioSession: .sharedInstance()
        )
    }

    init(
        rootDirectory: URL,
        fileManager: FileManager = .default,
        audioSession: AVAudioSession = .sharedInstance()
    ) {
        self.rootDirectory = rootDirectory.standardizedFileURL
        self.fileManager = fileManager
        self.audioSession = audioSession
        super.init()
        recordsByHistoryID = Dictionary(
            uniqueKeysWithValues: loadAllRecords().map { ($0.historyID, $0) }
        )
    }

    @discardableResult
    func archive(
        _ sources: [AudioDiagnosticSource],
        historyID: UUID,
        createdAt: Date,
        duration: TimeInterval,
        quality: AudioCaptureQualitySummary,
        microphoneMode: AudioMicrophoneModeSnapshot,
        languageProbability: Double?
    ) throws -> AudioDiagnosticRecord {
        guard !sources.isEmpty else { throw AudioDiagnosticsStoreError.audioMissing }
        try prepareRoot()

        let directory = recordDirectory(for: historyID)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }

        let existing = try loadRecord(for: historyID)
        var segments = existing?.segments ?? []
        for source in sources where !segments.contains(where: { $0.id == source.id }) {
            let sourceValues = try source.url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            )
            guard sourceValues.isRegularFile == true,
                  sourceValues.isSymbolicLink != true,
                  let byteCount = sourceValues.fileSize,
                  byteCount > 0 else {
                throw AudioDiagnosticsStoreError.unsafeSource
            }

            let fileExtension = safeExtension(source.url.pathExtension)
            let fileName = "\(source.id.uuidString.lowercased()).\(fileExtension)"
            let destination = directory.appendingPathComponent(fileName)
            let temporary = directory.appendingPathComponent(
                ".\(source.id.uuidString.lowercased()).copying"
            )
            if fileManager.fileExists(atPath: temporary.path) {
                try fileManager.removeItem(at: temporary)
            }
            try fileManager.copyItem(at: source.url, to: temporary)
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: temporary.path
            )
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            segments.append(
                AudioDiagnosticRecord.Segment(
                    id: source.id,
                    fileName: fileName,
                    byteCount: Int64(byteCount)
                )
            )
        }

        guard !segments.isEmpty else { throw AudioDiagnosticsStoreError.audioMissing }
        let record = AudioDiagnosticRecord(
            historyID: historyID,
            createdAt: existing?.createdAt ?? createdAt,
            duration: max(existing?.duration ?? 0, duration),
            quality: merged(existing?.quality, quality),
            microphoneMode: microphoneMode,
            languageProbability: languageProbability ?? existing?.languageProbability,
            segments: segments
        )
        let data = try JSONEncoder().encode(record)
        try data.write(
            to: manifestURL(for: historyID),
            options: [.atomic, .completeFileProtection]
        )
        recordsByHistoryID[historyID] = record
        return record
    }

    func record(for historyID: UUID) -> AudioDiagnosticRecord? {
        recordsByHistoryID[historyID]
    }

    func hasAudio(for historyID: UUID) -> Bool {
        guard let record = record(for: historyID) else { return false }
        return !record.segments.isEmpty
    }

    func togglePlayback(for historyID: UUID) throws {
        if playingHistoryID == historyID {
            stopPlayback()
            return
        }
        stopPlayback()
        playbackQueue = try audioURLs(for: historyID)
        guard !playbackQueue.isEmpty else {
            throw AudioDiagnosticsStoreError.audioMissing
        }
        playingHistoryID = historyID
        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio)
            try audioSession.setActive(true)
            try playNext()
        } catch {
            stopPlayback()
            throw AudioDiagnosticsStoreError.playbackFailed
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playbackQueue = []
        playingHistoryID = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func delete(historyID: UUID) {
        if playingHistoryID == historyID {
            stopPlayback()
        }
        let directory = recordDirectory(for: historyID)
        guard directory.deletingLastPathComponent().standardizedFileURL == rootDirectory else {
            return
        }
        try? fileManager.removeItem(at: directory)
        recordsByHistoryID[historyID] = nil
    }

    func prune(
        keeping historyIDs: Set<UUID>,
        maximumBytes: Int64 = AudioDiagnosticsStore.maximumStoredBytes
    ) {
        guard (try? prepareRoot()) != nil else { return }
        let records = Array(recordsByHistoryID.values)
        for record in records where !historyIDs.contains(record.historyID) {
            delete(historyID: record.historyID)
        }

        var retained = recordsByHistoryID.values.sorted { $0.createdAt > $1.createdAt }
        var total = retained.reduce(Int64(0)) { partial, record in
            partial + record.segments.reduce(Int64(0)) { $0 + $1.byteCount }
        }
        while total > max(0, maximumBytes), let oldest = retained.popLast() {
            total -= oldest.segments.reduce(Int64(0)) { $0 + $1.byteCount }
            delete(historyID: oldest.historyID)
        }
    }

    func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        do {
            try playNext()
        } catch {
            stopPlayback()
        }
    }

    private func playNext() throws {
        guard !playbackQueue.isEmpty else {
            stopPlayback()
            return
        }
        let next = playbackQueue.removeFirst()
        let player = try AVAudioPlayer(contentsOf: next)
        player.delegate = self
        player.prepareToPlay()
        guard player.play() else {
            throw AudioDiagnosticsStoreError.playbackFailed
        }
        self.player = player
    }

    private func audioURLs(for historyID: UUID) throws -> [URL] {
        guard let record = try loadRecord(for: historyID) else {
            throw AudioDiagnosticsStoreError.audioMissing
        }
        let directory = recordDirectory(for: historyID)
        return try record.segments.map { segment in
            let url = directory.appendingPathComponent(segment.fileName)
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AudioDiagnosticsStoreError.corruptRecord
            }
            return url
        }
    }

    private func loadAllRecords() -> [AudioDiagnosticRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return urls.compactMap { url in
            guard url.pathExtension == "diagnostic",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else {
                return nil
            }
            return try? loadRecord(for: id)
        }
    }

    private func loadRecord(for historyID: UUID) throws -> AudioDiagnosticRecord? {
        let manifest = manifestURL(for: historyID)
        guard fileManager.fileExists(atPath: manifest.path) else { return nil }
        let values = try manifest.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw AudioDiagnosticsStoreError.corruptRecord
        }
        let decoded = try JSONDecoder().decode(
            AudioDiagnosticRecord.self,
            from: Data(contentsOf: manifest)
        )
        guard decoded.historyID == historyID,
              decoded.segments.allSatisfy({
                  $0.fileName == "\($0.id.uuidString.lowercased()).\(safeExtension(($0.fileName as NSString).pathExtension))"
              }) else {
            throw AudioDiagnosticsStoreError.corruptRecord
        }
        return decoded
    }

    private func merged(
        _ first: AudioCaptureQualitySummary?,
        _ second: AudioCaptureQualitySummary
    ) -> AudioCaptureQualitySummary {
        guard let first, first.sampleCount > 0 else { return second }
        guard second.sampleCount > 0 else { return first }
        let total = first.sampleCount + second.sampleCount
        let firstWeight = Double(first.sampleCount) / Double(total)
        let secondWeight = Double(second.sampleCount) / Double(total)
        let audible = first.audibleFraction * firstWeight
            + second.audibleFraction * secondWeight
        let average = first.averageLevel * firstWeight
            + second.averageLevel * secondWeight
        let clipping = first.clippingFraction * firstWeight
            + second.clippingFraction * secondWeight
        let classification: AudioCaptureSignalClassification
        if clipping >= 0.03 {
            classification = .clippingRisk
        } else if audible < 0.05 {
            classification = .mostlySilent
        } else if audible < 0.25 || average < 0.08 {
            classification = .quiet
        } else {
            classification = .healthy
        }
        return AudioCaptureQualitySummary(
            sampleCount: total,
            audibleFraction: audible,
            averageLevel: average,
            peakLevel: max(first.peakLevel, second.peakLevel),
            clippingFraction: clipping,
            classification: classification
        )
    }

    private func prepareRoot() throws {
        if !fileManager.fileExists(atPath: rootDirectory.path) {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
        }
    }

    private func recordDirectory(for historyID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(historyID.uuidString.lowercased()).diagnostic",
            isDirectory: true
        )
    }

    private func manifestURL(for historyID: UUID) -> URL {
        recordDirectory(for: historyID).appendingPathComponent("manifest.json")
    }

    private func safeExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["m4a", "caf", "wav"].contains(normalized) ? normalized : "m4a"
    }
}
