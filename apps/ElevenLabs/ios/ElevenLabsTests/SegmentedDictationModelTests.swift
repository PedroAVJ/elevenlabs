import XCTest
#if ELEVENLABS_SWIFT_PACKAGE
@testable import ElevenLabsClient
#else
@testable import ElevenLabs
#endif

final class SegmentedDictationModelTests: XCTestCase {
    func testToggleUsesStateToChooseStartPauseAndResume() {
        XCTAssertEqual(
            SegmentedDictationCaptureState.idle.toggleAction,
            .start
        )
        XCTAssertEqual(
            SegmentedDictationCaptureState.recording.toggleAction,
            .pause
        )
        XCTAssertEqual(
            SegmentedDictationCaptureState.paused.toggleAction,
            .resume
        )
        for transitionalState in [
            SegmentedDictationCaptureState.starting,
            .recoveringSilentCapture,
            .pausing,
            .resuming,
            .closing,
        ] {
            XCTAssertEqual(transitionalState.toggleAction, .none)
        }
    }

    func testTranscriptAssemblyUsesSpokenOrderNotCompletionOrder() throws {
        let result = try XCTUnwrap(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 2,
                    text: " third. ",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "First,",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 1,
                    text: "second",
                    languageCode: "en"
                ),
            ])
        )

        XCTAssertEqual(result.text, "First, second third.")
        XCTAssertEqual(result.languageCode, "en")
    }

    func testTranscriptAssemblyDoesNotClaimOneLanguageForMixedSegments() throws {
        let result = try XCTUnwrap(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "Hello.",
                    languageCode: "en"
                ),
                SegmentedTranscriptPiece(
                    ordinal: 1,
                    text: "Hola.",
                    languageCode: "es"
                ),
            ])
        )

        XCTAssertEqual(result.text, "Hello. Hola.")
        XCTAssertNil(result.languageCode)
        XCTAssertNil(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 0,
                    text: "  \n ",
                    languageCode: nil
                ),
            ])
        )
    }

    func testSilentCaptureRecoveryRecyclesOnlyOncePerSession() {
        var policy = SegmentedNoAudioRecoveryPolicy()

        XCTAssertEqual(
            policy.action(for: .recording),
            .recycleCapture
        )
        XCTAssertEqual(
            policy.action(for: .recording),
            .reportPersistentSilence
        )
    }

    func testSilentCaptureRecoveryIgnoresSignalsOutsideActiveRecording() {
        var policy = SegmentedNoAudioRecoveryPolicy()

        XCTAssertEqual(policy.action(for: .starting), .ignore)
        XCTAssertEqual(policy.action(for: .paused), .ignore)
        XCTAssertEqual(policy.action(for: .closing), .ignore)
        XCTAssertEqual(policy.action(for: .recording), .recycleCapture)
    }

    func testEmptySegmentFailureDoesNotPoisonValidSegmentAssembly() throws {
        XCTAssertTrue(
            SegmentedTranscriptFailurePolicy.canSkipSegment(
                ElevenLabsClientError.emptyTranscript
            )
        )
        XCTAssertFalse(
            SegmentedTranscriptFailurePolicy.canSkipSegment(
                ElevenLabsClientError.api(
                    statusCode: 503,
                    message: "not retained by observability"
                )
            )
        )

        let result = try XCTUnwrap(
            SegmentedTranscriptAssembler.assemble([
                SegmentedTranscriptPiece(
                    ordinal: 1,
                    text: "The recovered microphone works.",
                    languageCode: "en"
                ),
            ])
        )
        XCTAssertEqual(result.text, "The recovered microphone works.")
    }
}
