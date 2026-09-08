@preconcurrency import AVFoundation
import Foundation
import OSLog

private final class MacSingleOutputSampleFlow: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount: UInt64 = 0
    private var storedPeak: Float = 0

    func reset() {
        lock.lock()
        storedCount = 0
        storedPeak = 0
        lock.unlock()
    }

    func record(peak: Float) {
        lock.lock()
        storedCount &+= 1
        storedPeak = min(max(peak, 0), 1)
        lock.unlock()
    }

    var count: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    var normalizedLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(storedPeak)
    }
}

/// Exact-device Continuity capture with one AVCaptureAudioDataOutput. The
/// system Mic Mode remains user-owned; this route removes the file-output
/// branch that made macOS keep Standard active, then writes those same sample
/// buffers directly into a private WAV used by the normal transcription path.
final class MacSingleOutputAudioRecorder: NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let logger = Logger(
        subsystem: "com.pedro.ElevenLabsMac",
        category: "VoiceIsolationCapture"
    )

    private let captureQueue = DispatchQueue(
        label: "com.pedro.ElevenLabs.single-output.capture",
        qos: .userInitiated
    )
    private let sampleQueue = DispatchQueue(
        label: "com.pedro.ElevenLabs.single-output.samples",
        qos: .userInitiated
    )
    private let sampleFlow = MacSingleOutputSampleFlow()

    // captureQueue-owned state.
    private var session: AVCaptureSession?
    private var output: AVCaptureAudioDataOutput?
    private var activeDeviceID: String?
    private var sessionGeneration: UInt64 = 0
    private var runtimeErrorObserver: NSObjectProtocol?
    private var runtimeError: NSError?
    private var recordingFailureHandler: (@Sendable (Error, URL?) -> Void)?

    // sampleQueue-owned state.
    private var segmentURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var acceptingSamples = false
    private var segmentDidStart = false
    private var isStopping = false
    private var startContinuation: CheckedContinuation<URL, Error>?
    private var stopContinuation: CheckedContinuation<MacRecordedSegment, Error>?
    private var startTimeoutWorkItem: DispatchWorkItem?
    private var finalizationTimeoutWorkItem: DispatchWorkItem?
    private let recordingStartTimeout: TimeInterval = 8
    private let finalizationTimeout: TimeInterval = 8
    private let steadyAudioTimeout: TimeInterval = 15
    private static let requiredSteadyWindows = 6

    func setRecordingFailureHandler(_ handler: @escaping @Sendable (Error, URL?) -> Void) {
        captureQueue.async { [weak self] in
            self?.recordingFailureHandler = handler
        }
    }

    var normalizedLevel: Double { sampleFlow.normalizedLevel }
    var deliveredSampleCount: UInt64 { sampleFlow.count }

    func microphoneModeObservation(
        source: MacMicrophoneModeObservation.Source
    ) -> MacMicrophoneModeObservation? {
        captureQueue.sync {
            guard session?.isRunning == true, activeDeviceID != nil else { return nil }
            return MacMicrophoneModeObservation(
                observedAt: Date(),
                source: source,
                preferred: Self.mode(from: AVCaptureDevice.preferredMicrophoneMode),
                active: Self.mode(from: AVCaptureDevice.activeMicrophoneMode)
            )
        }
    }

    func connect(deviceID: String) async throws -> Bool {
        try await ensurePermission()
        try Task.checkCancellation()
        let generation = try await establishSession(deviceID: deviceID)
        do {
            try await waitForSteadyAudio(generation: generation)
        } catch {
            await disconnectAndWait()
            throw error
        }
        return true
    }

    func startSegment() async throws -> URL {
        guard captureQueue.sync(execute: {
            session?.isRunning == true && activeDeviceID != nil && runtimeError == nil
        }) else {
            throw MacAudioRecorderError.connectionFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard
                    segmentURL == nil,
                    writer == nil,
                    startContinuation == nil,
                    stopContinuation == nil,
                    !isStopping
                else {
                    continuation.resume(throwing: MacAudioRecorderError.recorderBusy)
                    return
                }

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ElevenLabs-\(UUID().uuidString)")
                    .appendingPathExtension("wav")
                try? FileManager.default.removeItem(at: url)
                segmentURL = url
                acceptingSamples = true
                segmentDidStart = false
                startContinuation = continuation
                scheduleStartTimeout(url: url)
            }
        }
    }

    func stop() async throws -> MacRecordedSegment {
        try await withCheckedThrowingContinuation { continuation in
            sampleQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                guard
                    let url = segmentURL,
                    segmentDidStart,
                    startContinuation == nil,
                    let writer,
                    let writerInput,
                    writer.status == .writing,
                    stopContinuation == nil,
                    !isStopping
                else {
                    continuation.resume(throwing: MacAudioRecorderError.noActiveRecording)
                    return
                }

                acceptingSamples = false
                isStopping = true
                stopContinuation = continuation
                writerInput.markAsFinished()
                scheduleFinalizationTimeout(url: url)
                writer.finishWriting { [weak self] in
                    self?.sampleQueue.async { [weak self] in
                        self?.finishSegment(url: url)
                    }
                }
            }
        }
    }

    func disconnect() {
        sampleQueue.async { [weak self] in self?.cancelSegment() }
        captureQueue.async { [weak self] in self?.finishSession() }
    }

    func disconnectAndWait() async {
        await withCheckedContinuation { continuation in
            sampleQueue.async { [weak self] in
                self?.cancelSegment()
                continuation.resume()
            }
        }
        await withCheckedContinuation { continuation in
            captureQueue.async { [weak self] in
                self?.finishSession()
                continuation.resume()
            }
        }
    }

    func disconnectSynchronously() {
        sampleQueue.sync { cancelSegment() }
        captureQueue.sync { finishSession() }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let peak = Self.peakAmplitude(of: sampleBuffer)
        sampleFlow.record(peak: peak)
        guard acceptingSamples, let url = segmentURL else { return }

        do {
            if writer == nil {
                try startWriter(at: url, with: sampleBuffer)
            }
            guard let writer, let writerInput, writer.status == .writing else {
                throw writer?.error ?? MacAudioRecorderError.connectionFailed
            }
            guard writerInput.isReadyForMoreMediaData else { return }
            guard writerInput.append(sampleBuffer) else {
                throw writer.error ?? MacAudioRecorderError.connectionFailed
            }
            if let continuation = startContinuation {
                startTimeoutWorkItem?.cancel()
                startTimeoutWorkItem = nil
                startContinuation = nil
                segmentDidStart = true
                let preferred = Self.mode(from: AVCaptureDevice.preferredMicrophoneMode)
                let active = Self.mode(from: AVCaptureDevice.activeMicrophoneMode)
                Self.logger.notice(
                    "event=recording_started route=singleDataOutputAssetWriter selected=\(preferred.rawValue, privacy: .public) active=\(active.rawValue, privacy: .public)"
                )
                continuation.resume(returning: url)
            }
        } catch {
            failSegment(with: error)
        }
    }

    private func ensurePermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else {
                throw MacAudioRecorderError.microphonePermissionDenied
            }
        default:
            throw MacAudioRecorderError.microphonePermissionDenied
        }
    }

    private func establishSession(deviceID: String) async throws -> UInt64 {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<UInt64, Error>) in
            captureQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
                    return
                }
                do {
                    finishSession()
                    guard let device = AVCaptureDevice(uniqueID: deviceID) else {
                        throw MacAudioRecorderError.deviceUnavailable
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: sampleQueue)

                    let session = AVCaptureSession()
                    session.beginConfiguration()
                    guard session.canAddInput(input) else {
                        session.commitConfiguration()
                        throw MacAudioRecorderError.inputCannotBeAdded
                    }
                    session.addInput(input)
                    guard session.canAddOutput(output) else {
                        session.commitConfiguration()
                        throw MacAudioRecorderError.outputCannotBeAdded
                    }
                    session.addOutput(output)
                    session.commitConfiguration()

                    sessionGeneration &+= 1
                    let generation = sessionGeneration
                    runtimeError = nil
                    sampleFlow.reset()
                    runtimeErrorObserver = NotificationCenter.default.addObserver(
                        forName: AVCaptureSession.runtimeErrorNotification,
                        object: session,
                        queue: nil
                    ) { [weak self, weak session] notification in
                        guard
                            let session,
                            let error = notification.userInfo?[AVCaptureSessionErrorKey]
                                as? NSError
                        else { return }
                        self?.captureQueue.async { [weak self, weak session] in
                            guard let self, let session,
                                  self.session === session,
                                  self.sessionGeneration == generation
                            else { return }
                            runtimeError = error
                        }
                    }

                    self.session = session
                    self.output = output
                    activeDeviceID = deviceID
                    session.startRunning()
                    guard session.isRunning, runtimeError == nil else {
                        let error: Error
                        if let runtimeError {
                            error = runtimeError
                        } else {
                            error = MacAudioRecorderError.connectionFailed
                        }
                        finishSession()
                        throw error
                    }
                    Self.logger.notice(
                        "event=session_started route=singleDataOutputAssetWriter"
                    )
                    continuation.resume(returning: generation)
                } catch {
                    finishSession()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func waitForSteadyAudio(generation: UInt64) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(steadyAudioTimeout))
        var lastCount = sampleFlow.count
        var steadyWindows = 0
        while steadyWindows < Self.requiredSteadyWindows {
            try Task.checkCancellation()
            if let error = captureQueue.sync(execute: {
                currentSessionFailure(generation: generation)
            }) {
                throw error
            }
            guard clock.now < deadline else {
                throw MacAudioRecorderError.audioStreamNotReady
            }
            try await Task.sleep(for: .milliseconds(30))
            let count = sampleFlow.count
            steadyWindows = count > lastCount ? steadyWindows + 1 : 0
            lastCount = count
        }
    }

    private func currentSessionFailure(generation: UInt64) -> Error? {
        guard sessionGeneration == generation else {
            return MacAudioRecorderError.connectionFailed
        }
        if let runtimeError { return runtimeError }
        guard session?.isRunning == true else {
            return MacAudioRecorderError.connectionFailed
        }
        return nil
    }

    private func startWriter(at url: URL, with sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
                  formatDescription
              )?.pointee
        else {
            throw MacAudioRecorderError.connectionFailed
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: basicDescription.mSampleRate,
            AVNumberOfChannelsKey: Int(basicDescription.mChannelsPerFrame),
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
            throw MacAudioRecorderError.outputCannotBeAdded
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: formatDescription
        )
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw MacAudioRecorderError.outputCannotBeAdded }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? MacAudioRecorderError.connectionFailed
        }
        writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard MacActiveCaptureRecovery.makeRecordingPrivate(at: url) else {
            writer.cancelWriting()
            throw MacAudioRecorderError.recordingFileProtectionFailed
        }
        self.writer = writer
        writerInput = input
    }

    private func finishSegment(url: URL) {
        finalizationTimeoutWorkItem?.cancel()
        finalizationTimeoutWorkItem = nil
        guard let continuation = stopContinuation else { return }
        let failure = writer?.status == .completed
            ? nil
            : writer?.error ?? MacAudioRecorderError.connectionFailed
        writer = nil
        writerInput = nil
        stopContinuation = nil
        isStopping = false
        segmentURL = nil
        segmentDidStart = false

        if let failure {
            try? FileManager.default.removeItem(at: url)
            releaseSession { continuation.resume(throwing: failure) }
            return
        }
        guard Self.isPlausibleWAV(at: url) else {
            try? FileManager.default.removeItem(at: url)
            releaseSession {
                continuation.resume(throwing: MacAudioRecorderError.connectionFailed)
            }
            return
        }
        let sampleCount = sampleFlow.count
        releaseSession {
            Self.logger.notice(
                "event=recording_finished route=singleDataOutputAssetWriter buffers=\(sampleCount, privacy: .public) released=true"
            )
            Task(priority: .userInitiated) {
                do {
                    try await MacSoundIsolationProcessor.processRecording(at: url)
                    continuation.resume(
                        returning: MacRecordedSegment(
                            url: url,
                            soundIsolationStatus: .applied
                        )
                    )
                } catch {
                    // The raw WAV remains complete and private until the
                    // isolated replacement succeeds atomically. A platform
                    // effect failure must not discard the user's dictation.
                    MacSoundIsolationProcessor.logFailure(error)
                    continuation.resume(
                        returning: MacRecordedSegment(
                            url: url,
                            soundIsolationStatus: .failed(error.localizedDescription)
                        )
                    )
                }
            }
        }
    }

    private func releaseSession(_ completion: @escaping @Sendable () -> Void) {
        captureQueue.async { [weak self] in
            self?.finishSession()
            completion()
        }
    }

    private func scheduleStartTimeout(url: URL) {
        startTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, segmentURL == url, startContinuation != nil else { return }
            failSegment(with: MacAudioRecorderError.recordingStartTimedOut)
        }
        startTimeoutWorkItem = workItem
        sampleQueue.asyncAfter(deadline: .now() + recordingStartTimeout, execute: workItem)
    }

    private func scheduleFinalizationTimeout(url: URL) {
        finalizationTimeoutWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, segmentURL == url, stopContinuation != nil else { return }
            failSegment(with: MacAudioRecorderError.recordingFinalizationTimedOut)
        }
        finalizationTimeoutWorkItem = workItem
        sampleQueue.asyncAfter(deadline: .now() + finalizationTimeout, execute: workItem)
    }

    private func failSegment(with error: Error) {
        let start = startContinuation
        let stop = stopContinuation
        let url = segmentURL
        startTimeoutWorkItem?.cancel()
        finalizationTimeoutWorkItem?.cancel()
        startTimeoutWorkItem = nil
        finalizationTimeoutWorkItem = nil
        acceptingSamples = false
        startContinuation = nil
        stopContinuation = nil
        writerInput = nil
        writer?.cancelWriting()
        writer = nil
        segmentURL = nil
        segmentDidStart = false
        isStopping = false
        if let url { try? FileManager.default.removeItem(at: url) }
        start?.resume(throwing: error)
        stop?.resume(throwing: error)
    }

    private func cancelSegment() {
        failSegment(with: CancellationError())
    }

    private func finishSession() {
        if let runtimeErrorObserver {
            NotificationCenter.default.removeObserver(runtimeErrorObserver)
        }
        runtimeErrorObserver = nil
        let staleOutput = output
        let staleSession = session
        output = nil
        session = nil
        activeDeviceID = nil
        runtimeError = nil
        staleOutput?.setSampleBufferDelegate(nil, queue: nil)
        staleSession?.stopRunning()
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

    private static func isPlausibleWAV(at url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ]
        guard
            let values = try? url.resourceValues(forKeys: keys),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let fileSize = values.fileSize,
            fileSize > 44,
            let handle = try? FileHandle(forReadingFrom: url)
        else {
            return false
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12 else {
            return false
        }
        return Array(header.prefix(4)) == Array("RIFF".utf8)
            && Array(header.dropFirst(8).prefix(4)) == Array("WAVE".utf8)
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
}
