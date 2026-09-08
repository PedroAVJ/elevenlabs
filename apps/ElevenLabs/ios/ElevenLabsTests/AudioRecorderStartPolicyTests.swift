import XCTest
#if os(iOS)
import AVFoundation
#endif
#if SWIFT_PACKAGE
@testable import ElevenLabsClient
#else
@testable import ElevenLabs
#endif

final class AudioRecorderStartPolicyTests: XCTestCase {
    func testStandardSessionMixesWithMediaForHeadlessBackgroundActivation() {
        let policy = AudioRecorderSessionPolicy.standard

        XCTAssertEqual(
            policy.primaryConfiguration,
            .mediaPreservingPlayAndRecord
        )
        XCTAssertTrue(policy.mixesWithOthers)
        XCTAssertFalse(policy.ducksOthers)
        XCTAssertTrue(policy.allowsBluetoothA2DPOutput)
        XCTAssertTrue(policy.usesConditionalBuiltInSpeakerFallback)
    }

    func testSpeakerFallbackAppliesOnlyToBuiltInReceiver() {
        XCTAssertTrue(
            AudioRecorderOutputRoutePolicy.shouldApplySpeakerFallback(
                to: .receiver
            )
        )
        XCTAssertFalse(
            AudioRecorderOutputRoutePolicy.shouldApplySpeakerFallback(
                to: .speaker
            )
        )
        XCTAssertFalse(
            AudioRecorderOutputRoutePolicy.shouldApplySpeakerFallback(
                to: .external
            )
        )
        XCTAssertFalse(
            AudioRecorderOutputRoutePolicy.shouldApplySpeakerFallback(
                to: .none
            )
        )
    }

    func testStaleBuiltInPreferenceRepairsAMissingLiveInputRoute() {
        XCTAssertTrue(
            AudioRecorderInputRoutePolicy.shouldSetPreferredBuiltInInput(
                preferredInputIsBuiltIn: true,
                currentInputIsBuiltIn: false,
                forceReassertion: false
            )
        )
    }

    func testHealthyBuiltInRouteDoesNotChurnItsPreference() {
        XCTAssertFalse(
            AudioRecorderInputRoutePolicy.shouldSetPreferredBuiltInInput(
                preferredInputIsBuiltIn: true,
                currentInputIsBuiltIn: true,
                forceReassertion: false
            )
        )
    }

    func testRecorderRetryCanForceRouteReassertionBeforeSettling() {
        XCTAssertTrue(
            AudioRecorderInputRoutePolicy.shouldSetPreferredBuiltInInput(
                preferredInputIsBuiltIn: true,
                currentInputIsBuiltIn: true,
                forceReassertion: true
            )
        )
    }

    func testBackgroundCannotStartRecordingContinuesInForeground() {
        XCTAssertEqual(
            AudioCaptureStartFailurePolicy.decision(
                failure: .cannotStartRecording,
                applicationState: .background,
                failedAttempt: 0,
                retryPolicy: .standard
            ),
            .continueInForeground
        )
    }

    func testEveryBackgroundPolicyRefusalContinuesInForeground() {
        let policyFailures: [AudioCaptureStartSystemFailure] = [
            .cannotInterruptOthers,
            .cannotStartPlaying,
            .cannotStartRecording,
            .insufficientPriority,
            .unspecified,
        ]

        for failure in policyFailures {
            XCTAssertEqual(
                AudioCaptureStartFailurePolicy.decision(
                    failure: failure,
                    applicationState: .background,
                    failedAttempt: 0,
                    retryPolicy: .standard
                ),
                .continueInForeground
            )
        }
    }

    func testForegroundPolicyRefusalFailsInsteadOfLooping() {
        let policyFailures: [AudioCaptureStartSystemFailure] = [
            .cannotInterruptOthers,
            .cannotStartPlaying,
            .cannotStartRecording,
            .insufficientPriority,
            .unspecified,
        ]

        for failure in policyFailures {
            XCTAssertEqual(
                AudioCaptureStartFailurePolicy.decision(
                    failure: failure,
                    applicationState: .active,
                    failedAttempt: 0,
                    retryPolicy: .standard
                ),
                .fail
            )
        }
    }

    func testInactivePolicyRefusalContinuesToForeground() {
        XCTAssertEqual(
            AudioCaptureStartFailurePolicy.decision(
                failure: .cannotStartRecording,
                applicationState: .inactive,
                failedAttempt: 0,
                retryPolicy: .standard
            ),
            .continueInForeground
        )
    }

    func testOnlySessionNotActiveGetsOneShortRepair() {
        let policy = AudioRecorderStartRetryPolicy.standard
        XCTAssertEqual(policy.retryDelaysMilliseconds, [250])
        XCTAssertEqual(
            AudioCaptureStartFailurePolicy.decision(
                failure: .sessionNotActive,
                applicationState: .background,
                failedAttempt: 0,
                retryPolicy: policy
            ),
            .repairRouteKeepingSessionActive(afterMilliseconds: 250)
        )
        XCTAssertEqual(
            AudioCaptureStartFailurePolicy.decision(
                failure: .sessionNotActive,
                applicationState: .background,
                failedAttempt: 1,
                retryPolicy: policy
            ),
            .fail
        )
    }

    func testUnknownFailureIsNotRetried() {
        XCTAssertEqual(
            AudioCaptureStartFailurePolicy.decision(
                failure: .unknownCode,
                applicationState: .background,
                failedAttempt: 0,
                retryPolicy: .standard
            ),
            .fail
        )
    }

    #if os(iOS)
    func testEveryCurrentAppleStartErrorMapsToAnOwnedCase() {
        let cases: [(AVAudioSession.ErrorCode, AudioCaptureStartSystemFailure)] = [
            (.none, .noError),
            (.mediaServicesFailed, .mediaServicesFailed),
            (.isBusy, .busy),
            (.incompatibleCategory, .incompatibleCategory),
            (.cannotInterruptOthers, .cannotInterruptOthers),
            (.missingEntitlement, .missingEntitlement),
            (.siriIsRecording, .siriIsRecording),
            (.cannotStartPlaying, .cannotStartPlaying),
            (.cannotStartRecording, .cannotStartRecording),
            (.badParam, .badParameter),
            (.insufficientPriority, .insufficientPriority),
            (.resourceNotAvailable, .resourceNotAvailable),
            (.unspecified, .unspecified),
            (.expiredSession, .expiredSession),
            (.sessionNotActive, .sessionNotActive),
        ]

        for (appleCode, expectedFailure) in cases {
            let mapped = AudioCaptureStartErrorAdapter.translate(
                NSError(
                    domain: "com.apple.coreaudio.avfaudio",
                    code: Int(appleCode.rawValue)
                )
            )
            XCTAssertEqual(mapped.failure, expectedFailure)
            XCTAssertEqual(mapped.diagnostic.domain, .avfaudio)
            XCTAssertEqual(mapped.diagnostic.code, Int(appleCode.rawValue))
        }
    }

    func testAppleUnspecifiedCodeMatchesTypedContract() {
        XCTAssertEqual(
            AVAudioSession.ErrorCode.unspecified.rawValue,
            2_003_329_396
        )
    }

    func testMatchingRawCodeFromAnotherDomainStaysUnknown() {
        let mapped = AudioCaptureStartErrorAdapter.translate(
            NSError(
                domain: NSCocoaErrorDomain,
                code: Int(AVAudioSession.ErrorCode.unspecified.rawValue)
            )
        )

        XCTAssertEqual(mapped.failure, .unknownCode)
        XCTAssertEqual(mapped.diagnostic.domain, .cocoa)
    }
    #endif

    #if !SWIFT_PACKAGE
    func testForegroundFailureTelemetryPreservesAppleError() {
        let systemError = AudioCaptureStartError(
            failure: .cannotStartRecording,
            diagnostic: AudioSystemDiagnostic(
                domain: .osStatus,
                code: Int(AVAudioSession.ErrorCode.cannotStartRecording.rawValue)
            )
        )
        let descriptor = AudioRecorderFailureDescriptor(
            error: AudioRecorderError.foregroundRequired(systemError)
        )

        XCTAssertEqual(descriptor.reason, "foreground_required")
        XCTAssertEqual(descriptor.stage, "audio_engine_start")
        XCTAssertEqual(descriptor.issueCode, 1006)
        XCTAssertEqual(descriptor.systemDomain, "os_status")
        XCTAssertEqual(descriptor.systemCode, 561_145_187)
    }

    func testTypedUnspecifiedFailurePreservesExactTelemetry() {
        let descriptor = AudioRecorderFailureDescriptor(
            error: .captureStartFailed(
                AudioCaptureStartError(
                    failure: .unspecified,
                    diagnostic: AudioSystemDiagnostic(
                        domain: .avfaudio,
                        code: 2_003_329_396
                    )
                )
            )
        )

        XCTAssertEqual(descriptor.reason, "unspecified")
        XCTAssertEqual(descriptor.stage, "audio_engine_start")
        XCTAssertEqual(descriptor.systemDomain, "avfaudio")
        XCTAssertEqual(descriptor.systemCode, 2_003_329_396)
    }
    #endif

    func testNegativeDelaysAreNormalized() {
        let policy = AudioRecorderStartRetryPolicy(
            retryDelaysMilliseconds: [-10, 25]
        )

        XCTAssertEqual(policy.retryDelaysMilliseconds, [0, 25])
        XCTAssertEqual(policy.maximumAttempts, 3)
        XCTAssertEqual(
            policy.action(
                afterFailedAttempt: 1
            ),
            .repairRouteKeepingSessionActive(afterMilliseconds: 25)
        )
    }

    func testAudioSessionReleaseRetryIsShortAndBounded() {
        let policy = AudioSessionReleaseRetryPolicy.standard

        XCTAssertEqual(policy.retryDelaysMilliseconds, [120, 360, 720])
        XCTAssertEqual(policy.maximumAttempts, 4)
        XCTAssertNil(policy.delayMilliseconds(afterFailedAttempt: 3))
    }

    func testQualityTrackerClassifiesSilenceWithoutInventingEnergy() {
        var tracker = AudioCaptureQualityTracker()
        for _ in 0..<20 {
            tracker.observe(
                normalizedLevel: 0,
                averagePowerDecibels: -80,
                peakPowerDecibels: -75
            )
        }

        XCTAssertEqual(tracker.summary.classification, .mostlySilent)
        XCTAssertEqual(tracker.summary.audibleFractionBucket, "none")
        XCTAssertEqual(tracker.summary.peakLevelBucket, "silent")
    }

    func testQualityTrackerClassifiesHealthySpeech() {
        var tracker = AudioCaptureQualityTracker()
        for _ in 0..<20 {
            tracker.observe(
                normalizedLevel: 0.24,
                averagePowerDecibels: -24,
                peakPowerDecibels: -8
            )
        }

        XCTAssertEqual(tracker.summary.classification, .healthy)
        XCTAssertEqual(tracker.summary.audibleFractionBucket, "high")
        XCTAssertEqual(tracker.summary.peakLevelBucket, "speech")
    }

    func testQualityTrackerSurfacesClippingRisk() {
        var tracker = AudioCaptureQualityTracker()
        for index in 0..<20 {
            tracker.observe(
                normalizedLevel: index == 0 ? 0.95 : 0.32,
                averagePowerDecibels: -18,
                peakPowerDecibels: index == 0 ? -0.5 : -4
            )
        }

        XCTAssertEqual(tracker.summary.classification, .clippingRisk)
        XCTAssertEqual(tracker.summary.peakLevelBucket, "near_clipping")
    }

    func testVoiceMeterEnvelopeTracksSpeechCadenceWithAttackAndRelease() {
        var envelope = VoiceMeterEnvelope(sampleCount: 5)

        let quiet = envelope.observe(averageLevel: 0.02, peakLevel: 0.04)
        let spoken = envelope.observe(averageLevel: 0.45, peakLevel: 0.9)
        let release = envelope.observe(averageLevel: 0.02, peakLevel: 0.03)

        XCTAssertEqual(spoken.count, 5)
        XCTAssertGreaterThan(spoken.last ?? 0, quiet.last ?? 0)
        XCTAssertLessThan(release.last ?? 0, spoken.last ?? 0)
        XCTAssertGreaterThan(release.last ?? 0, 0.02)
        XCTAssertTrue(release.allSatisfy { 0...1 ~= $0 })

        envelope.reset()
        XCTAssertEqual(envelope.levels, Array(repeating: 0, count: 5))
    }

    func testSessionDurationCarriesAccumulatedTimeIntoLiveContinuation() {
        XCTAssertEqual(
            SessionElapsedDurationPolicy.total(
                accumulatedDuration: 12,
                liveRecorderDuration: 3,
                finalizedSegmentDuration: 0,
                isRecording: true,
                hasActiveRecordingReference: true
            ),
            15
        )
    }

    func testSessionDurationCountsUnbankedPausedSegmentExactlyOnce() {
        XCTAssertEqual(
            SessionElapsedDurationPolicy.total(
                accumulatedDuration: 12,
                liveRecorderDuration: 3,
                finalizedSegmentDuration: 3,
                isRecording: false,
                hasActiveRecordingReference: true
            ),
            15
        )
    }

    func testSessionDurationIgnoresStoppedRecorderAfterSegmentIsBanked() {
        XCTAssertEqual(
            SessionElapsedDurationPolicy.total(
                accumulatedDuration: 15,
                liveRecorderDuration: 3,
                finalizedSegmentDuration: 0,
                isRecording: false,
                hasActiveRecordingReference: false
            ),
            15
        )
    }
}
