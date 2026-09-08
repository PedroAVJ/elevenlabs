import Darwin
import Foundation
import UniformTypeIdentifiers

protocol ElevenLabsClientProtocol: Sendable {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String],
        diarize: Bool
    ) async throws -> TranscriptionResult
}

extension ElevenLabsClientProtocol {
    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String]
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioURL: audioURL,
            apiKey: apiKey,
            language: language,
            cleanSpeech: cleanSpeech,
            keyterms: keyterms,
            diarize: false
        )
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool
    ) async throws -> TranscriptionResult {
        try await transcribe(
            audioURL: audioURL,
            apiKey: apiKey,
            language: language,
            cleanSpeech: cleanSpeech,
            keyterms: [],
            diarize: false
        )
    }
}

enum ElevenLabsClientError: LocalizedError, Equatable {
    case invalidResponse
    case api(statusCode: Int, message: String)
    /// Keeps the URL loading reason typed. Collapsing certificate, ATS, and
    /// unsupported-URL failures into status 0 made all of them look like an
    /// internet outage and eligible for reconnect retry.
    case transport(code: URLError.Code, message: String)
    case emptyTranscript

    enum Category: String, Equatable, Sendable {
        case authentication
        case invalidRequest
        case rateLimited
        case serviceUnavailable
        case network
        case invalidResponse
        case noSpeech
        case unknown
    }

    var category: Category {
        switch self {
        case .invalidResponse:
            .invalidResponse
        case .emptyTranscript:
            .noSpeech
        case let .transport(code, _):
            Self.isConnectivityCode(code) ? .network : .unknown
        case let .api(statusCode, _):
            switch statusCode {
            case 0:
                .network
            case 401, 403:
                .authentication
            case 400, 404, 409, 413, 415, 422:
                .invalidRequest
            case 429:
                .rateLimited
            case 408, 500, 502, 503, 504:
                .serviceUnavailable
            default:
                .unknown
            }
        }
    }

    static func isConnectivityCode(_ code: URLError.Code) -> Bool {
        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable,
             .backgroundSessionWasDisconnected:
            true
        default:
            false
        }
    }

    var isRetryable: Bool {
        switch category {
        case .rateLimited, .serviceUnavailable, .network:
            true
        case .authentication, .invalidRequest, .invalidResponse, .noSpeech, .unknown:
            false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The speech service returned an unreadable response."
        case let .api(statusCode, message):
            if statusCode == 0 {
                "Could not reach the speech service: \(message)"
            } else {
                "Speech service error \(statusCode): \(message)"
            }
        case let .transport(_, message):
            message
        case .emptyTranscript:
            "The speech service did not hear any speech. Try again a little closer to the microphone."
        }
    }

    var recoverySuggestion: String? {
        switch category {
        case .authentication:
            "Open Settings and update your speech API key."
        case .invalidRequest:
            "Check the recording, language, and custom vocabulary, then try again."
        case .rateLimited:
            "The speech service retried automatically. Wait a moment before trying again."
        case .serviceUnavailable:
            "The speech service retried automatically and may be temporarily unavailable."
        case .network:
            "Check your internet connection and try again."
        case .invalidResponse:
            "Try again. If this keeps happening, the speech service may have changed its response format."
        case .noSpeech:
            "Speak a little closer to the microphone and try again."
        case .unknown:
            "Try again. If this keeps happening, check the speech service status."
        }
    }
}

struct ElevenLabsRetryPolicy: Equatable, Sendable {
    static let standard = ElevenLabsRetryPolicy(
        maximumAttempts: 3,
        initialDelay: 0.5,
        maximumDelay: 30
    )
    /// App Intent transcription owns only a finite iOS background assertion.
    /// Its client-level retry loop must leave time to publish a terminal phase
    /// and clean up audio before iOS suspends the process.
    static let backgroundIntent = ElevenLabsRetryPolicy(
        maximumAttempts: 1,
        initialDelay: 0,
        maximumDelay: 0
    )

    let maximumAttempts: Int
    let initialDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(maximumAttempts: Int, initialDelay: TimeInterval, maximumDelay: TimeInterval) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.initialDelay = initialDelay.isFinite ? max(0, initialDelay) : 0
        self.maximumDelay = maximumDelay.isFinite ? max(0, maximumDelay) : 0
    }

    func delay(afterAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
        if let retryAfter {
            return min(max(0, retryAfter), maximumDelay)
        }

        let exponent = Double(max(0, attempt - 1))
        return min(initialDelay * pow(2, exponent), maximumDelay)
    }
}

private actor ElevenLabsRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
            return
        }
        activeCount = max(0, activeCount - 1)
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

/// Speech uploads carry a custom `xi-api-key` header and a replayable body
/// stream. URLSession is not required to scrub custom credentials on a
/// cross-origin redirect, so ElevenLabs rejects every redirect before a second
/// request can be created. ElevenLabs' documented endpoint is final; a 3xx is
/// safer as a visible retryable failure than as credential/audio forwarding.
class ElevenLabsNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Per-attempt upload progress used to distinguish a dead connection from
/// legitimate server-side transcription time. Scribe does not stream a
/// response while it works, so the short deadline applies only until every
/// multipart byte has left the Mac.
final class ElevenLabsUploadProgressDelegate: ElevenLabsNoRedirectDelegate, @unchecked Sendable {
    struct Snapshot: Sendable {
        let uploadIsComplete: Bool
        let attemptIsFinished: Bool
        let lastProgressUptime: TimeInterval
    }

    private let expectedUploadBytes: Int64
    private let lock = NSLock()
    private var totalBytesSent: Int64 = 0
    private var attemptIsFinished = false
    private var lastProgressUptime = ProcessInfo.processInfo.systemUptime

    init(expectedUploadBytes: Int64) {
        self.expectedUploadBytes = max(1, expectedUploadBytes)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.withLock {
            guard !attemptIsFinished else { return }
            self.totalBytesSent = max(self.totalBytesSent, totalBytesSent)
            lastProgressUptime = ProcessInfo.processInfo.systemUptime
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                uploadIsComplete: totalBytesSent >= expectedUploadBytes,
                attemptIsFinished: attemptIsFinished,
                lastProgressUptime: lastProgressUptime
            )
        }
    }

    func markFinished() {
        lock.withLock {
            attemptIsFinished = true
        }
    }
}

private enum ElevenLabsAttemptResult: @unchecked Sendable {
    case response(Data, URLResponse)
}

enum ElevenLabsRealtimeConnectionFailure: String, Equatable {
    case serverClosed = "server_closed"
    case serverGoingAway = "server_going_away"
    case unsupportedFrame = "unsupported_frame"
    case policyViolation = "policy_violation"
    case messageTooBig = "message_too_big"
    case networkUnavailable = "network_unavailable"
    case connectionReset = "connection_reset"
    case socketNotConnected = "socket_not_connected"
    case timedOut = "transport_timeout"
    case badServerResponse = "bad_server_response"
    case secureConnectionFailed = "secure_connection_failed"
    case cancelled = "transport_cancelled"
    case otherTransport = "other_transport"
}

enum ElevenLabsRealtimeError: LocalizedError, Equatable {
    case invalidWaveFile
    case invalidServerEvent
    case connectionTimedOut
    case server(type: String)
    case connectionLost(ElevenLabsRealtimeConnectionFailure)

    var errorDescription: String? {
        switch self {
        case .invalidWaveFile:
            "The live transcription preview could not read the recording stream."
        case .invalidServerEvent:
            "The live transcription preview received an invalid server event."
        case .connectionTimedOut:
            "The live transcription preview could not connect in time."
        case let .server(type):
            "The live transcription preview stopped (\(type))."
        case .connectionLost:
            "The live transcription preview lost its connection."
        }
    }

    var telemetryReason: String {
        switch self {
        case .invalidWaveFile: "invalid_wave"
        case .invalidServerEvent: "invalid_server_event"
        case .connectionTimedOut: "connection_timeout"
        case let .server(type): "server_\(type)"
        case let .connectionLost(failure): failure.rawValue
        }
    }
}

/// Reads only newly appended PCM payload bytes from a growing RIFF/WAVE file.
/// The durable batch recording remains owned by the audio engine; this reader
/// never writes, truncates, or trusts the unfinished RIFF payload length.
struct GrowingPCM16WaveReader {
    private let handle: FileHandle
    private(set) var readOffset: UInt64

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        do {
            try handle.seek(toOffset: 0)
            guard
                let header = try handle.read(upToCount: 64 * 1_024),
                let dataOffset = Self.dataOffset(in: header)
            else {
                try? handle.close()
                throw ElevenLabsRealtimeError.invalidWaveFile
            }
            self.handle = handle
            readOffset = UInt64(dataOffset)
        } catch {
            try? handle.close()
            throw error
        }
    }

    mutating func readAvailable(
        maximumByteCount: Int = 16_000
    ) throws -> Data? {
        let fileEnd = try handle.seekToEnd()
        guard fileEnd > readOffset else { return nil }
        let available = fileEnd - readOffset
        let bounded = min(
            available,
            UInt64(max(2, maximumByteCount))
        )
        // The realtime API consumes little-endian Int16 samples. Never split
        // a sample when reading at the writer's current end-of-file boundary.
        let sampleAligned = bounded - (bounded % 2)
        guard sampleAligned > 0 else { return nil }
        try handle.seek(toOffset: readOffset)
        guard
            let data = try handle.read(upToCount: Int(sampleAligned)),
            !data.isEmpty
        else {
            return nil
        }
        let alignedCount = data.count - (data.count % 2)
        guard alignedCount > 0 else { return nil }
        readOffset += UInt64(alignedCount)
        return alignedCount == data.count
            ? data
            : Data(data.prefix(alignedCount))
    }

    private static func dataOffset(in bytes: Data) -> Int? {
        guard
            bytes.count >= 12,
            ascii(in: bytes, at: 0, count: 4) == "RIFF",
            ascii(in: bytes, at: 8, count: 4) == "WAVE"
        else {
            return nil
        }

        var cursor = 12
        var hasExpectedFormat = false
        while cursor + 8 <= bytes.count {
            guard let chunkSize = littleEndianUInt32(in: bytes, at: cursor + 4)
            else {
                return nil
            }
            let payloadOffset = cursor + 8
            let payloadSize = Int(chunkSize)
            let chunkName = ascii(in: bytes, at: cursor, count: 4)

            if chunkName == "fmt " {
                guard
                    payloadSize >= 16,
                    payloadOffset + 16 <= bytes.count,
                    littleEndianUInt16(in: bytes, at: payloadOffset) == 1,
                    littleEndianUInt16(in: bytes, at: payloadOffset + 2) == 1,
                    littleEndianUInt32(in: bytes, at: payloadOffset + 4)
                        == 16_000,
                    littleEndianUInt16(in: bytes, at: payloadOffset + 14) == 16
                else {
                    return nil
                }
                hasExpectedFormat = true
            } else if chunkName == "data" {
                return hasExpectedFormat ? payloadOffset : nil
            }

            let paddedPayloadSize = payloadSize + (payloadSize % 2)
            guard
                paddedPayloadSize >= payloadSize,
                payloadOffset <= Int.max - paddedPayloadSize
            else {
                return nil
            }
            cursor = payloadOffset + paddedPayloadSize
        }
        return nil
    }

    private static func ascii(
        in bytes: Data,
        at offset: Int,
        count: Int
    ) -> String? {
        guard offset >= 0, count >= 0, offset + count <= bytes.count else {
            return nil
        }
        return String(
            data: bytes.subdata(in: offset..<(offset + count)),
            encoding: .ascii
        )
    }

    private static func littleEndianUInt16(
        in bytes: Data,
        at offset: Int
    ) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset])
            | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func littleEndianUInt32(
        in bytes: Data,
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
}

struct RealtimeTranscriptAccumulator {
    private let prefix: String
    private var committedSegments: [String] = []
    private var partial = ""
    private var lastEmitted = ""

    init(prefix: String = "") {
        self.prefix = Self.normalized(prefix)
    }

    mutating func consume(messageType: String, text: String?) -> String? {
        let text = Self.normalized(text ?? "")
        switch messageType {
        case "partial_transcript", "final_transcript":
            partial = text
        case "committed_transcript":
            if !text.isEmpty {
                committedSegments.append(text)
            }
            partial = ""
        default:
            return nil
        }

        let draft = ([prefix] + committedSegments + [partial])
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, draft != lastEmitted else { return nil }
        lastEmitted = draft
        return draft
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Best-effort low-latency preview. Batch Scribe remains the durable source of
/// truth, so every error here is isolated from recording and batch delivery.
actor ElevenLabsRealtimeClient {
    typealias DraftHandler = @Sendable (String) async -> Void

    private enum StopRequest {
        case none
        case finish
        case cancel
    }

    private struct IncomingEvent: Decodable {
        let messageType: String
        let text: String?

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case text
        }
    }

    private struct AudioChunk: Encodable {
        let messageType = "input_audio_chunk"
        let audioBase64: String
        let commit: Bool?

        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case audioBase64 = "audio_base_64"
            case commit
        }
    }

    private let endpoint: URL
    private let sessionConfiguration: URLSessionConfiguration
    private let pollingNanoseconds: UInt64
    private var stopRequest = StopRequest.none
    private var socket: URLSessionWebSocketTask?
    private var sessionStarted = false
    private var terminalError: ElevenLabsRealtimeError?
    private var receivedCommitAfterFinish = false

    init(
        endpoint: URL = URL(
            string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime"
        )!,
        sessionConfiguration: URLSessionConfiguration = .ephemeral,
        pollingInterval: TimeInterval = 0.15
    ) {
        self.endpoint = endpoint
        self.sessionConfiguration = sessionConfiguration
        pollingNanoseconds = UInt64(
            max(0.05, pollingInterval) * 1_000_000_000
        )
    }

    func streamGrowingWave(
        at audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        prefix: String = "",
        onDraft: @escaping DraftHandler
    ) async throws {
        stopRequest = .none
        sessionStarted = false
        terminalError = nil
        receivedCommitAfterFinish = false

        let request = Self.makeRequest(
            endpoint: endpoint,
            apiKey: apiKey,
            language: language,
            cleanSpeech: cleanSpeech
        )
        let session = URLSession(configuration: sessionConfiguration)
        let socket = session.webSocketTask(with: request)
        self.socket = socket
        socket.resume()

        let receiver = Task { [weak self] in
            await self?.receiveMessages(
                from: socket,
                prefix: prefix,
                onDraft: onDraft
            )
        }
        defer {
            receiver.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
            self.socket = nil
        }

        try await waitForSessionStart()
        var reader = try GrowingPCM16WaveReader(url: audioURL)
        while stopRequest == .none {
            try Task.checkCancellation()
            if let error = terminalError { throw error }
            if let bytes = try reader.readAvailable() {
                try await send(bytes, commit: false, through: socket)
            } else {
                try await Task.sleep(nanoseconds: pollingNanoseconds)
            }
        }

        guard stopRequest != .cancel else { throw CancellationError() }
        try Task.checkCancellation()
        if let error = terminalError { throw error }

        var finalChunks: [Data] = []
        while let bytes = try reader.readAvailable() {
            finalChunks.append(bytes)
        }
        // Ignore an earlier VAD boundary: Send now must not become available
        // until the server has had a chance to consume this stopped file's
        // final audio and manual commit.
        receivedCommitAfterFinish = false
        if finalChunks.isEmpty {
            // A short silent commit is valid PCM and keeps the final control
            // message inside the documented audio-chunk event shape.
            try await send(Data(repeating: 0, count: 3_200), commit: true, through: socket)
        } else {
            for bytes in finalChunks.dropLast() {
                try await send(bytes, commit: false, through: socket)
            }
            try await send(finalChunks[finalChunks.count - 1], commit: true, through: socket)
        }

        // Do not hold up batch delivery. This bounded grace period merely lets
        // the manual commit replace a trailing partial before the preview ends.
        for index in 0..<20 {
            if index >= 3, receivedCommitAfterFinish { break }
            if let error = terminalError { throw error }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    func finish() {
        guard stopRequest == .none else { return }
        stopRequest = .finish
    }

    func cancel() {
        stopRequest = .cancel
        socket?.cancel(with: .goingAway, reason: nil)
    }

    static func makeRequest(
        endpoint: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool
    ) -> URLRequest {
        var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        )!
        var queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "no_verbatim", value: cleanSpeech ? "true" : "false"),
        ]
        if let languageCode = language.apiCode {
            queryItems.append(
                URLQueryItem(name: "language_code", value: languageCode)
            )
        }
        components.queryItems = queryItems
        var request = URLRequest(url: components.url!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        return request
    }

    private func waitForSessionStart() async throws {
        for _ in 0..<80 {
            try Task.checkCancellation()
            if sessionStarted { return }
            if let error = terminalError { throw error }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw ElevenLabsRealtimeError.connectionTimedOut
    }

    private func receiveMessages(
        from socket: URLSessionWebSocketTask,
        prefix: String,
        onDraft: @escaping DraftHandler
    ) async {
        var accumulator = RealtimeTranscriptAccumulator(prefix: prefix)
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                let data: Data
                switch message {
                case let .data(value):
                    data = value
                case let .string(value):
                    data = Data(value.utf8)
                @unknown default:
                    continue
                }
                let event: IncomingEvent
                do {
                    event = try JSONDecoder().decode(IncomingEvent.self, from: data)
                } catch {
                    terminalError = .invalidServerEvent
                    return
                }
                if event.messageType == "session_started" {
                    sessionStarted = true
                    continue
                }
                if Self.isServerError(event.messageType) {
                    terminalError = .server(type: event.messageType)
                    return
                }
                if
                    let draft = accumulator.consume(
                        messageType: event.messageType,
                        text: event.text
                    )
                {
                    await onDraft(draft)
                }
                if
                    stopRequest == .finish,
                    event.messageType == "committed_transcript"
                {
                    receivedCommitAfterFinish = true
                }
            } catch is CancellationError {
                return
            } catch {
                if stopRequest == .none {
                    terminalError = .connectionLost(
                        Self.connectionFailure(for: error, socket: socket)
                    )
                }
                return
            }
        }
    }

    private func send(
        _ bytes: Data,
        commit: Bool,
        through socket: URLSessionWebSocketTask
    ) async throws {
        let message = try Self.audioMessage(bytes, commit: commit)
        do {
            try await socket.send(message)
        } catch {
            throw ElevenLabsRealtimeError.connectionLost(
                Self.connectionFailure(for: error, socket: socket)
            )
        }
    }

    static func audioMessage(
        _ bytes: Data,
        commit: Bool
    ) throws -> URLSessionWebSocketTask.Message {
        let payload = AudioChunk(
            audioBase64: bytes.base64EncodedString(),
            commit: commit ? true : nil
        )
        let data = try JSONEncoder().encode(payload)
        // ElevenLabs' realtime endpoint consumes JSON text messages. A binary
        // frame contains the same bytes but is rejected by the service before
        // it can return a partial transcript.
        return .string(String(decoding: data, as: UTF8.self))
    }

    static func connectionFailure(
        for error: Error,
        closeCode: URLSessionWebSocketTask.CloseCode
    ) -> ElevenLabsRealtimeConnectionFailure {
        switch closeCode {
        case .normalClosure:
            return .serverClosed
        case .goingAway:
            return .serverGoingAway
        case .unsupportedData:
            return .unsupportedFrame
        case .policyViolation:
            return .policyViolation
        case .messageTooBig:
            return .messageTooBig
        case .invalid:
            break
        default:
            return .serverClosed
        }

        let error = error as NSError
        if error.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: error.code) {
            case .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost:
                return .networkUnavailable
            case .networkConnectionLost:
                return .connectionReset
            case .cannotConnectToHost:
                return .socketNotConnected
            case .timedOut:
                return .timedOut
            case .badServerResponse:
                return .badServerResponse
            case .secureConnectionFailed,
                 .serverCertificateHasBadDate,
                 .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return .secureConnectionFailed
            case .cancelled:
                return .cancelled
            default:
                break
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case 51:
                return .networkUnavailable
            case 54:
                return .connectionReset
            case 57:
                return .socketNotConnected
            case 60:
                return .timedOut
            default:
                break
            }
        }
        return .otherTransport
    }

    private static func connectionFailure(
        for error: Error,
        socket: URLSessionWebSocketTask
    ) -> ElevenLabsRealtimeConnectionFailure {
        connectionFailure(for: error, closeCode: socket.closeCode)
    }

    private static func isServerError(_ messageType: String) -> Bool {
        [
            "auth_error",
            "quota_exceeded",
            "transcriber_error",
            "input_error",
            "invalid_request",
            "error",
            "commit_throttled",
            "unaccepted_terms",
            "rate_limited",
            "queue_overflow",
            "resource_exhausted",
            "session_time_limit_exceeded",
            "chunk_size_exceeded",
            "insufficient_audio_activity",
        ].contains(messageType)
    }
}

final class ElevenLabsClient: ElevenLabsClientProtocol, @unchecked Sendable {
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private let sessionConfiguration: URLSessionConfiguration
    private let endpoint: URL
    private let retryPolicy: ElevenLabsRetryPolicy
    private let requestTimeout: TimeInterval
    private let uploadStallTimeout: TimeInterval
    private let limiter: ElevenLabsRequestLimiter
    private let sleeper: Sleeper
    private let now: @Sendable () -> Date

    /// A process can be terminated after URLSession cancellation but before
    /// this client's normal `defer` runs. At primary-app launch, remove only
    /// exact private multipart files created by this client. Holding an open,
    /// non-following descriptor and rechecking the inode keeps a swapped path,
    /// symlink, directory, or unrelated temp file out of scope.
    @discardableResult
    static func cleanupAbandonedMultipartUploads(
        in temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) -> Int {
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: temporaryDirectoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            return 0
        }

        var removedCount = 0
        for url in candidates where isGeneratedMultipartUploadName(url.lastPathComponent) {
            let descriptor = url.path.withCString {
                Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard descriptor >= 0 else { continue }

            var openedMetadata = stat()
            let isSafe = Darwin.fstat(descriptor, &openedMetadata) == 0
                && openedMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && openedMetadata.st_uid == Darwin.getuid()
                && openedMetadata.st_nlink == 1
                && openedMetadata.st_mode & mode_t(0o777) == mode_t(0o600)
            guard isSafe else {
                Darwin.close(descriptor)
                continue
            }

            var currentMetadata = stat()
            let stillSameFile = url.path.withCString {
                Darwin.lstat($0, &currentMetadata) == 0
            }
                && currentMetadata.st_dev == openedMetadata.st_dev
                && currentMetadata.st_ino == openedMetadata.st_ino
                && currentMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
                && currentMetadata.st_uid == Darwin.getuid()
                && currentMetadata.st_nlink == 1
                && currentMetadata.st_mode & mode_t(0o777) == mode_t(0o600)
            guard stillSameFile else {
                Darwin.close(descriptor)
                continue
            }

            let status = url.path.withCString { Darwin.unlink($0) }
            Darwin.close(descriptor)
            if status == 0 { removedCount += 1 }
        }
        return removedCount
    }

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
        retryPolicy: ElevenLabsRetryPolicy = .standard,
        requestTimeout: TimeInterval = 300,
        uploadStallTimeout: TimeInterval = 8,
        maximumConcurrentRequests: Int = 3,
        sleeper: @escaping Sleeper = { delay in
            try Task.checkCancellation()
            guard delay > 0 else {
                await Task.yield()
                return
            }
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        sessionConfiguration = session.configuration
        self.endpoint = endpoint
        self.retryPolicy = retryPolicy
        self.requestTimeout = requestTimeout.isFinite ? max(1, requestTimeout) : 300
        self.uploadStallTimeout = uploadStallTimeout.isFinite ? max(0.1, uploadStallTimeout) : 8
        limiter = ElevenLabsRequestLimiter(limit: maximumConcurrentRequests)
        self.sleeper = sleeper
        self.now = now
    }

    func transcribe(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String],
        diarize: Bool
    ) async throws -> TranscriptionResult {
        // Admission covers multipart preparation, retries, and response decode.
        // Eight simultaneous twenty-minute WAVs must not each allocate/build a
        // request before discovering that only three may run.
        try await limiter.acquire()
        do {
            let result = try await transcribeAdmitted(
                audioURL: audioURL,
                apiKey: apiKey,
                language: language,
                cleanSpeech: cleanSpeech,
                keyterms: keyterms,
                diarize: diarize
            )
            await limiter.release()
            return result
        } catch {
            await limiter.release()
            throw error
        }
    }

    private func transcribeAdmitted(
        audioURL: URL,
        apiKey: String,
        language: TranscriptionLanguage,
        cleanSpeech: Bool,
        keyterms: [String],
        diarize: Bool
    ) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        let boundary = "ElevenLabs-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElevenLabs-upload-\(UUID().uuidString)")
            .appendingPathExtension("multipart")
        // Register cleanup before writing. A missing/unreadable source or task
        // cancellation can fail halfway through multipart preparation, and that
        // partial file contains private dictated audio just like a complete one.
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        try Self.writeMultipartBody(
            to: bodyURL,
            boundary: boundary,
            audioURL: audioURL,
            // A local filename can contain a person's name, customer name, or
            // project title. Scribe only needs a useful extension, so do not
            // disclose the original basename in the multipart headers.
            filename: Self.uploadFilename(for: audioURL),
            audioContentType: Self.audioContentType(for: audioURL),
            languageCode: language.apiCode,
            cleanSpeech: cleanSpeech,
            keyterms: Self.validKeyterms(keyterms),
            diarize: diarize
        )
        try Task.checkCancellation()

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        // Imported files and the supported twenty-minute dictations can take
        // materially longer than a short voice note to upload and process.
        // Keep the request bounded, but do not manufacture a timeout while
        // Scribe is still doing the quality-first batch transcription.
        request.timeoutInterval = requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        guard
            let values = try? bodyURL.resourceValues(forKeys: [.fileSizeKey]),
            let size = values.fileSize,
            size > 0
        else {
            throw ElevenLabsClientError.invalidResponse
        }
        let uploadByteCount = Int64(size)
        request.setValue(String(size), forHTTPHeaderField: "Content-Length")

        var attempt = 0
        while attempt < retryPolicy.maximumAttempts {
            try Task.checkCancellation()
            attempt += 1

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await perform(
                    request,
                    bodyURL: bodyURL,
                    uploadByteCount: uploadByteCount
                )
            } catch {
                if error is CancellationError || Task.isCancelled {
                    throw CancellationError()
                }
                if let clientError = error as? ElevenLabsClientError {
                    throw clientError
                }
                if let urlError = error as? URLError {
                    if urlError.code == .cancelled {
                        throw CancellationError()
                    }
                    if Self.isTransient(urlError), attempt < retryPolicy.maximumAttempts {
                        try await waitBeforeRetry(attempt: attempt, retryAfter: nil)
                        continue
                    }
                    throw ElevenLabsClientError.transport(
                        code: urlError.code,
                        message: Self.networkMessage(for: urlError)
                    )
                }
                throw ElevenLabsClientError.transport(
                    code: .unknown,
                    message: "The network request failed."
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ElevenLabsClientError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                let apiError = ElevenLabsClientError.api(
                    statusCode: httpResponse.statusCode,
                    message: Self.errorMessage(from: data)
                )
                if
                    Self.isTransient(statusCode: httpResponse.statusCode),
                    attempt < retryPolicy.maximumAttempts
                {
                    try await waitBeforeRetry(
                        attempt: attempt,
                        retryAfter: Self.retryAfter(from: httpResponse, now: now())
                    )
                    continue
                }
                throw apiError
            }

            guard let result = try? JSONDecoder().decode(TranscriptionResult.self, from: data) else {
                throw ElevenLabsClientError.invalidResponse
            }
            let trimmedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedText.isEmpty else {
                throw ElevenLabsClientError.emptyTranscript
            }

            return TranscriptionResult(
                text: trimmedText,
                languageCode: result.languageCode,
                languageProbability: result.languageProbability,
                words: result.words
            )
        }

        throw ElevenLabsClientError.invalidResponse
    }

    private func perform(
        _ request: URLRequest,
        bodyURL: URL,
        uploadByteCount: Int64
    ) async throws -> (Data, URLResponse) {
        try Task.checkCancellation()
        // A session is deliberately single-attempt. A retry must never inherit
        // the stale HTTP/3 connection that prompted this safeguard.
        let attemptSession = URLSession(configuration: sessionConfiguration)
        let progress = ElevenLabsUploadProgressDelegate(
            expectedUploadBytes: uploadByteCount
        )
        defer {
            progress.markFinished()
            attemptSession.invalidateAndCancel()
        }

        return try await withThrowingTaskGroup(of: ElevenLabsAttemptResult.self) { group in
            group.addTask {
                let (data, response) = try await attemptSession.upload(
                    for: request,
                    fromFile: bodyURL,
                    delegate: progress
                )
                progress.markFinished()
                return .response(data, response)
            }
            group.addTask {
                try await self.watchForStalledUpload(progress)
            }
            defer { group.cancelAll() }

            guard let first = try await group.next() else {
                throw CancellationError()
            }
            switch first {
            case let .response(data, response):
                return (data, response)
            }
        }
    }

    func watchForStalledUpload(
        _ progress: ElevenLabsUploadProgressDelegate
    ) async throws -> Never {
        while true {
            try Task.checkCancellation()
            let snapshot = progress.snapshot()
            if snapshot.attemptIsFinished || snapshot.uploadIsComplete {
                // Once the upload is complete, the request's longer timeout
                // governs Scribe's legitimate server-side processing time.
                try await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }

            let elapsed = max(
                0,
                ProcessInfo.processInfo.systemUptime - snapshot.lastProgressUptime
            )
            if elapsed >= uploadStallTimeout {
                throw URLError(.timedOut)
            }
            let remaining = max(0.01, uploadStallTimeout - elapsed)
            let pollInterval = min(0.25, remaining)
            try await Task.sleep(
                nanoseconds: UInt64(pollInterval * 1_000_000_000)
            )
        }
    }

    private func waitBeforeRetry(attempt: Int, retryAfter: TimeInterval?) async throws {
        try Task.checkCancellation()
        let delay = retryPolicy.delay(afterAttempt: attempt, retryAfter: retryAfter)
        try await sleeper(delay)
        try Task.checkCancellation()
    }

    private static func isTransient(statusCode: Int) -> Bool {
        statusCode == 429 || [408, 500, 502, 503, 504].contains(statusCode)
    }

    private static func isTransient(_ error: URLError) -> Bool {
        ElevenLabsClientError.isConnectivityCode(error.code)
    }

    private static func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            "The connection timed out."
        case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
            "There is no internet connection."
        case .networkConnectionLost:
            "The connection dropped before transcription finished."
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            "Could not connect to the speech service."
        default:
            "The network request failed."
        }
    }

    private static func retryAfter(from response: HTTPURLResponse, now: Date) -> TimeInterval? {
        guard
            let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawValue.isEmpty
        else {
            return nil
        }

        if let seconds = TimeInterval(rawValue), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: rawValue) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    private static func writeMultipartBody(
        to destinationURL: URL,
        boundary: String,
        audioURL: URL,
        filename: String,
        audioContentType: String,
        languageCode: String?,
        cleanSpeech: Bool,
        keyterms: [String],
        diarize: Bool
    ) throws {
        _ = FileManager.default.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        )
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        func append(_ string: String) throws {
            try output.write(contentsOf: Data(string.utf8))
        }

        func appendField(name: String, value: String) throws {
            try append("--\(boundary)\r\n")
            try append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            try append("\(value)\r\n")
        }

        try appendField(name: "model_id", value: "scribe_v2")
        try appendField(name: "no_verbatim", value: cleanSpeech ? "true" : "false")
        try appendField(name: "tag_audio_events", value: "false")
        // Word timestamps are what make diarization actionable: without them a
        // speaker label cannot be traced back to the audio it came from, so the
        // caller could never check the label against a known voice. No
        // `num_speakers` hint accompanies this — the real number of voices in a
        // room is unknowable at request time, and a wrong hint corrupts the
        // label assignment rather than merely limiting it.
        if diarize {
            try appendField(name: "diarize", value: "true")
            try appendField(name: "timestamps_granularity", value: "word")
        }
        if let languageCode {
            try appendField(name: "language_code", value: languageCode)
        }
        // Repeated `keyterms` fields match ElevenLabs' multipart array
        // encoding and bias recognition toward the user's own
        // names and jargon. This is the only lever the batch endpoint gives for
        // vocabulary, and it is context-aware rather than a forced substitution,
        // so an always-on list does not distort ordinary speech.
        for keyterm in keyterms {
            try appendField(name: "keyterms", value: keyterm)
        }

        let safeFilename = filename
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "_")
            .replacingOccurrences(of: "\n", with: "_")
        try append("--\(boundary)\r\n")
        try append("Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n")
        try append("Content-Type: \(audioContentType)\r\n\r\n")

        let input = try FileHandle(forReadingFrom: audioURL)
        defer { try? input.close() }
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 64 * 1_024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
        try append("\r\n--\(boundary)--\r\n")
    }

    private static func audioContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "m4a": "audio/mp4"
        case "mp4": "video/mp4"
        case "mov": "video/quicktime"
        case "ogg": "audio/ogg"
        case "opus": "audio/opus"
        case "flac": "audio/flac"
        case "aac": "audio/aac"
        case "caf": "audio/x-caf"
        case "aif", "aiff": "audio/aiff"
        case "webm": "video/webm"
        default:
            UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
        }
    }

    private static func uploadFilename(for url: URL) -> String {
        let sourceExtension = url.pathExtension.lowercased()
        let isSafeExtension = !sourceExtension.isEmpty
            && sourceExtension.count <= 12
            && sourceExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        guard isSafeExtension,
              let type = UTType(filenameExtension: sourceExtension),
              type.conforms(to: .audio) || type.conforms(to: .movie) else {
            return "recording.bin"
        }
        return "recording.\(sourceExtension)"
    }

    private static func isGeneratedMultipartUploadName(_ fileName: String) -> Bool {
        let prefix = "ElevenLabs-upload-"
        let suffix = ".multipart"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return false }
        let identifier = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard let uuid = UUID(uuidString: identifier) else { return false }
        return uuid.uuidString == identifier
    }

    /// Defense in depth for callers other than the macOS vocabulary store.
    /// Invalid keyterms make ElevenLabs reject the entire transcription, and
    /// control characters could also break the multipart field framing.
    private static func validKeyterms(_ candidates: [String]) -> [String] {
        let unsupported = CharacterSet(charactersIn: "<>{}[]\\")
            .union(.controlCharacters)
        var accepted: [String] = []
        var seen = Set<String>()

        for candidate in candidates {
            guard accepted.count < 1_000 else { break }
            let term = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !term.isEmpty,
                term.count < 50,
                term.split(whereSeparator: \.isWhitespace).count <= 5,
                term.rangeOfCharacter(from: unsupported) == nil
            else {
                continue
            }
            let duplicateKey = term.lowercased()
            guard seen.insert(duplicateKey).inserted else { continue }
            accepted.append(term)
        }
        return accepted
    }

    private static func errorMessage(from data: Data) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return "The request failed."
        }

        if let detail = dictionary["detail"] as? String {
            return detail
        }
        if
            let detail = dictionary["detail"] as? [String: Any],
            let message = detail["message"] as? String
        {
            return message
        }
        if let message = dictionary["message"] as? String {
            return message
        }
        return "The request failed."
    }
}
