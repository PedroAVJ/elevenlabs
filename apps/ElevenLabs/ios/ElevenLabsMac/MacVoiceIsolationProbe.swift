@preconcurrency import AVFoundation
import Darwin
import Foundation
import OSLog

enum MacVoiceIsolationProbeProgress: Equatable, Sendable {
    case connecting
    case recording
}

/// A deliberately isolated experiment for one unresolved platform question:
/// does an exact Continuity microphone keep Voice Isolation active when the
/// capture graph contains only AVCaptureAudioDataOutput and AVAssetWriter?
///
/// Normal dictation never calls this type. It never changes the Core Audio
/// default device, never falls back to another microphone, never uploads the
/// audio, and deletes its private temporary WAV after validating it.
final class MacVoiceIsolationProbe: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private enum ProbeError: Int, Error {
        case alreadyRunning = 1
        case microphonePermissionDenied
        case deviceUnavailable
        case inputCannotBeAdded
        case outputCannotBeAdded
        case captureDidNotStart
        case writerCannotAcceptSettings
        case writerCannotAddInput
        case writerDidNotStart
        case writerAppendFailed
        case fileProtectionFailed
    }

    private struct FailureFingerprint: Equatable, Sendable {
        let domain: MacVoiceIsolationProbeResult.FailureDomain
        let code: Int
    }

    private struct SampleMetrics: Sendable {
        var receivedBufferCount: UInt64 = 0
        var appendedBufferCount: UInt64 = 0
        var peakLevel: Float = 0
        var firstSampleAt: Date?
        var writerFailure: FailureFingerprint?
    }

    private struct WriterReceipt: Sendable {
        let completed: Bool
        let failure: FailureFingerprint?
    }

    private struct FileValidation: Sendable {
        let duration: TimeInterval
        let byteCount: Int64
    }

    private static let logger = Logger(
        subsystem: "com.pedro.ElevenLabsMac",
        category: "VoiceIsolationProbe"
    )

    private let captureQueue = DispatchQueue(
        label: "com.pedro.ElevenLabs.voice-isolation-probe.capture",
        qos: .userInitiated
    )
    private let sampleQueue = DispatchQueue(
        label: "com.pedro.ElevenLabs.voice-isolation-probe.samples",
        qos: .userInitiated
    )
    private let operationLock = NSLock()
    private let metricsLock = NSLock()

    private var operationIsRunning = false
    private var session: AVCaptureSession?
    private var dataOutput: AVCaptureAudioDataOutput?
    private var temporaryURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var acceptingSamples = false
    private var metrics = SampleMetrics()

    func run(
        deviceID: String,
        captureDuration: TimeInterval = 5,
        progress: @escaping @Sendable (MacVoiceIsolationProbeProgress) -> Void
    ) async -> MacVoiceIsolationProbeResult {
        let startedAt = Date()
        guard beginOperation() else {
            return failureResult(
                startedAt: startedAt,
                error: ProbeError.alreadyRunning,
                released: true
            )
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElevenLabs-probe-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        Self.logger.notice("route=singleDataOutputAssetWriter event=start")
        progress(.connecting)

        do {
            try await ensurePermission()
            try Task.checkCancellation()
            try await prepareSampleWriter(at: url)
            try await startCapture(deviceID: deviceID)

            let clock = ContinuousClock()
            let sampleDeadline = clock.now.advanced(by: .seconds(15))
            var didAnnounceRecording = false
            var captureStoppedWithoutSamples = false

            while true {
                try Task.checkCancellation()
                let snapshot = sampleMetrics()
                if snapshot.firstSampleAt != nil, !didAnnounceRecording {
                    didAnnounceRecording = true
                    progress(.recording)
                }
                if snapshot.writerFailure != nil { break }
                if let firstSampleAt = snapshot.firstSampleAt,
                   Date().timeIntervalSince(firstSampleAt) >= max(1, captureDuration) {
                    break
                }
                if snapshot.firstSampleAt == nil, clock.now >= sampleDeadline { break }
                if snapshot.firstSampleAt == nil, !(await captureIsRunning()) {
                    captureStoppedWithoutSamples = true
                    break
                }
                try await Task.sleep(for: .milliseconds(100))
            }

            let modes = await microphoneModes()
            let writerReceipt = await finishWriting()
            let released = await stopCapture()
            let validation = Self.validateAudioFile(at: url)
            try? Self.removePrivateProbeFile(at: url)
            endOperation()

            let snapshot = sampleMetrics()
            let failure = snapshot.writerFailure ?? writerReceipt.failure
            let status: MacVoiceIsolationProbeResult.Status
            if snapshot.receivedBufferCount == 0 || captureStoppedWithoutSamples {
                status = .noSamples
            } else if !writerReceipt.completed || validation == nil {
                status = .fileInvalid
            } else if !released {
                status = .failed
            } else if modes.active == .voiceIsolation {
                status = .voiceIsolationActive
            } else if modes.preferred == .voiceIsolation {
                status = .selectedButInactive
            } else {
                status = .notSelected
            }

            let result = MacVoiceIsolationProbeResult(
                startedAt: startedAt,
                completedAt: Date(),
                status: status,
                preferredMode: modes.preferred,
                activeMode: modes.active,
                sampleBufferCount: snapshot.receivedBufferCount,
                peakLevel: Double(snapshot.peakLevel),
                playableDurationSeconds: validation?.duration,
                fileByteCount: validation?.byteCount ?? 0,
                releaseConfirmed: released,
                failureDomain: failure?.domain,
                failureCode: failure?.code
            )
            Self.logCompletion(result)
            return result
        } catch {
            await cancelWriting()
            let released = await stopCapture()
            try? Self.removePrivateProbeFile(at: url)
            endOperation()
            let result = failureResult(
                startedAt: startedAt,
                error: error,
                released: released
            )
            Self.logCompletion(result)
            return result
        }
    }

    /// Synchronous lifecycle escape hatch used only while the app is exiting.
    /// The ordinary probe path awaits the same two queues and records release.
    func disconnectSynchronously() {
        captureQueue.sync {
            dataOutput?.setSampleBufferDelegate(nil, queue: nil)
            let staleSession = session
            session = nil
            dataOutput = nil
            staleSession?.stopRunning()
        }
        sampleQueue.sync {
            acceptingSamples = false
            writerInput = nil
            writer?.cancelWriting()
            writer = nil
            if let temporaryURL {
                try? Self.removePrivateProbeFile(at: temporaryURL)
            }
            temporaryURL = nil
        }
        endOperation()
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard acceptingSamples else { return }

        let peak = Self.peakAmplitude(of: sampleBuffer)
        metricsLock.lock()
        metrics.receivedBufferCount &+= 1
        metrics.peakLevel = max(metrics.peakLevel, peak)
        metrics.firstSampleAt = metrics.firstSampleAt ?? Date()
        metricsLock.unlock()

        if writer == nil {
            do {
                try startWriter(with: sampleBuffer)
            } catch {
                recordWriterFailure(error)
                return
            }
        }

        guard let writer, let writerInput, writer.status == .writing else {
            recordWriterFailure(writer?.error ?? ProbeError.writerDidNotStart)
            return
        }
        guard writerInput.isReadyForMoreMediaData else { return }
        guard writerInput.append(sampleBuffer) else {
            recordWriterFailure(writer.error ?? ProbeError.writerAppendFailed)
            return
        }
        metricsLock.lock()
        metrics.appendedBufferCount &+= 1
        metricsLock.unlock()
    }

    private func beginOperation() -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !operationIsRunning else { return false }
        operationIsRunning = true
        return true
    }

    private func endOperation() {
        operationLock.lock()
        operationIsRunning = false
        operationLock.unlock()
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw ProbeError.microphonePermissionDenied
            }
        default:
            throw ProbeError.microphonePermissionDenied
        }
    }

    private func prepareSampleWriter(at url: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ProbeError.captureDidNotStart)
                    return
                }
                writer?.cancelWriting()
                writer = nil
                writerInput = nil
                temporaryURL = url
                acceptingSamples = true
                metricsLock.lock()
                metrics = SampleMetrics()
                metricsLock.unlock()
                try? Self.removePrivateProbeFile(at: url)
                continuation.resume()
            }
        }
    }

    private func startCapture(deviceID: String) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: ProbeError.captureDidNotStart)
                    return
                }
                do {
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                        throw ProbeError.deviceUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: sampleQueue)

                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        throw ProbeError.inputCannotBeAdded
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        throw ProbeError.outputCannotBeAdded
                    }
                    session.addOutput(output)
                    session.commitConfiguration()

                    self.session = session
                    self.dataOutput = output
                    session.startRunning()
                    guard session.isRunning else {
                        throw ProbeError.captureDidNotStart
                    }
                    continuation.resume()
                } catch {
                    self.dataOutput?.setSampleBufferDelegate(nil, queue: nil)
                    let staleSession = self.session
                    self.session = nil
                    self.dataOutput = nil
                    staleSession?.stopRunning()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func captureIsRunning() async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                continuation.resume(returning: self?.session?.isRunning == true)
            }
        }
    }

    private func microphoneModes() async -> (
        preferred: MacMicrophoneModeObservation.Mode,
        active: MacMicrophoneModeObservation.Mode
    ) {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard self?.session?.isRunning == true else {
                    continuation.resume(returning: (.unknown, .unknown))
                    return
                }
                continuation.resume(
                    returning: (
                        Self.mode(from: AVCaptureDevice.preferredMicrophoneMode),
                        Self.mode(from: AVCaptureDevice.activeMicrophoneMode)
                    )
                )
            }
        }
    }

    private func stopCapture() async -> Bool {
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: true)
                    return
                }
                dataOutput?.setSampleBufferDelegate(nil, queue: nil)
                let staleSession = session
                session = nil
                dataOutput = nil
                staleSession?.stopRunning()
                continuation.resume(returning: staleSession?.isRunning != true)
            }
        }
    }

    private func startWriter(with sampleBuffer: CMSampleBuffer) throws {
        guard let url = temporaryURL,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                  formatDescription
              )?.pointee
        else {
            throw ProbeError.writerDidNotStart
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: basicDescription.mSampleRate,
            AVNumberOfChannelsKey: Int(basicDescription.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        guard writer.canApply(outputSettings: outputSettings, forMediaType: .audio) else {
            throw ProbeError.writerCannotAcceptSettings
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: outputSettings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw ProbeError.writerCannotAddInput }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? ProbeError.writerDidNotStart
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard Self.makeProbeFilePrivate(at: url) else {
            writer.cancelWriting()
            throw ProbeError.fileProtectionFailed
        }
        self.writer = writer
        writerInput = input
    }

    private func finishWriting() async -> WriterReceipt {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: WriterReceipt(completed: false, failure: nil))
                    return
                }
                acceptingSamples = false
                guard let writer, let writerInput else {
                    let snapshot = sampleMetrics()
                    continuation.resume(
                        returning: WriterReceipt(
                            completed: false,
                            failure: snapshot.writerFailure
                        )
                    )
                    return
                }
                guard writer.status == .writing else {
                    let failure = Self.fingerprint(writer.error ?? ProbeError.writerDidNotStart)
                    writer.cancelWriting()
                    self.writer = nil
                    self.writerInput = nil
                    continuation.resume(returning: WriterReceipt(completed: false, failure: failure))
                    return
                }
                writerInput.markAsFinished()
                writer.finishWriting { [weak self] in
                    guard let self else {
                        continuation.resume(
                            returning: WriterReceipt(completed: false, failure: nil)
                        )
                        return
                    }
                    sampleQueue.async { [weak self] in
                        guard let self else {
                            continuation.resume(
                                returning: WriterReceipt(completed: false, failure: nil)
                            )
                            return
                        }
                        let completed = self.writer?.status == .completed
                        let failure = completed
                            ? nil
                            : Self.fingerprint(
                                self.writer?.error ?? ProbeError.writerDidNotStart
                            )
                        self.writer = nil
                        self.writerInput = nil
                        continuation.resume(
                            returning: WriterReceipt(completed: completed, failure: failure)
                        )
                    }
                }
            }
        }
    }

    private func cancelWriting() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                acceptingSamples = false
                writerInput = nil
                writer?.cancelWriting()
                writer = nil
                continuation.resume()
            }
        }
    }

    private func sampleMetrics() -> SampleMetrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return metrics
    }

    private func recordWriterFailure(_ error: Error) {
        metricsLock.lock()
        metrics.writerFailure = metrics.writerFailure ?? Self.fingerprint(error)
        metricsLock.unlock()
    }

    private func failureResult(
        startedAt: Date,
        error: Error,
        released: Bool
    ) -> MacVoiceIsolationProbeResult {
        let snapshot = sampleMetrics()
        let fingerprint = Self.fingerprint(error)
        let status: MacVoiceIsolationProbeResult.Status = error is CancellationError
            ? .cancelled
            : .failed
        return MacVoiceIsolationProbeResult(
            startedAt: startedAt,
            completedAt: Date(),
            status: status,
            preferredMode: .unknown,
            activeMode: .unknown,
            sampleBufferCount: snapshot.receivedBufferCount,
            peakLevel: Double(snapshot.peakLevel),
            playableDurationSeconds: nil,
            fileByteCount: 0,
            releaseConfirmed: released,
            failureDomain: fingerprint.domain,
            failureCode: fingerprint.code
        )
    }

    private static func mode(
        from mode: AVCaptureDevice.MicrophoneMode
    ) -> MacMicrophoneModeObservation.Mode {
        switch mode {
        case .standard: .standard
        case .wideSpectrum: .wideSpectrum
        case .voiceIsolation: .voiceIsolation
        @unknown default: .unknown
        }
    }

    private static func fingerprint(_ error: Error) -> FailureFingerprint {
        if let probeError = error as? ProbeError {
            return FailureFingerprint(domain: .probe, code: probeError.rawValue)
        }
        let error = error as NSError
        let domain: MacVoiceIsolationProbeResult.FailureDomain
        switch error.domain {
        case AVFoundationErrorDomain:
            domain = .avFoundation
        case NSOSStatusErrorDomain:
            domain = .osStatus
        case NSCocoaErrorDomain:
            domain = .cocoa
        default:
            domain = .unknown
        }
        return FailureFingerprint(domain: domain, code: error.code)
    }

    private static func logCompletion(_ result: MacVoiceIsolationProbeResult) {
        logger.notice(
            "route=\(result.route.rawValue, privacy: .public) status=\(result.status.rawValue, privacy: .public) selected=\(result.preferredMode.rawValue, privacy: .public) active=\(result.activeMode.rawValue, privacy: .public) buffers=\(result.sampleBufferCount, privacy: .public) peak=\(result.peakLevel, privacy: .public) playableSeconds=\(result.playableDurationSeconds ?? 0, privacy: .public) released=\(result.releaseConfirmed, privacy: .public)"
        )
    }

    private static func validateAudioFile(at url: URL) -> FileValidation? {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let byteCount = values.fileSize,
            byteCount > 44,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer { try? handle.close() }
        guard
            let header = try? handle.read(upToCount: 12),
            header.count == 12,
            Array(header.prefix(4)) == Array("RIFF".utf8),
            Array(header.dropFirst(8).prefix(4)) == Array("WAVE".utf8),
            let audioFile = try? AVAudioFile(forReading: url),
            audioFile.fileFormat.sampleRate > 0,
            audioFile.length > 0
        else {
            return nil
        }
        let duration = Double(audioFile.length) / audioFile.fileFormat.sampleRate
        guard duration.isFinite, duration > 0 else { return nil }
        return FileValidation(duration: duration, byteCount: Int64(byteCount))
    }

    private nonisolated static func peakAmplitude(of sampleBuffer: CMSampleBuffer) -> Float {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                  formatDescription
              )
        else {
            return 0
        }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList()
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return 0 }

        let format = basicDescription.pointee
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(&audioBufferList) {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else { continue }
            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                let samples = data.bindMemory(to: Float.self, capacity: count)
                for index in 0..<count { peak = max(peak, abs(samples[index])) }
            } else if format.mBitsPerChannel == 16 {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                let samples = data.bindMemory(to: Int16.self, capacity: count)
                for index in 0..<count {
                    peak = max(peak, abs(Float(samples[index]) / Float(Int16.max)))
                }
            }
        }
        return peak
    }

    private static func makeProbeFilePrivate(at url: URL) -> Bool {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1,
              Darwin.fchmod(descriptor, mode_t(0o600)) == 0
        else {
            return false
        }
        return true
    }

    private static func removePrivateProbeFile(at url: URL) throws {
        guard url.lastPathComponent.hasPrefix("ElevenLabs-probe-"),
              url.pathExtension == "wav"
        else {
            return
        }
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == getuid(),
              metadata.st_nlink == 1
        else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
