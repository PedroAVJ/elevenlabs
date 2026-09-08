@preconcurrency import AVFoundation
import AudioToolbox
import Darwin
import Foundation
import OSLog

enum MacSoundIsolationStatus: Sendable {
    case notRequested
    case applied
    case failed(String)
}

private enum MacSoundIsolationError: LocalizedError {
    case instantiateReturnedNoUnit
    case parameter(name: String, status: OSStatus)
    case couldNotCreatePrivateOutput
    case renderStoppedProducingOutput
    case renderFailed
    case unknownRenderStatus
    case invalidOutput
    case replaceFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .instantiateReturnedNoUnit:
            "Apple Sound Isolation loaded without an audio effect instance."
        case let .parameter(name, status):
            "Apple Sound Isolation could not set \(name) (OSStatus \(status))."
        case .couldNotCreatePrivateOutput:
            "Dictation Button could not create a private Sound Isolation output file."
        case .renderStoppedProducingOutput:
            "Apple Sound Isolation stopped producing audio."
        case .renderFailed:
            "Apple Sound Isolation could not render this recording."
        case .unknownRenderStatus:
            "Apple Sound Isolation returned an unknown render status."
        case .invalidOutput:
            "Apple Sound Isolation produced an invalid audio file."
        case let .replaceFailed(code):
            "Dictation Button could not atomically preserve the isolated recording (errno \(code))."
        }
    }
}

private struct MacSoundIsolationRenderReport {
    let inputFrames: AVAudioFramePosition
    let outputFrames: AVAudioFramePosition
    let sampleRate: Double
    let latency: TimeInterval
    let tailTime: TimeInterval
    let model: String
}

/// Applies Apple's public AUSoundIsolation effect after exact-device iPhone
/// capture and before ElevenLabs. The capture WAV remains the recovery source
/// of truth until a complete, private isolated WAV has been rendered. The
/// final rename replaces that WAV atomically, so a process exit can leave the
/// raw recording or the complete isolated recording, never an unowned gap.
enum MacSoundIsolationProcessor {
    private static let logger = Logger(
        subsystem: "com.pedro.ElevenLabsMac",
        category: "SoundIsolation"
    )
    private static let maximumFrameCount: AVAudioFrameCount = 4_096
    private static let maximumConsecutiveEmptyRenders = 100

    static func processRecording(at inputURL: URL) async throws {
        let startedAt = Date()
        let inputBytes = fileSize(at: inputURL)
        Self.logger.notice(
            "event=processing_started effect=appleAUSoundIsolation inputBytes=\(inputBytes, privacy: .public)"
        )

        let effect = try await instantiateEffect()
        let model = try configure(effect)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ElevenLabs-import-\(UUID().uuidString)")
            .appendingPathExtension("wav")
        try? FileManager.default.removeItem(at: outputURL)
        defer { try? FileManager.default.removeItem(at: outputURL) }

        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ), MacActiveCaptureRecovery.makeImportedFilePrivate(at: outputURL) else {
            throw MacSoundIsolationError.couldNotCreatePrivateOutput
        }

        let report = try render(
            inputURL: inputURL,
            outputURL: outputURL,
            effect: effect,
            model: model
        )
        guard isPlausibleWAV(at: outputURL),
              MacActiveCaptureRecovery.makeImportedFilePrivate(at: outputURL)
        else {
            throw MacSoundIsolationError.invalidOutput
        }

        let renameStatus = outputURL.path.withCString { sourcePath in
            inputURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard renameStatus == 0 else {
            throw MacSoundIsolationError.replaceFailed(errno)
        }
        guard MacActiveCaptureRecovery.makeRecordingPrivate(at: inputURL) else {
            throw MacSoundIsolationError.couldNotCreatePrivateOutput
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let outputBytes = fileSize(at: inputURL)
        Self.logger.notice(
            "event=processing_finished effect=appleAUSoundIsolation applied=true model=\(report.model, privacy: .public) inputFrames=\(report.inputFrames, privacy: .public) outputFrames=\(report.outputFrames, privacy: .public) sampleRate=\(report.sampleRate, privacy: .public) latency=\(report.latency, privacy: .public) tail=\(report.tailTime, privacy: .public) inputBytes=\(inputBytes, privacy: .public) outputBytes=\(outputBytes, privacy: .public) elapsed=\(elapsed, privacy: .public)"
        )
    }

    static func logFailure(_ error: Error) {
        Self.logger.error(
            "event=processing_finished effect=appleAUSoundIsolation applied=false fallback=raw error=\(error.localizedDescription, privacy: .public)"
        )
    }

    private static func instantiateEffect() async throws -> AVAudioUnit {
        let description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        return try await withCheckedThrowingContinuation { continuation in
            AVAudioUnit.instantiate(with: description, options: .loadInProcess) { unit, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let unit {
                    continuation.resume(returning: unit)
                } else {
                    continuation.resume(
                        throwing: MacSoundIsolationError.instantiateReturnedNoUnit
                    )
                }
            }
        }
    }

    private static func configure(_ effect: AVAudioUnit) throws -> String {
        effect.auAudioUnit.shouldBypassEffect = false
        let mixStatus = AudioUnitSetParameter(
            effect.audioUnit,
            kAUSoundIsolationParam_WetDryMixPercent,
            kAudioUnitScope_Global,
            0,
            100,
            0
        )
        guard mixStatus == noErr else {
            throw MacSoundIsolationError.parameter(name: "wet/dry mix", status: mixStatus)
        }

        let soundType: AudioUnitParameterValue
        let model: String
        if #available(macOS 15.0, *) {
            soundType = AudioUnitParameterValue(
                kAUSoundIsolationSoundType_HighQualityVoice
            )
            model = "highQualityVoice"
        } else {
            soundType = AudioUnitParameterValue(kAUSoundIsolationSoundType_Voice)
            model = "voice"
        }
        let voiceStatus = AudioUnitSetParameter(
            effect.audioUnit,
            kAUSoundIsolationParam_SoundToIsolate,
            kAudioUnitScope_Global,
            0,
            soundType,
            0
        )
        guard voiceStatus == noErr else {
            throw MacSoundIsolationError.parameter(
                name: "sound to isolate",
                status: voiceStatus
            )
        }
        return model
    }

    private static func render(
        inputURL: URL,
        outputURL: URL,
        effect: AVAudioUnit,
        model: String
    ) throws -> MacSoundIsolationRenderReport {
        let inputFile = try AVAudioFile(forReading: inputURL)
        let inputFormat = inputFile.processingFormat
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: inputFormat)
        engine.connect(effect, to: engine.mainMixerNode, format: inputFormat)
        try engine.enableManualRenderingMode(
            .offline,
            format: inputFormat,
            maximumFrameCount: maximumFrameCount
        )

        let renderingFormat = engine.manualRenderingFormat
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: renderingFormat.sampleRate,
                AVNumberOfChannelsKey: Int(renderingFormat.channelCount),
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        player.scheduleFile(
            inputFile,
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { _ in }
        try engine.start()
        player.play()
        defer {
            player.stop()
            engine.stop()
        }

        let latency = effect.auAudioUnit.latency
        let tailTime = effect.auAudioUnit.tailTime
        let extraFrames = AVAudioFramePosition(
            ceil((latency + tailTime) * renderingFormat.sampleRate)
        )
        let targetFrames = inputFile.length + max(0, extraFrames)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: renderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw MacSoundIsolationError.renderFailed
        }
        var consecutiveEmptyRenders = 0

        while engine.manualRenderingSampleTime < targetFrames {
            let remaining = targetFrames - engine.manualRenderingSampleTime
            let requestedFrames = min(
                maximumFrameCount,
                AVAudioFrameCount(remaining)
            )
            let status = try engine.renderOffline(requestedFrames, to: buffer)
            switch status {
            case .success:
                consecutiveEmptyRenders = 0
                try outputFile.write(from: buffer)
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                consecutiveEmptyRenders += 1
                guard consecutiveEmptyRenders < maximumConsecutiveEmptyRenders else {
                    throw MacSoundIsolationError.renderStoppedProducingOutput
                }
            case .error:
                throw MacSoundIsolationError.renderFailed
            @unknown default:
                throw MacSoundIsolationError.unknownRenderStatus
            }
        }

        return MacSoundIsolationRenderReport(
            inputFrames: inputFile.length,
            outputFrames: outputFile.length,
            sampleRate: renderingFormat.sampleRate,
            latency: latency,
            tailTime: tailTime,
            model: model
        )
    }

    private static func fileSize(at url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func isPlausibleWAV(at url: URL) -> Bool {
        guard fileSize(at: url) > 44,
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
}
