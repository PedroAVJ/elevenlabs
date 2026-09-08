import Foundation
import XCTest
@testable import ElevenLabs

final class MacPasteMenuShortcutTests: XCTestCase {
    func testAcceptsElectronAndNativeCommandVCasing() {
        XCTAssertTrue(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: "V",
                commandModifiers: 0,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: "v",
                commandModifiers: 0,
                isEnabled: true
            )
        )
    }

    func testRejectsPasteAndMatchStyleAndDisabledPaste() {
        XCTAssertFalse(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: "V",
                commandModifiers: 1,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: "V",
                commandModifiers: 0,
                isEnabled: false
            )
        )
    }

    func testRejectsMissingOrUnrelatedAccelerators() {
        XCTAssertFalse(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: nil,
                commandModifiers: 0,
                isEnabled: true
            )
        )
        XCTAssertFalse(
            MacPasteMenuShortcut.isPlainPaste(
                commandCharacter: "C",
                commandModifiers: 0,
                isEnabled: true
            )
        )
    }
}

final class MacDeliveryTargetingTests: XCTestCase {
    func testDeliveryUsesReplacementEditorInsteadOfCapturedNodeIdentity() {
        XCTAssertEqual(
            MacDeliveryTargeting.decide(
                captured: "electron-node-before-dictation",
                current: "electron-node-at-delivery"
            ),
            .focusedApplication("electron-node-at-delivery")
        )
    }

    func testDeliveryRetargetsToCurrentWritableEditorAcrossApplications() {
        XCTAssertEqual(
            MacDeliveryTargeting.decide(
                captured: "source-app-editor",
                current: "current-app-editor"
            ),
            .focusedApplication("current-app-editor")
        )
    }

    func testCurrentApplicationDoesNotRequireAXWritableElement() {
        XCTAssertEqual(
            MacDeliveryTargeting.decide(
                captured: "old-editor",
                current: "electron-app-without-stable-ax-node"
            ),
            .focusedApplication("electron-app-without-stable-ax-node")
        )
    }

    func testMissingCurrentApplicationSelectsClipboardFallback() {
        XCTAssertEqual(
            MacDeliveryTargeting.decide(
                captured: "old-editor",
                current: Optional<String>.none
            ),
            .clipboardFallback
        )
    }

    func testWritableRolesIncludeEditableChromiumAncestors() {
        XCTAssertTrue(
            MacAccessibility.roleAcceptsText(
                "AXTextArea",
                explicitlyEditable: false
            )
        )
        XCTAssertTrue(
            MacAccessibility.roleAcceptsText(
                "AXGroup",
                explicitlyEditable: true
            )
        )
        XCTAssertFalse(
            MacAccessibility.roleAcceptsText(
                "AXButton",
                explicitlyEditable: false
            )
        )
        XCTAssertFalse(
            MacAccessibility.roleAcceptsText(
                "AXSlider",
                explicitlyEditable: false,
                valueIsSettable: true
            )
        )
    }

    func testInvokedMenuActionNeverFallsThroughToAnotherInsertionRoute() {
        XCTAssertTrue(MacPasteMenuActionResult.unavailable.permitsAnotherInsertionRoute)
        XCTAssertFalse(MacPasteMenuActionResult.invoked.permitsAnotherInsertionRoute)
    }
}

final class MacTranscriptPostProcessorRegressionTests: XCTestCase {
    func testLeadingParagraphCommandSurvivesCursorFitting() {
        XCTAssertEqual(
            process("new paragraph hello", after: "First."),
            "\n\nHello"
        )
    }

    func testLeadingLineCommandSurvivesWithoutInventingSentenceCasing() {
        XCTAssertEqual(process("new line hello", after: "first"), "\nhello")
        XCTAssertEqual(process("new line hello"), "\nHello")
    }

    func testTrailingLayoutCommandsSurviveCursorFitting() {
        XCTAssertEqual(process("hello new paragraph", after: "Start:"), " Hello\n\n")
        XCTAssertEqual(process("hello new line", after: "Start:"), " Hello\n")
    }

    func testSpokenDelimitersRemoveOnlyTheirInteriorSpaces() {
        XCTAssertEqual(
            process("say open parenthesis hello close parenthesis now"),
            "Say (hello) now"
        )
        XCTAssertEqual(
            process("say open bracket hello close bracket now"),
            "Say [hello] now"
        )
    }

    func testConfiguredReplacementOwnsExactLeadingCase() {
        XCTAssertEqual(
            process(
                "iphone",
                replacements: [replacement(spoken: "iphone", written: "iPhone")]
            ),
            "iPhone"
        )
        XCTAssertEqual(
            process(
                "dog",
                replacements: [replacement(spoken: "dog", written: "dog")]
            ),
            "dog"
        )
    }

    func testScribeMixedCaseProperNameIsNotDamagedAtSentenceStart() {
        XCTAssertEqual(process("iPhone is ready"), "iPhone is ready")
        XCTAssertEqual(process("macOS is ready", after: "Done."), " macOS is ready")
    }

    func testPreparedChunkDoesNotCollideWithPrecedingWord() {
        let chunk = prepare("Next")

        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(chunk, after: "word"),
            " Next"
        )
    }

    func testPreparedChunkDoesNotAddSpaceAfterWhitespaceNewlineOrOpeningMark() {
        let chunk = prepare("next")

        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word "), "next")
        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word\n"), "next")
        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "("), "next")
    }

    func testPreparedPunctuationAttachesToPrecedingText() {
        let chunk = prepare(", next")

        XCTAssertEqual(MacTranscriptPostProcessor.fit(chunk, after: "word"), ", next")
    }

    func testPreparedChunkUsesSentenceCaseWithoutOverridingReplacementCase() {
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(prepare("next"), after: "Done."),
            " Next"
        )

        let replacementChunk = prepare(
            "iphone",
            replacements: [replacement(spoken: "iphone", written: "iPhone")]
        )
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(replacementChunk, after: "Done."),
            " iPhone"
        )
    }

    func testPreparedChunkFoldCarriesActualTextAcrossThreeFragments() {
        let chunks = ["one", "two.", "three"].map { prepare($0) }

        XCTAssertEqual(
            MacTranscriptPostProcessor.fold(chunks, after: "Draft"),
            " one two. Three"
        )
    }

    func testPreparedChunkCombineClosesOnlyInternalSegmentSeams() {
        let combined = MacTranscriptPostProcessor.combine(
            ["one", "two.", "three"].map { prepare($0) }
        )

        XCTAssertEqual(combined.text, "one two. Three")
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(combined, after: "Draft"),
            " one two. Three"
        )
    }

    func testPreparedChunkCombinePreservesFirstReplacementCasing() {
        let combined = MacTranscriptPostProcessor.combine([
            prepare(
                "iphone",
                replacements: [replacement(spoken: "iphone", written: "iPhone")]
            ),
            prepare("works"),
        ])

        XCTAssertTrue(combined.preservesLeadingReplacementCase)
        XCTAssertEqual(combined.text, "iPhone works")
        XCTAssertEqual(
            MacTranscriptPostProcessor.fit(combined, after: "Done."),
            " iPhone works"
        )
    }

    private func process(
        _ transcript: String,
        replacements: [MacTextReplacement] = [],
        after precedingText: String? = nil
    ) -> String {
        MacTranscriptPostProcessor.apply(
            transcript,
            replacements: replacements,
            precedingText: precedingText
        )
    }

    private func replacement(spoken: String, written: String) -> MacTextReplacement {
        MacTextReplacement(
            spoken: spoken,
            written: written,
            isEnabled: true,
            matchesWholeWordsOnly: true
        )
    }

    private func prepare(
        _ transcript: String,
        replacements: [MacTextReplacement] = []
    ) -> MacPreparedTranscriptChunk {
        MacTranscriptPostProcessor.prepare(
            transcript,
            replacements: replacements
        )
    }
}

final class MacLanguageConfidenceReviewTests: XCTestCase {
    func testLowAutomaticConfidenceNamesKnownDetectedLanguage() {
        XCTAssertEqual(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: "Spanish",
                probability: 0.423
            ),
            "Scribe was only 42% confident that the language was Spanish. Review the text or pin the language in Settings."
        )
    }

    func testLowAutomaticConfidenceStillWarnsWithoutKnownLanguage() {
        XCTAssertEqual(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: nil,
                probability: 0.49
            ),
            "Scribe's automatic language confidence was only 49%. Review the text or pin the language in Settings."
        )
    }

    func testPinnedHighOrInvalidConfidenceDoesNotWarn() {
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: false,
                languageTitle: "Spanish",
                probability: 0.1
            )
        )
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: "Spanish",
                probability: 0.5
            )
        )
        XCTAssertNil(
            MacLanguageConfidenceReview.notice(
                isAutomatic: true,
                languageTitle: nil,
                probability: .nan
            )
        )
    }
}

final class MacDiagnosticsRegressionTests: XCTestCase {
    func testVoiceIsolationReadingConfirmsActiveContinuityProcessing() {
        let observation = MacMicrophoneModeObservation(
            observedAt: Date(timeIntervalSince1970: 1),
            source: .continuity,
            preferred: .voiceIsolation,
            active: .voiceIsolation
        )

        XCTAssertTrue(observation.voiceIsolationIsActive)
        XCTAssertTrue(observation.preferredModeIsActive)
        XCTAssertEqual(
            observation.resultTitle,
            "Voice Isolation active on the iPhone Continuity microphone"
        )
        XCTAssertEqual(
            observation.detailText,
            "Selected Voice Isolation · Active Voice Isolation · observed during live audio"
        )
    }

    func testVoiceIsolationReadingExposesSelectedButInactiveRoute() {
        let observation = MacMicrophoneModeObservation(
            observedAt: Date(timeIntervalSince1970: 1),
            source: .continuity,
            preferred: .voiceIsolation,
            active: .standard
        )

        XCTAssertFalse(observation.voiceIsolationIsActive)
        XCTAssertFalse(observation.preferredModeIsActive)
        XCTAssertEqual(
            observation.resultTitle,
            "Voice Isolation selected, but Standard is active"
        )
    }

    func testMicrophoneModeStorePersistsNewestFirstBoundedRuntimeTrail() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacMicrophoneModeObservationStore(
            applicationSupportDirectory: directory,
            maximumObservations: 2
        )
        let standard = MacMicrophoneModeObservation(
            observedAt: Date(timeIntervalSince1970: 1),
            source: .continuity,
            preferred: .standard,
            active: .standard
        )
        let mismatch = MacMicrophoneModeObservation(
            observedAt: Date(timeIntervalSince1970: 2),
            source: .continuity,
            preferred: .voiceIsolation,
            active: .standard
        )
        let active = MacMicrophoneModeObservation(
            observedAt: Date(timeIntervalSince1970: 3),
            source: .continuity,
            preferred: .voiceIsolation,
            active: .voiceIsolation
        )

        try store.append(standard)
        try store.append(mismatch)
        try store.append(active)

        let reloaded = MacMicrophoneModeObservationStore(
            applicationSupportDirectory: directory,
            maximumObservations: 2
        ).load()
        XCTAssertEqual(reloaded, [active, mismatch])

        let raw = try String(
            contentsOf: directory.appending(path: "microphone-mode-observations.json"),
            encoding: .utf8
        )
        XCTAssertTrue(raw.contains(#""schemaVersion" : 1"#))
        XCTAssertTrue(raw.contains(#""preferred" : "voiceIsolation""#))
        XCTAssertFalse(raw.contains(#""observedAt" : "1970-01-01T00:00:01Z""#))
    }

    func testVoiceIsolationProbeResultExplainsActiveAndInactiveRoutes() {
        let active = voiceIsolationProbeResult(
            startedAt: Date(timeIntervalSince1970: 1),
            status: .voiceIsolationActive,
            preferred: .voiceIsolation,
            active: .voiceIsolation
        )
        XCTAssertEqual(
            active.resultTitle,
            "Confirmed: Voice Isolation is active on the probe route."
        )
        XCTAssertTrue(active.detailText.contains("iPhone released yes"))

        let inactive = voiceIsolationProbeResult(
            startedAt: Date(timeIntervalSince1970: 2),
            status: .selectedButInactive,
            preferred: .voiceIsolation,
            active: .standard
        )
        XCTAssertEqual(
            inactive.resultTitle,
            "Voice Isolation was selected, but macOS kept Standard active."
        )
    }

    func testVoiceIsolationProbeStorePersistsOnlyBoundedSafeResults() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MacVoiceIsolationProbeResultStore(
            applicationSupportDirectory: directory,
            maximumResults: 2
        )
        let first = voiceIsolationProbeResult(
            startedAt: Date(timeIntervalSince1970: 1),
            status: .noSamples,
            preferred: .voiceIsolation,
            active: .unknown
        )
        let second = voiceIsolationProbeResult(
            startedAt: Date(timeIntervalSince1970: 2),
            status: .selectedButInactive,
            preferred: .voiceIsolation,
            active: .standard
        )
        let third = voiceIsolationProbeResult(
            startedAt: Date(timeIntervalSince1970: 3),
            status: .voiceIsolationActive,
            preferred: .voiceIsolation,
            active: .voiceIsolation
        )

        try store.append(first)
        try store.append(second)
        try store.append(third)

        let reloaded = MacVoiceIsolationProbeResultStore(
            applicationSupportDirectory: directory,
            maximumResults: 2
        ).load()
        XCTAssertEqual(reloaded, [third, second])

        let raw = try String(
            contentsOf: directory.appending(path: "voice-isolation-probe-results.json"),
            encoding: .utf8
        )
        XCTAssertTrue(raw.contains(#""route" : "singleDataOutputAssetWriter""#))
        XCTAssertTrue(raw.contains(#""releaseConfirmed" : true"#))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("deviceID"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("filePath"))
        XCTAssertFalse(raw.localizedCaseInsensitiveContains("transcript"))
    }

    func testMicrophoneGainClampsToDocumentedRange() {
        XCTAssertEqual(microphone(gain: 1.7).gain, 1)
        XCTAssertEqual(microphone(gain: -0.4).gain, 0)
        XCTAssertEqual(microphone(gain: 0.45).gain, 0.45)
    }

    func testNonFiniteMicrophoneGainBecomesUnavailable() {
        XCTAssertNil(microphone(gain: .nan).gain)
        XCTAssertNil(microphone(gain: .infinity).gain)
        XCTAssertNil(microphone(gain: -.infinity).gain)
    }

    func testDecodedMicrophoneGainIsClampedToo() throws {
        let data = Data(
            #"{"name":"Microphone","transport":"builtIn","gain":2.5}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            MacDiagnosticsSnapshot.Microphone.self,
            from: data
        )
        XCTAssertEqual(decoded.gain, 1)
    }

    private func microphone(gain: Double?) -> MacDiagnosticsSnapshot.Microphone {
        MacDiagnosticsSnapshot.Microphone(
            transport: .builtIn,
            gain: gain
        )
    }

    private func voiceIsolationProbeResult(
        startedAt: Date,
        status: MacVoiceIsolationProbeResult.Status,
        preferred: MacMicrophoneModeObservation.Mode,
        active: MacMicrophoneModeObservation.Mode
    ) -> MacVoiceIsolationProbeResult {
        MacVoiceIsolationProbeResult(
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(5),
            status: status,
            preferredMode: preferred,
            activeMode: active,
            sampleBufferCount: 100,
            peakLevel: 0.5,
            playableDurationSeconds: 5,
            fileByteCount: 10_000,
            releaseConfirmed: true
        )
    }
}
