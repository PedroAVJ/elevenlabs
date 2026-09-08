import Dispatch
import XCTest
@testable import ElevenLabs

final class SharedDictationStoreTests: XCTestCase {
    func testControlTogglePreparesLauncherAndHonorsActiveSessionValues() {
        XCTAssertEqual(
            DictationControlTransition.action(
                requestedIsOn: true,
                phase: .idle
            ),
            .showLauncher
        )
        XCTAssertEqual(
            DictationControlTransition.action(
                requestedIsOn: false,
                phase: .recording
            ),
            .pause
        )
        XCTAssertEqual(
            DictationControlTransition.action(
                requestedIsOn: true,
                phase: .paused
            ),
            .resume
        )
    }

    func testControlToggleAbsorbsStaleAndTransitionalValues() {
        for phase in [
            SharedDictationPhase.launching,
            .starting,
            .recording,
            .pausing,
            .resuming,
            .transcribing,
            .completed,
            .inserting,
            .deliveryBlocked,
        ] {
            XCTAssertEqual(
                DictationControlTransition.action(
                    requestedIsOn: true,
                    phase: phase
                ),
                .none
            )
        }

        for phase in [
            SharedDictationPhase.idle,
            .launching,
            .starting,
            .pausing,
            .paused,
            .resuming,
            .transcribing,
            .completed,
            .failed,
            .cancelled,
        ] {
            XCTAssertEqual(
                DictationControlTransition.action(
                    requestedIsOn: false,
                    phase: phase
                ),
                .none
            )
        }
    }

    func testTerminalControlFailureCompletesIntentToReleaseOptimisticState() {
        XCTAssertTrue(
            DictationControlIntentFailurePolicy.completesIntent(after: .failed)
        )
        for phase in [
            SharedDictationPhase.idle,
            .launching,
            .starting,
            .recording,
            .pausing,
            .paused,
            .resuming,
            .transcribing,
            .completed,
            .inserting,
            .deliveryBlocked,
            .cancelled,
            .inserted,
            .handled,
        ] {
            XCTAssertFalse(
                DictationControlIntentFailurePolicy.completesIntent(
                    after: phase
                )
            )
        }
    }

    private final class ContinuationRaceResult: @unchecked Sendable {
        private let lock = NSLock()
        private var insertion = false
        private var continuation = false

        func recordInsertion(_ value: Bool) {
            lock.lock()
            insertion = value
            lock.unlock()
        }

        func recordContinuation(_ value: Bool) {
            lock.lock()
            continuation = value
            lock.unlock()
        }

        var values: (insertion: Bool, continuation: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (insertion, continuation)
        }
    }

    private func withIsolatedSharedStores(
        _ body: (
            SharedDictationStore,
            SharedDictationStore
        ) throws -> Void
    ) throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        try body(
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            ),
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            )
        )
    }

    private func withIsolatedContinuationStores(
        _ body: (
            SharedDictationStore,
            SharedDictationStore,
            SharedDictationContinuationStore
        ) throws -> Void
    ) throws {
        let suiteName = "SharedDictationContinuationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        try body(
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            ),
            SharedDictationStore(
                suiteName: suiteName,
                storageDirectory: directory
            ),
            SharedDictationContinuationStore(
                suiteName: suiteName,
                storageDirectory: directory
            )
        )
    }

    func testRequestedContinuationBanksAndAppendsEachPartExactlyOnce() throws {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let firstPart = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            app.setPhase(
                .transcribing,
                sessionID: session.sessionID,
                elapsedDuration: 4
            )
            XCTAssertTrue(app.releaseCaptureLease(ownerID: session.sessionID))
            XCTAssertTrue(
                continuation.requestContinuation(sessionID: session.sessionID)
            )

            let launch = try XCTUnwrap(
                continuation.beginRequestedContinuation(
                    sessionID: session.sessionID,
                    partID: firstPart,
                    transcript: "  First thought.  ",
                    duration: 4,
                    historyPersisted: true
                )
            )
            XCTAssertEqual(launch.assembly.text, "First thought.")
            XCTAssertEqual(launch.assembly.duration, 4)
            XCTAssertEqual(keyboard.load().phase, .launching)
            XCTAssertNil(keyboard.load().transcript)

            // Replaying a result banked before a crash must not duplicate it.
            XCTAssertEqual(
                continuation.assembly(
                    sessionID: session.sessionID,
                    partID: firstPart,
                    transcript: "First thought.",
                    duration: 4
                ),
                launch.assembly
            )

            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let secondPart = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            let combined = continuation.assembly(
                sessionID: session.sessionID,
                partID: secondPart,
                transcript: "  Second thought. ",
                duration: 3
            )
            XCTAssertEqual(combined.text, "First thought. Second thought.")
            XCTAssertEqual(combined.duration, 7)
        }
    }

    func testImmediateContinuationStartsNextPartBeforePriorBankCompletes()
        throws
    {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let firstPart = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .transcribing,
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            XCTAssertTrue(app.releaseCaptureLease(ownerID: session.sessionID))

            let launch = try XCTUnwrap(
                continuation.beginImmediateContinuation(
                    sessionID: session.sessionID,
                    expectedPriorPartID: firstPart
                )
            )
            XCTAssertEqual(launch.priorPartID, firstPart)
            XCTAssertNotEqual(launch.nextPartID, firstPart)
            XCTAssertEqual(keyboard.load().phase, .launching)
            XCTAssertEqual(
                keyboard.load().captureOwnerID,
                session.sessionID
            )
            XCTAssertEqual(keyboard.load().elapsedDuration, 4)
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .activePartID,
                launch.nextPartID
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .pendingPartIDs,
                [firstPart]
            )

            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .recording,
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            let banked = try XCTUnwrap(
                continuation.bankImmediateContinuationPart(
                    sessionID: session.sessionID,
                    partID: firstPart,
                    transcript: "First thought",
                    duration: 4,
                    historyPersisted: true
                )
            )
            XCTAssertEqual(banked.text, "First thought")
            XCTAssertEqual(banked.duration, 4)
            XCTAssertEqual(keyboard.load().phase, .recording)
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .activePartID,
                launch.nextPartID
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .pendingPartIDs,
                []
            )
            XCTAssertNil(
                continuation.bankImmediateContinuationPart(
                    sessionID: session.sessionID,
                    partID: firstPart,
                    transcript: "First thought",
                    duration: 4,
                    historyPersisted: true
                )
            )

            let combined = continuation.assembly(
                sessionID: session.sessionID,
                partID: launch.nextPartID,
                transcript: "Second thought",
                duration: 3
            )
            XCTAssertEqual(combined.text, "First thought Second thought")
            XCTAssertEqual(combined.duration, 7)
        }
    }

    func testImmediateContinuationRejectsMismatchedPriorPartWithoutMutation()
        throws
    {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let firstPart = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .transcribing,
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            XCTAssertTrue(app.releaseCaptureLease(ownerID: session.sessionID))

            XCTAssertNil(
                continuation.beginImmediateContinuation(
                    sessionID: session.sessionID,
                    expectedPriorPartID: UUID()
                )
            )
            XCTAssertEqual(keyboard.load().phase, .transcribing)
            XCTAssertNil(keyboard.load().captureOwnerID)
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?.activePartID,
                firstPart
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?.pendingPartIDs,
                []
            )
        }
    }

    func testCancellingImmediateContinuationRestoresPriorPartOwnership() throws {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let firstPart = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .transcribing,
                    sessionID: session.sessionID,
                    elapsedDuration: 6
                )
            )
            XCTAssertTrue(app.releaseCaptureLease(ownerID: session.sessionID))
            let launch = try XCTUnwrap(
                continuation.beginImmediateContinuation(
                    sessionID: session.sessionID,
                    expectedPriorPartID: firstPart
                )
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .recording,
                    sessionID: session.sessionID,
                    elapsedDuration: 6
                )
            )

            let rollback = try XCTUnwrap(
                continuation.abandonImmediateContinuation(
                    sessionID: session.sessionID,
                    abandonedPartID: launch.nextPartID,
                    priorPartID: firstPart,
                    elapsedDuration: 6
                )
            )

            XCTAssertEqual(rollback.priorPartID, firstPart)
            XCTAssertEqual(rollback.elapsedDuration, 6)
            XCTAssertEqual(keyboard.load().phase, .transcribing)
            XCTAssertNil(keyboard.load().captureOwnerID)
            XCTAssertTrue(keyboard.load().hasRecoverableAudio == true)
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?.activePartID,
                firstPart
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?.pendingPartIDs,
                []
            )
            XCTAssertNil(
                continuation.abandonImmediateContinuation(
                    sessionID: session.sessionID,
                    abandonedPartID: launch.nextPartID,
                    priorPartID: firstPart,
                    elapsedDuration: 6
                )
            )
        }
    }

    func testPauseBoundaryWaitsForBankBeforeControlCenterContinuation() throws {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let partID = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                continuation.beginPausedBoundary(
                    sessionID: session.sessionID,
                    elapsedDuration: 3
                )
            )
            XCTAssertEqual(keyboard.load().phase, .paused)
            XCTAssertNil(keyboard.load().captureOwnerID)
            XCTAssertEqual(
                continuation.requestPausedContinuation(
                    sessionID: session.sessionID
                ),
                .waitingForTranscript
            )

            let completion = continuation.completePausedPart(
                sessionID: session.sessionID,
                partID: partID,
                transcript: "First segment",
                duration: 3,
                historyPersisted: true
            )
            guard case let .launch(launch) = completion else {
                return XCTFail("banking should honor the queued continuation")
            }
            XCTAssertEqual(launch.assembly.text, "First segment")
            XCTAssertEqual(launch.assembly.duration, 3)
            XCTAssertEqual(keyboard.load().phase, .launching)
            XCTAssertEqual(
                keyboard.load().captureOwnerID,
                session.sessionID
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .pausedBoundaryActive,
                false
            )
        }
    }

    func testBankedPauseBoundaryReopensOnlyFromControlCenter() throws {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let partID = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                continuation.beginPausedBoundary(
                    sessionID: session.sessionID,
                    elapsedDuration: 2.5
                )
            )

            let completion = continuation.completePausedPart(
                sessionID: session.sessionID,
                partID: partID,
                transcript: "Banked words",
                duration: 2.5,
                historyPersisted: true
            )
            guard case let .waiting(assembly) = completion else {
                return XCTFail("pause should remain parked without Control Center")
            }
            XCTAssertEqual(assembly.text, "Banked words")
            XCTAssertEqual(keyboard.load().phase, .paused)
            XCTAssertFalse(keyboard.load().hasRecoverableAudio ?? true)

            let request = continuation.requestPausedContinuation(
                sessionID: session.sessionID
            )
            guard case let .launch(launch) = request else {
                return XCTFail("Control Center should claim the next segment")
            }
            XCTAssertEqual(launch.assembly, assembly)
            XCTAssertEqual(keyboard.load().phase, .launching)
        }
    }

    func testSendDuringPauseBankingFinishesInsteadOfStartingAnotherSegment()
        throws
    {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let partID = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                continuation.beginPausedBoundary(
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            XCTAssertTrue(
                app.setPhase(.transcribing, sessionID: session.sessionID)
            )

            let completion = continuation.completePausedPart(
                sessionID: session.sessionID,
                partID: partID,
                transcript: "Finish here",
                duration: 4,
                historyPersisted: true
            )
            guard case let .finishing(assembly) = completion else {
                return XCTFail("Send should finish the paused dictation")
            }
            XCTAssertEqual(assembly.text, "Finish here")
            XCTAssertEqual(keyboard.load().phase, .transcribing)
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .pausedBoundaryActive,
                false
            )
        }
    }

    func testSendRacingPauseBoundaryCannotBeStolenByControlCenter() throws {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            let partID = try XCTUnwrap(
                continuation.registerPart(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(app.send(.stop, sessionID: session.sessionID))
            XCTAssertTrue(
                continuation.beginPausedBoundary(
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            XCTAssertEqual(keyboard.load().command, .stop)
            XCTAssertEqual(
                continuation.requestPausedContinuation(
                    sessionID: session.sessionID
                ),
                .unavailable
            )

            let completion = continuation.completePausedPart(
                sessionID: session.sessionID,
                partID: partID,
                transcript: "Send wins",
                duration: 4,
                historyPersisted: true
            )
            guard case let .finishing(assembly) = completion else {
                return XCTFail("the pending keyboard Send should finish")
            }
            XCTAssertEqual(assembly.text, "Send wins")
            XCTAssertEqual(keyboard.load().phase, .transcribing)
            XCTAssertEqual(keyboard.load().command, .none)
        }
    }

    func testKeyboardInsertionWinsCompletedTranscriptRaceWithoutReopening()
        throws
    {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            app.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Already delivered",
                elapsedDuration: 2
            )
            XCTAssertNil(app.load().captureOwnerID)

            XCTAssertTrue(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertNil(
                continuation.reopenCompletedForContinuation(
                    sessionID: session.sessionID
                )
            )
            XCTAssertEqual(app.load().phase, .inserting)
            XCTAssertEqual(app.load().transcript, "Already delivered")
        }
    }

    func testContinuationWinsCompletedTranscriptRaceBeforeKeyboardInsertion()
        throws
    {
        try withIsolatedContinuationStores { app, keyboard, continuation in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            app.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Keep this text",
                historyPersisted: true,
                elapsedDuration: 5
            )
            XCTAssertNil(app.load().captureOwnerID)

            let reopened = try XCTUnwrap(
                continuation.reopenCompletedForContinuation(
                    sessionID: session.sessionID
                )
            )
            XCTAssertEqual(reopened.phase, .launching)
            XCTAssertNil(reopened.transcript)
            XCTAssertFalse(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .accumulatedTranscript,
                "Keep this text"
            )
            XCTAssertEqual(
                continuation.state(sessionID: session.sessionID)?
                    .accumulatedDuration,
                5
            )
        }
    }

    func testConcurrentCompletedTranscriptRaceAlwaysHasExactlyOneWinner()
        throws
    {
        for iteration in 0..<64 {
            try withIsolatedContinuationStores {
                app, keyboard, continuation in
                let session = try XCTUnwrap(
                    app.begin(returnBundleIdentifier: nil)
                )
                app.setPhase(
                    .completed,
                    sessionID: session.sessionID,
                    transcript: "Never lose part \(iteration)",
                    elapsedDuration: 2
                )

                let result = ContinuationRaceResult()
                DispatchQueue.concurrentPerform(iterations: 2) { contender in
                    if contender == 0 {
                        result.recordInsertion(
                            keyboard.markInsertionStarted(
                                sessionID: session.sessionID
                            )
                        )
                    } else {
                        result.recordContinuation(
                            continuation.reopenCompletedForContinuation(
                                sessionID: session.sessionID
                            ) != nil
                        )
                    }
                }

                let winners = result.values
                XCTAssertNotEqual(
                    winners.insertion,
                    winners.continuation,
                    "iteration \(iteration) must have exactly one owner"
                )
                if winners.insertion {
                    XCTAssertEqual(app.load().phase, .inserting)
                    XCTAssertEqual(
                        app.load().transcript,
                        "Never lose part \(iteration)"
                    )
                } else {
                    XCTAssertEqual(app.load().phase, .launching)
                    XCTAssertEqual(
                        continuation.state(sessionID: session.sessionID)?
                            .accumulatedTranscript,
                        "Never lose part \(iteration)"
                    )
                }
            }
        }
    }

    func testHostCaptureBaselinePreservesCallbacksAfterCleanHandoff() {
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 1,
                cleanBoundaryGeneration: nil,
                processHasEstablishedAppearance: false
            ),
            0
        )
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 3,
                cleanBoundaryGeneration: 2,
                processHasEstablishedAppearance: true
            ),
            2
        )
        XCTAssertEqual(
            HostApplicationCapturePolicy.baselineGeneration(
                currentGeneration: 3,
                cleanBoundaryGeneration: nil,
                processHasEstablishedAppearance: true
            ),
            3
        )
    }

    func testHostCapturePolicyRequiresNewGenerationAndStableProcess() {
        XCTAssertTrue(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 11,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 475,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: nil,
                currentProcessIdentifier: nil,
                previousIdentity: nil
            )
        )
    }

    func testVisibleHostLeaseAcceptsFreshCatalogCaptureWithoutProcessID() {
        XCTAssertTrue(
            HostApplicationCapturePolicy.acceptsVisibleLease(
                candidateBundleIdentifier: "com.openai.chat",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: nil,
                currentProcessIdentifier: nil,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.acceptsVisibleLease(
                candidateBundleIdentifier: "com.openai.chat",
                captureGeneration: 11,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: nil,
                currentProcessIdentifier: nil,
                previousIdentity: nil
            )
        )
        XCTAssertFalse(
            HostApplicationCapturePolicy.acceptsVisibleLease(
                candidateBundleIdentifier: "com.openai.chat",
                captureGeneration: 12,
                appearanceBaselineGeneration: 11,
                expectedProcessIdentifier: nil,
                currentProcessIdentifier: 474,
                previousIdentity: nil
            )
        )
    }

    func testHostCapturePolicyRejectsTransientBrokerAndCorruptedCache() {
        let supported = [
            "com.apple.mobilenotes",
            "net.whatsapp.WhatsApp",
        ]
        XCTAssertEqual(
            HostApplicationCapturePolicy.canonicalSupportedBundleIdentifier(
                " net.whatsapp.whatsapp ",
                supportedBundleIdentifiers: supported
            ),
            "net.whatsapp.WhatsApp"
        )
        XCTAssertNil(
            HostApplicationCapturePolicy.canonicalSupportedBundleIdentifier(
                "com.apple.SafariViewService",
                supportedBundleIdentifiers: supported
            )
        )

        let corrupted = HostApplicationIdentity(
            bundleIdentifier: "com.apple.SafariViewService",
            processIdentifier: 474,
            capturedAt: Date()
        )
        XCTAssertNil(
            HostApplicationCapturePolicy.supportedIdentity(
                corrupted,
                supportedBundleIdentifiers: supported
            )
        )
    }

    func testHostCapturePolicyQuarantinesLatePreviousHostCallback() {
        let now = Date(timeIntervalSince1970: 30_000)
        let previousNotes = HostApplicationIdentity(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 801,
            capturedAt: now.addingTimeInterval(-1)
        )

        XCTAssertFalse(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "com.apple.mobilenotes",
                captureGeneration: 22,
                appearanceBaselineGeneration: 21,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: previousNotes
            )
        )
        XCTAssertTrue(
            HostApplicationCapturePolicy.accepts(
                candidateBundleIdentifier: "net.whatsapp.WhatsApp",
                captureGeneration: 23,
                appearanceBaselineGeneration: 21,
                expectedProcessIdentifier: 474,
                currentProcessIdentifier: 474,
                previousIdentity: previousNotes
            )
        )
    }

    func testHostIdentityCacheRequiresExactLiveProcess() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 10_000)

        cache.save(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            processIdentifier: 474,
            capturedAt: capturedAt
        )

        XCTAssertEqual(
            cache.matchingIdentity(
                processIdentifier: 474,
                now: capturedAt.addingTimeInterval(60)
            )?.bundleIdentifier,
            "net.whatsapp.WhatsApp"
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 475,
                now: capturedAt.addingTimeInterval(60)
            )
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: nil,
                now: capturedAt.addingTimeInterval(60)
            )
        )
    }

    func testHostIdentityCacheRejectsExpiredAndFutureRecords() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 20_000)

        cache.save(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 801,
            capturedAt: capturedAt
        )

        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 801,
                now: capturedAt.addingTimeInterval(
                    HostApplicationIdentityCache.defaultMaximumAge + 1
                )
            )
        )
        XCTAssertNil(
            cache.matchingIdentity(
                processIdentifier: 801,
                now: capturedAt.addingTimeInterval(-6)
            )
        )
    }

    func testVisibleKeyboardLeaseExpiresBeforeAStaleLauncherTap() throws {
        let suiteName = "VisibleHostApplicationLeaseCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = VisibleHostApplicationLeaseCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 25_000)

        cache.save(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: nil,
            capturedAt: capturedAt
        )

        XCTAssertNotNil(
            cache.freshLease(
                now: capturedAt.addingTimeInterval(
                    VisibleHostApplicationLeaseCache.maximumAge
                )
            )
        )
        XCTAssertNil(
            cache.freshLease(
                now: capturedAt.addingTimeInterval(
                    VisibleHostApplicationLeaseCache.maximumAge + 0.001
                )
            )
        )
    }

    @MainActor
    func testLiveActivityScenePreflightPreservesFreshLeaseForColdLaunch()
        throws
    {
        let suiteName = "VisibleHostApplicationLeaseCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = VisibleHostApplicationLeaseCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 26_000)
        cache.save(
            bundleIdentifier: "com.openai.chat",
            processIdentifier: nil,
            capturedAt: capturedAt
        )

        let context = try XCTUnwrap(
            LiveActivityLaunchContext.capture(
                for: try XCTUnwrap(
                    URL(string: "elevenlabs://live-activity/start")
                ),
                sourceApplication: nil,
                visibleLeaseCache: cache,
                now: capturedAt.addingTimeInterval(3.9)
            )
        )
        XCTAssertEqual(
            context.visibleKeyboardHostLease?.bundleIdentifier,
            "com.openai.chat"
        )
        XCTAssertNil(context.visibleKeyboardHostLease?.processIdentifier)

        // Simulate AppModel's cold-start work finishing after the original
        // four-second cache lease. The URL-bound snapshot remains valid while
        // a new read of the App Group correctly expires.
        XCTAssertNil(
            cache.freshLease(now: capturedAt.addingTimeInterval(4.1))
        )
        let resolution = LiveActivityReturnTargetResolution.resolve(
            launchContext: context,
            currentVisibleLease: nil
        )
        XCTAssertEqual(resolution.bundleIdentifier, "com.openai.chat")
        XCTAssertNil(resolution.processIdentifier)
        XCTAssertEqual(resolution.evidence, .scenePreflight)
    }

    @MainActor
    func testLiveActivityScenePreflightDoesNotExtendExpiredLease() throws {
        let suiteName = "VisibleHostApplicationLeaseCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = VisibleHostApplicationLeaseCache(suiteName: suiteName)
        let capturedAt = Date(timeIntervalSince1970: 27_000)
        cache.save(
            bundleIdentifier: "com.anthropic.claude",
            processIdentifier: 601,
            capturedAt: capturedAt
        )

        let context = try XCTUnwrap(
            LiveActivityLaunchContext.capture(
                for: try XCTUnwrap(
                    URL(string: "elevenlabs://live-activity/start")
                ),
                sourceApplication: nil,
                visibleLeaseCache: cache,
                now: capturedAt.addingTimeInterval(4.001)
            )
        )
        XCTAssertNil(context.visibleKeyboardHostLease)
        XCTAssertEqual(
            LiveActivityReturnTargetResolution.resolve(
                launchContext: context,
                currentVisibleLease: nil
            ).evidence,
            .unavailable
        )
    }

    func testHostIdentityCacheReplacesAndClearsRecord() throws {
        let suiteName = "HostApplicationIdentityCache-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cache = HostApplicationIdentityCache(suiteName: suiteName)

        cache.save(
            bundleIdentifier: "com.apple.mobilenotes",
            processIdentifier: 700
        )
        cache.save(
            bundleIdentifier: "net.whatsapp.WhatsApp",
            processIdentifier: 701
        )

        XCTAssertNil(cache.matchingIdentity(processIdentifier: 700))
        XCTAssertEqual(
            cache.matchingIdentity(processIdentifier: 701)?.bundleIdentifier,
            "net.whatsapp.WhatsApp"
        )
        cache.clear()
        XCTAssertNil(cache.load())
    }

    func testKeyboardSetupStatusReflectsActualExtensionAccess() throws {
        let suiteName = "KeyboardSetupStatus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KeyboardSetupStatusStore(
            suiteName: suiteName,
            legacyEvidenceKeys: ["legacy-keyboard-evidence"]
        )

        XCTAssertEqual(
            store.resolution(),
            KeyboardSetupResolution(
                wasDetected: false,
                hasFullAccess: false
            )
        )

        let observedAt = Date(timeIntervalSince1970: 1_234)
        store.record(hasFullAccess: true, now: observedAt)
        XCTAssertEqual(
            store.load(),
            KeyboardSetupStatus(
                hasFullAccess: true,
                observedAt: observedAt
            )
        )
        XCTAssertEqual(
            store.resolution(),
            KeyboardSetupResolution(
                wasDetected: true,
                hasFullAccess: true
            )
        )

        // A current explicit observation wins if Full Access is later revoked.
        store.record(hasFullAccess: false, now: observedAt.addingTimeInterval(1))
        defaults.set(true, forKey: "legacy-keyboard-evidence")
        XCTAssertEqual(
            store.resolution(),
            KeyboardSetupResolution(
                wasDetected: true,
                hasFullAccess: false
            )
        )
    }

    func testKeyboardSetupMigratesPriorExtensionEvidence() throws {
        let suiteName = "KeyboardSetupMigration-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data([0x01]), forKey: "legacy-keyboard-evidence")

        let resolution = KeyboardSetupStatusStore(
            suiteName: suiteName,
            legacyEvidenceKeys: ["legacy-keyboard-evidence"]
        ).resolution()

        XCTAssertEqual(
            resolution,
            KeyboardSetupResolution(
                wasDetected: true,
                hasFullAccess: true
            )
        )
    }

    func testKeyboardInsertionTelemetryCorrelatesAttemptAndTerminalResult()
        throws
    {
        let suiteName = "KeyboardInsertionTelemetry-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KeyboardInsertionTelemetryStore(suiteName: suiteName)
        let sessionID = UUID()
        let startedAt = Date(timeIntervalSince1970: 2_000)

        let attemptID = store.begin(
            sessionID: sessionID,
            transcript: "En otro rincón Test phrase En 19",
            returnBundleIdentifier: "com.openai.chat",
            now: startedAt
        )
        let attempting = try XCTUnwrap(store.pendingForReporting())
        XCTAssertEqual(attempting.id, attemptID)
        XCTAssertEqual(attempting.sessionID, sessionID)
        XCTAssertEqual(attempting.outcome, .attempting)
        store.markReported(attempting)
        XCTAssertNil(store.pendingForReporting())

        store.finish(
            id: attemptID,
            result: KeyboardInsertionResult(
                confirmed: true,
                documentIdentifierBefore: "document-a",
                documentIdentifierAfter: "document-a",
                contextBeforeMutation: "Draft: ",
                contextAfterMutation:
                    "Draft: En otro rincón Test phrase En 19",
                documentChangeObserved: true
            ),
            now: startedAt.addingTimeInterval(0.18)
        )

        let confirmed = try XCTUnwrap(store.pendingForReporting())
        XCTAssertEqual(confirmed.outcome, .confirmed)
        XCTAssertEqual(confirmed.latencyMs, 180)
        XCTAssertEqual(
            confirmed.transcript,
            "En otro rincón Test phrase En 19"
        )
        XCTAssertEqual(confirmed.returnBundleIdentifier, "com.openai.chat")
        XCTAssertEqual(confirmed.contextBeforeMutation, "Draft: ")
        XCTAssertEqual(
            confirmed.contextAfterMutation,
            "Draft: En otro rincón Test phrase En 19"
        )
    }

    func testKeyboardInsertionTelemetryRejectsStaleCompletion() throws {
        let suiteName = "KeyboardInsertionStale-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = KeyboardInsertionTelemetryStore(suiteName: suiteName)
        let firstID = store.begin(
            sessionID: UUID(),
            transcript: "first",
            returnBundleIdentifier: nil
        )
        let secondID = store.begin(
            sessionID: UUID(),
            transcript: "second",
            returnBundleIdentifier: nil
        )

        store.finish(
            id: firstID,
            result: KeyboardInsertionResult(
                confirmed: true,
                documentIdentifierBefore: "a",
                documentIdentifierAfter: "a",
                contextBeforeMutation: nil,
                contextAfterMutation: nil,
                documentChangeObserved: true
            )
        )
        XCTAssertEqual(store.load()?.id, secondID)
        XCTAssertEqual(store.load()?.outcome, .attempting)
    }

    @MainActor
    func testWisprStyleCatalogUsesStaticHostURLs() throws {
        let notes = try XCTUnwrap(
            HostAppSwitcher.appInfo(for: "com.apple.mobilenotes")
        )
        XCTAssertEqual(notes.displayName, "Notes")
        XCTAssertEqual(notes.launchURL.absoluteString, "mobilenotes://")
        XCTAssertTrue(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "com.openai.chat"
            )
        )
        XCTAssertEqual(
            HostAppSwitcher.appInfo(for: "com.openai.chat")?
                .launchURL.absoluteString,
            "chatgpt://"
        )
        XCTAssertEqual(
            HostAppSwitcher.appInfo(for: "com.anthropic.claude")?
                .launchURL.absoluteString,
            "claude://"
        )
        XCTAssertEqual(
            HostAppSwitcher.userSelectableChatApps.map(\.bundleIdentifier),
            [
                HostAppSwitcher.chatGPTBundleIdentifier,
                HostAppSwitcher.claudeBundleIdentifier,
            ]
        )
        XCTAssertTrue(
            HostAppSwitcher.supportsUserSelectedChatReturn(
                to: "com.openai.chat"
            )
        )
        XCTAssertTrue(
            HostAppSwitcher.supportsUserSelectedChatReturn(
                to: "com.anthropic.claude"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.supportsUserSelectedChatReturn(
                to: "com.apple.mobilenotes"
            )
        )
        XCTAssertTrue(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "ch.protonmail.protonmail"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.supportsAutomaticReturn(
                to: "com.example.unsupported"
            )
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedRoute(
                for: "com.apple.mobilenotes"
            ),
            "host-url"
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedAttempts(
                for: "net.whatsapp.WhatsApp",
                processIdentifier: 474
            ),
            [
                "return-target-shared-bundle:net.whatsapp.WhatsApp",
                "host-catalog:net.whatsapp.WhatsApp",
                "host-url:pending",
            ]
        )
        XCTAssertEqual(
            HostAppSwitcher.anticipatedRoute(
                for: "com.example.unsupported"
            ),
            "manual-switchback"
        )
    }

    func testHostSwitchOutcomeCountsTheSingleProtectedOpenRequest() {
        XCTAssertEqual(
            HostAppSwitchOutcome(
                didOpen: true,
                attempts: [
                    "host-url-can-open:true",
                    "host-url:true",
                ]
            ).openAttemptCount,
            1
        )
        XCTAssertEqual(
            HostAppSwitchOutcome(
                didOpen: false,
                attempts: [
                    "host-url-can-open:false",
                    "manual-switchback:scheme-unavailable",
                ]
            ).openAttemptCount,
            0
        )
    }

    func testInsertionFingerprintTreatsNilAndEmptyProxyContextAsEquivalent() {
        let documentID = UUID()
        let nilContext = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: nil,
            textAfterInput: nil,
            selectedText: nil,
            keyboardType: nil
        )
        let emptyContext = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "",
            textAfterInput: "",
            selectedText: "",
            keyboardType: 0
        )

        XCTAssertEqual(nilContext, emptyContext)
    }

    func testInsertionFingerprintStillDetectsRealCursorAndFieldChanges() {
        let documentID = UUID()
        let original = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "hello",
            textAfterInput: " world",
            selectedText: nil,
            keyboardType: 0
        )
        let movedCursor = InsertionContextFingerprint.make(
            documentIdentifier: documentID,
            textBeforeInput: "hello ",
            textAfterInput: "world",
            selectedText: nil,
            keyboardType: 0
        )
        let differentField = InsertionContextFingerprint.make(
            documentIdentifier: UUID(),
            textBeforeInput: "hello",
            textAfterInput: " world",
            selectedText: nil,
            keyboardType: 0
        )

        XCTAssertNotEqual(original, movedCursor)
        XCTAssertNotEqual(original, differentField)
    }

    @MainActor
    func testReturnTargetsRejectSystemBrokersWithoutRestrictingRealApps() {
        XCTAssertTrue(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.mobilenotes"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.springboard"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.Spotlight"
            )
        )
        XCTAssertFalse(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.apple.SafariViewService"
            )
        )
        XCTAssertTrue(
            HostAppSwitcher.isValidReturnBundleIdentifier(
                "com.example.unknown"
            )
        )
    }

    func testSessionMovesFromLaunchThroughCompletionAndInsertion() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.openai.chat",
            returnProcessIdentifier: 4_281
        ))
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertEqual(store.load().returnBundleIdentifier, "com.openai.chat")
        XCTAssertEqual(store.load().returnProcessIdentifier, 4_281)

        store.setHostResolutionDiagnostics(
            ["environment-host:<nil>", "scene.hostBundleIdentifier:com.openai.chat"],
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().hostResolutionAttempts,
            ["environment-host:<nil>", "scene.hostBundleIdentifier:com.openai.chat"]
        )

        store.setReturnDiagnostics(
            ["host-url:true"],
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().returnAttempts,
            ["host-url:true"]
        )

        store.setLaunchDiagnostics(
            ["responder-scene:true"],
            successfulRoute: "scene",
            sessionID: session.sessionID
        )
        XCTAssertEqual(store.load().successfulLaunchRoute, "scene")
        XCTAssertEqual(
            store.load().launchAttempts,
            ["responder-scene:true"]
        )

        store.setIncomingURLContext(
            deliveryRoute: "scene-open-url",
            sourceApplication: "com.apple.mobilenotes",
            sessionID: session.sessionID
        )
        XCTAssertEqual(
            store.load().incomingURLDeliveryRoute,
            "scene-open-url"
        )
        XCTAssertEqual(
            store.load().incomingURLSourceApplication,
            "com.apple.mobilenotes"
        )

        store.setPhase(.recording, sessionID: session.sessionID)
        store.send(.stop, sessionID: session.sessionID)
        XCTAssertEqual(store.load().command, .stop)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .stop
        )

        store.setPhase(.completed, sessionID: session.sessionID, transcript: "Hello world")
        XCTAssertEqual(store.load().transcript, "Hello world")
        XCTAssertEqual(store.load().command, .none)

        store.markInserted(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .inserted)
        XCTAssertNil(store.load().transcript)
    }

    func testStaleSessionCannotOverwriteCurrentSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let stale = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(.cancelled, sessionID: stale.sessionID)
        let current = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.apple.MobileSMS")
        )
        store.setPhase(.failed, sessionID: stale.sessionID, errorMessage: "Stale")

        XCTAssertEqual(store.load().sessionID, current.sessionID)
        XCTAssertEqual(store.load().phase, .launching)
        XCTAssertNil(store.load().errorMessage)
    }

    func testBackgroundSessionStaysStartingUntilCaptureIsLive() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertEqual(store.load().phase, .starting)
        XCTAssertEqual(store.load().sessionKind, .segmentedIntent)

        store.setPhase(.recording, sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .recording)
        XCTAssertGreaterThanOrEqual(store.load().startedAt, session.startedAt)
    }

    func testBackgroundSessionPublishesPauseAndResumeTransitions() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertTrue(
            store.transitionPhase(
                from: [.starting],
                to: .recording,
                sessionID: session.sessionID
            )
        )
        XCTAssertTrue(
            store.transitionPhase(
                from: [.recording],
                to: .pausing,
                sessionID: session.sessionID
            )
        )
        XCTAssertEqual(store.load().phase, .pausing)
        XCTAssertTrue(store.load().phase.isContainingAppOwned)

        XCTAssertTrue(
            store.transitionPhase(
                from: [.pausing],
                to: .paused,
                sessionID: session.sessionID
            )
        )
        XCTAssertTrue(
            store.transitionPhase(
                from: [.paused],
                to: .resuming,
                sessionID: session.sessionID
            )
        )
        XCTAssertEqual(store.load().phase, .resuming)
        XCTAssertTrue(store.load().phase.isContainingAppOwned)
        XCTAssertTrue(store.load().phase.retainsSessionCaptureLease)
    }

    func testBackgroundSessionPreservesLiveActivityReturnIdentity() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(
            store.beginBackgroundSession(
                returnBundleIdentifier: "com.openai.chat",
                returnProcessIdentifier: 55469
            )
        )

        XCTAssertEqual(session.sessionKind, .segmentedIntent)
        XCTAssertEqual(session.returnBundleIdentifier, "com.openai.chat")
        XCTAssertEqual(session.returnProcessIdentifier, 55469)
        XCTAssertEqual(
            store.load().returnBundleIdentifier,
            "com.openai.chat"
        )
        XCTAssertEqual(store.load().returnProcessIdentifier, 55469)
    }

    func testKeyboardAndIntentSessionsCarryDistinctOwners() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let keyboardSession = try XCTUnwrap(
                keyboard.begin(returnBundleIdentifier: "com.apple.mobilenotes")
            )
            XCTAssertEqual(
                containingApp.load().sessionKind,
                .keyboardRoundTrip
            )

            containingApp.setPhase(
                .cancelled,
                sessionID: keyboardSession.sessionID
            )
            let intentSession = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            XCTAssertEqual(intentSession.sessionKind, .segmentedIntent)
        }
    }

    func testPausedSessionRemainsDurableWithoutAHeartbeat() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID
            )

            let paused = keyboard.load()
            XCTAssertEqual(paused.phase, .paused)
            XCTAssertEqual(paused.captureOwnerID, session.sessionID)
            XCTAssertFalse(paused.phase.isContainingAppOwned)
            XCTAssertEqual(
                paused.phase.containingAppAbandonmentTimeout,
                0
            )
            XCTAssertTrue(keyboard.isCaptureLeaseActive)
            XCTAssertNil(keyboard.beginBackgroundSession())

            let beforeRevision = paused.revision ?? 0
            containingApp.touch(sessionID: session.sessionID)
            XCTAssertGreaterThan(
                keyboard.load().revision ?? 0,
                beforeRevision
            )
        }
    }

    func testPauseAndResumeCommandsCrossProcessesExactlyOnce() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID
            )

            keyboard.send(.pause, sessionID: session.sessionID)
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.pause]
                ),
                .pause
            )
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.pause]
                ),
                .none
            )

            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID
            )
            keyboard.send(.resume, sessionID: session.sessionID)
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.resume]
                ),
                .resume
            )
            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.resume]
                ),
                .none
            )

            let consumed = keyboard.load()
            XCTAssertEqual(consumed.command, .none)
            XCTAssertEqual(
                consumed.acknowledgedCommandSequence,
                consumed.commandSequence
            )
        }
    }

    func testIntentControlsRouteToKeyboardRecorderWithoutDuplicates() throws {
        try withIsolatedSharedStores { containingApp, intentProcess in
            let session = try XCTUnwrap(
                containingApp.begin(
                    returnBundleIdentifier: "com.openai.chat"
                )
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID
            )

            XCTAssertTrue(
                SharedDictationIntentCommandRouter.routeToKeyboardOwner(
                    .pause,
                    sessionID: session.sessionID,
                    store: intentProcess
                )
            )
            let routedOnce = containingApp.load()
            XCTAssertEqual(routedOnce.command, .pause)

            XCTAssertTrue(
                SharedDictationIntentCommandRouter.routeToKeyboardOwner(
                    .pause,
                    sessionID: session.sessionID,
                    store: intentProcess
                )
            )
            XCTAssertEqual(
                containingApp.load().commandSequence,
                routedOnce.commandSequence,
                "the keyboard prepare and intent wakeup must be idempotent"
            )

            XCTAssertEqual(
                containingApp.takePendingCommand(
                    sessionID: session.sessionID,
                    accepting: [.pause]
                ),
                .pause
            )
            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID
            )
            XCTAssertTrue(
                SharedDictationIntentCommandRouter.routeToggleToKeyboardOwner(
                    store: intentProcess
                )
            )
            XCTAssertEqual(containingApp.load().command, .resume)
        }
    }

    func testIntentControlsLeaveSegmentedSessionWithItsEngine() throws {
        try withIsolatedSharedStores { engine, intentProcess in
            let session = try XCTUnwrap(engine.beginBackgroundSession())
            engine.setPhase(.recording, sessionID: session.sessionID)

            XCTAssertFalse(
                SharedDictationIntentCommandRouter.routeToKeyboardOwner(
                    .pause,
                    sessionID: session.sessionID,
                    store: intentProcess
                )
            )
            XCTAssertFalse(
                SharedDictationIntentCommandRouter.routeToggleToKeyboardOwner(
                    store: intentProcess
                )
            )
            XCTAssertEqual(engine.load().command, .none)
        }
    }

    func testOnlyOneProcessCanClaimAStaleRecordingForRecovery() throws {
        try withIsolatedSharedStores { foregroundApp, backgroundIntent in
            let session = try XCTUnwrap(
                foregroundApp.beginBackgroundSession()
            )
            foregroundApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                hasRecoverableAudio: true
            )

            XCTAssertTrue(
                backgroundIntent.transitionPhase(
                    from: [.recording],
                    to: .paused,
                    sessionID: session.sessionID,
                    hasRecoverableAudio: true
                )
            )
            XCTAssertFalse(
                foregroundApp.transitionPhase(
                    from: [.recording],
                    to: .failed,
                    sessionID: session.sessionID,
                    errorMessage: "Recovered in the app",
                    hasRecoverableAudio: true,
                    recoveryAction: .retryTranscription
                )
            )
            XCTAssertEqual(foregroundApp.load().phase, .paused)
        }
    }

    func testAbandonmentFailureCannotOverwriteAFreshHeartbeat() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                hasRecoverableAudio: true
            )
            let beforeHeartbeat = keyboard.load()
            containingApp.touch(sessionID: session.sessionID)

            XCTAssertFalse(
                keyboard.failAbandonedSession(
                    sessionID: session.sessionID,
                    phases: [.recording],
                    updatedAtOrBefore: beforeHeartbeat.updatedAt,
                    errorMessage: "Interrupted",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            )
            XCTAssertEqual(keyboard.load().phase, .recording)

            XCTAssertTrue(
                keyboard.failAbandonedSession(
                    sessionID: session.sessionID,
                    phases: [.recording],
                    updatedAtOrBefore: .distantFuture,
                    errorMessage: "Interrupted",
                    hasRecoverableAudio: true,
                    recoveryAction: .openContainingApp
                )
            )
            XCTAssertEqual(keyboard.load().phase, .failed)
            XCTAssertNil(keyboard.load().captureOwnerID)
            XCTAssertFalse(keyboard.isCaptureLeaseActive)
        }
    }

    func testElapsedDurationSurvivesPauseAndResume() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                elapsedDuration: 0,
                startedAt: Date().addingTimeInterval(-5)
            )
            containingApp.setPhase(
                .paused,
                sessionID: session.sessionID,
                elapsedDuration: 5
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID,
                elapsedDuration: 5,
                startedAt: Date()
            )

            XCTAssertEqual(keyboard.load().elapsedDuration, 5)
        }
    }

    func testActiveControlSurfaceCanAimEveryBackgroundDeliveryPhase() throws {
        let claimablePhases: [SharedDictationPhase] = [
            .starting,
            .recording,
            .pausing,
            .paused,
            .resuming,
            .transcribing,
            .completed,
        ]

        for phase in claimablePhases {
            try withIsolatedSharedStores { containingApp, keyboard in
                let session = try XCTUnwrap(
                    containingApp.beginBackgroundSession()
                )
                if phase != .starting {
                    containingApp.setPhase(
                        phase,
                        sessionID: session.sessionID,
                        transcript: phase == .completed ? "Ready" : nil
                    )
                }

                XCTAssertTrue(
                    keyboard.claimInsertionContext(
                        sessionID: session.sessionID,
                        fingerprint: "cursor-\(phase.rawValue)"
                    ),
                    "The keyboard should be able to aim a \(phase.rawValue) session"
                )
                XCTAssertEqual(
                    containingApp.load().insertionContextFingerprint,
                    "cursor-\(phase.rawValue)"
                )
            }
        }
    }

    func testStopAndInsertReclaimsCurrentCursorBeforeStop() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "resident-cursor"
                )
            )
            containingApp.setPhase(
                .recording,
                sessionID: session.sessionID
            )

            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "stop-tap-cursor",
                    replacingExistingClaim: true
                )
            )
            keyboard.send(.stop, sessionID: session.sessionID)

            let stop = containingApp.load()
            XCTAssertEqual(
                stop.insertionContextFingerprint,
                "stop-tap-cursor"
            )
            XCTAssertEqual(stop.command, .stop)
        }
    }

    func testCompletedBackgroundTranscriptKeepsExactOnceBoundary() throws {
        try withIsolatedSharedStores { containingApp, keyboard in
            let session = try XCTUnwrap(
                containingApp.beginBackgroundSession()
            )
            containingApp.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Insert exactly once"
            )

            XCTAssertTrue(
                keyboard.claimInsertionContext(
                    sessionID: session.sessionID,
                    fingerprint: "late-visible-cursor"
                )
            )
            XCTAssertTrue(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertFalse(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertEqual(
                containingApp.load().transcript,
                "Insert exactly once"
            )

            keyboard.markInserted(sessionID: session.sessionID)
            XCTAssertEqual(containingApp.load().phase, .inserted)
            XCTAssertNil(containingApp.load().transcript)
            XCTAssertFalse(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
        }
    }

    func testBackgroundSessionCannotReplaceKeyboardOwnedSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let keyboardSession = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.apple.mobilenotes"
        ))
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().sessionID, keyboardSession.sessionID)

        store.setPhase(.recording, sessionID: keyboardSession.sessionID)
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().phase, .recording)
    }

    func testKeyboardSessionCannotReplaceIntentOwnedSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let intentSession = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertNil(
            store.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )
        XCTAssertEqual(store.load().sessionID, intentSession.sessionID)
        XCTAssertEqual(store.load().phase, .starting)
    }

    func testForegroundCaptureLeaseExcludesKeyboardAndIntentRecorders() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let foregroundOwner = UUID()

        XCTAssertTrue(store.acquireCaptureLease(ownerID: foregroundOwner))
        XCTAssertTrue(store.isCaptureLeaseActive)
        XCTAssertNil(store.begin(returnBundleIdentifier: "com.openai.chat"))
        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertFalse(store.releaseCaptureLease(ownerID: UUID()))

        XCTAssertTrue(store.releaseCaptureLease(ownerID: foregroundOwner))
        let keyboard = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.openai.chat")
        )
        XCTAssertEqual(store.load().captureOwnerID, keyboard.sessionID)
        XCTAssertTrue(store.isCaptureLeaseActive)
    }

    func testKeyboardLaunchCanBeClaimedOnlyOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .starting)
    }

    func testReleasedFailureCannotBeReclaimedOrHaveItsErrorReplaced() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        let originalError = "The recording journal is unavailable."
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: originalError,
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )
        let failed = store.load()

        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load(), failed)
        XCTAssertEqual(store.load().errorMessage, originalError)
    }

    func testReleasedSetupFailureCanBeResetForAFreshAttempt() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Setup failed.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )

        XCTAssertTrue(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .idle)
        XCTAssertNotEqual(store.load().sessionID, session.sessionID)
        XCTAssertNotNil(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
    }

    func testLiveOrRecoverableFailureCannotBeResetAutomatically() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Late launch.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )

        XCTAssertFalse(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load().phase, .failed)

        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Audio saved.",
            hasRecoverableAudio: true,
            recoveryAction: .retryTranscription
        )
        XCTAssertFalse(
            store.resetNonrecoverableFailure(sessionID: session.sessionID)
        )
        XCTAssertTrue(store.load().hasRecoverableAudio == true)
    }

    func testLateLaunchCanClaimWatchdogFailureWhileLeaseIsStillLive() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "ElevenLabs did not open.",
            hasRecoverableAudio: false,
            recoveryAction: .openContainingApp
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertNil(claimed.errorMessage)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
    }

    func testLiveRecoverableFailureCannotBeClaimedAsANewLaunch() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "net.whatsapp.WhatsApp")
        )
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Audio saved.",
            hasRecoverableAudio: true,
            recoveryAction: .retryTranscription
        )
        let recoverable = store.load()

        XCTAssertNil(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )
        XCTAssertEqual(store.load(), recoverable)
        XCTAssertTrue(store.load().hasRecoverableAudio == true)
    }

    func testLegacyLaunchWithoutCaptureOwnerCanBeClaimed() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(
            store.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )
        XCTAssertTrue(
            store.releaseCaptureLease(ownerID: session.sessionID)
        )

        let claimed = try XCTUnwrap(
            store.claimLaunchingSession(sessionID: session.sessionID)
        )

        XCTAssertEqual(claimed.phase, .starting)
        XCTAssertEqual(claimed.captureOwnerID, session.sessionID)
        XCTAssertNotNil(claimed.captureLeaseUpdatedAt)
    }

    func testExpiredCaptureLeaseCannotBlockANewRecorder() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        var stale = SharedDictationSnapshot.idle
        stale.captureOwnerID = UUID()
        stale.captureLeaseUpdatedAt = Date().addingTimeInterval(-60)
        defaults.set(
            try JSONEncoder().encode(stale),
            forKey: SharedDictationConstants.storageKey
        )

        let session = try XCTUnwrap(
            SharedDictationStore(suiteName: suiteName)
                .beginBackgroundSession()
        )
        XCTAssertEqual(session.phase, .starting)
        XCTAssertEqual(session.captureOwnerID, session.sessionID)
    }

    func testBackgroundSessionPreservesTranscriptUntilInsertion() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let pending = try XCTUnwrap(store.beginBackgroundSession())
        store.setPhase(
            .completed,
            sessionID: pending.sessionID,
            transcript: "Do not lose me"
        )

        XCTAssertNil(store.beginBackgroundSession())
        XCTAssertEqual(store.load().sessionID, pending.sessionID)
        XCTAssertEqual(store.load().transcript, "Do not lose me")

        store.markHandled(sessionID: pending.sessionID)
        XCTAssertEqual(store.load().phase, .handled)
        XCTAssertNil(store.load().transcript)

        let next = try XCTUnwrap(store.beginBackgroundSession())
        XCTAssertNotEqual(next.sessionID, pending.sessionID)
        XCTAssertEqual(next.phase, .starting)
    }

    func testTwoProcessesPreserveCommandAcrossHeartbeatAndConsumeItOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: directory)
        }

        let keyboard = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: directory
        )
        let containingApp = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: directory
        )
        let session = try XCTUnwrap(
            keyboard.begin(returnBundleIdentifier: "com.apple.mobilenotes")
        )

        keyboard.send(.stop, sessionID: session.sessionID)
        containingApp.touch(sessionID: session.sessionID)

        XCTAssertEqual(containingApp.load().command, .stop)
        XCTAssertEqual(
            containingApp.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .stop
        )
        XCTAssertEqual(
            containingApp.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop]
            ),
            .none
        )
        let consumed = keyboard.load()
        XCTAssertEqual(consumed.command, .none)
        XCTAssertEqual(
            consumed.acknowledgedCommandSequence,
            consumed.commandSequence
        )
    }

    func testPendingCommandWaitsUntilOwnerCanActOnIt() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        store.send(.retry, sessionID: session.sessionID)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.stop, .cancel]
            ),
            .none
        )
        XCTAssertEqual(store.load().command, .retry)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.retry]
            ),
            .retry
        )
    }

    func testPhasePublicationPreservesUnconsumedColdLaunchRetry() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Saved for recovery",
            recoveryAction: .retryTranscription
        )
        store.send(.retry, sessionID: session.sessionID)

        // App startup restores the audio and republishes its recovery status
        // before the command monitor begins. That metadata write must not eat
        // the keyboard's already-persisted Retry tap.
        store.setPhase(
            .failed,
            sessionID: session.sessionID,
            errorMessage: "Recovered recording",
            recoveryAction: .retryTranscription
        )

        XCTAssertEqual(store.load().command, .retry)
        XCTAssertEqual(
            store.takePendingCommand(
                sessionID: session.sessionID,
                accepting: [.retry]
            ),
            .retry
        )
    }

    func testScopedResetCannotEraseANewerSession() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let first = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(.cancelled, sessionID: first.sessionID)
        let second = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))

        XCTAssertFalse(store.reset(sessionID: first.sessionID))
        XCTAssertEqual(store.load().sessionID, second.sessionID)
        XCTAssertEqual(store.load().phase, .launching)
    }

    func testCompletedPublicationFailsClosedWhenSharedStorageIsUnavailable() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let session = SharedDictationSnapshot(
            sessionID: UUID(),
            phase: .transcribing,
            command: .none,
            transcript: nil,
            errorMessage: nil,
            returnBundleIdentifier: nil,
            returnProcessIdentifier: nil,
            hostResolutionAttempts: nil,
            launchAttempts: nil,
            successfulLaunchRoute: nil,
            returnAttempts: nil,
            incomingURLDeliveryRoute: nil,
            incomingURLSourceApplication: nil,
            startedAt: Date(),
            updatedAt: Date()
        )
        defaults.set(
            try JSONEncoder().encode(session),
            forKey: SharedDictationConstants.storageKey
        )

        let invalidDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: invalidDirectory)
        defer { try? FileManager.default.removeItem(at: invalidDirectory) }
        let store = SharedDictationStore(
            suiteName: suiteName,
            storageDirectory: invalidDirectory
        )

        XCTAssertFalse(
            store.setPhase(
                .completed,
                sessionID: session.sessionID,
                transcript: "Must stay recoverable",
                historyPersisted: false
            )
        )
        XCTAssertEqual(store.load().phase, .transcribing)
        XCTAssertNil(store.load().transcript)
    }

    func testInsertionBoundaryKeepsTranscriptUntilDeliveryIsAcknowledged() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(
            returnBundleIdentifier: "com.openai.chat",
            insertionContextFingerprint: "field-before-recording"
        ))
        store.setPhase(
            .completed,
            sessionID: session.sessionID,
            transcript: "Crash-safe text"
        )

        XCTAssertTrue(store.markInsertionStarted(sessionID: session.sessionID))
        XCTAssertEqual(store.load().phase, .inserting)
        XCTAssertEqual(store.load().transcript, "Crash-safe text")
        XCTAssertEqual(store.load().recoveryAction, .reviewPossibleInsertion)
        XCTAssertNil(store.beginBackgroundSession())

        store.markInserted(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .inserted)
        XCTAssertNil(store.load().transcript)
    }

    func testInsertionAcknowledgementRejectsAnUnchangedDocumentProxy() {
        XCTAssertFalse(
            KeyboardInsertionAcknowledgementPolicy.confirmsMutation(
                insertedText: "Must not disappear",
                contextBeforeMutation: "Draft: ",
                contextAfterMutation: "Draft: ",
                documentChangeObserved: false
            )
        )
    }

    func testInsertionAcknowledgementAcceptsExpectedCursorSuffix() {
        XCTAssertTrue(
            KeyboardInsertionAcknowledgementPolicy.confirmsMutation(
                insertedText: "Delivered text",
                contextBeforeMutation: "Draft: ",
                contextAfterMutation: "Draft: Delivered text",
                documentChangeObserved: false
            )
        )
    }

    func testInsertionAcknowledgementAcceptsDocumentDelegateCallback() {
        XCTAssertTrue(
            KeyboardInsertionAcknowledgementPolicy.confirmsMutation(
                insertedText: "Delivered text",
                contextBeforeMutation: nil,
                contextAfterMutation: nil,
                documentChangeObserved: true
            )
        )
    }

    func testLegacyBlockedDeliveryAllowsExplicitRecovery() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setPhase(
            .completed,
            sessionID: session.sessionID,
            transcript: "Keep this"
        )

        store.blockDelivery(
            sessionID: session.sessionID,
            message: "The text field changed."
        )
        XCTAssertEqual(store.load().phase, .deliveryBlocked)
        XCTAssertEqual(store.load().transcript, "Keep this")
        XCTAssertEqual(store.load().recoveryAction, .insertHere)

        store.allowExplicitInsertion(sessionID: session.sessionID)
        XCTAssertEqual(store.load().phase, .completed)
        XCTAssertEqual(store.load().transcript, "Keep this")
    }

    func testInsertionBoundaryDoesNotDependOnLegacyCursorFingerprint() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.begin(
            returnBundleIdentifier: nil,
            insertionContextFingerprint: "cursor-at-stop"
        ))
        store.setPhase(
            .completed,
            sessionID: session.sessionID,
            transcript: "Insert at the live cursor"
        )

        XCTAssertTrue(store.markInsertionStarted(sessionID: session.sessionID))
        XCTAssertEqual(store.load().phase, .inserting)
        XCTAssertEqual(
            store.load().insertionContextFingerprint,
            "cursor-at-stop"
        )
        XCTAssertFalse(store.markInsertionStarted(sessionID: session.sessionID))
    }

    func testInsertionContextCanOnlyBeClaimedDuringAnActiveSessionOnce() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)
        let session = try XCTUnwrap(store.beginBackgroundSession())

        XCTAssertTrue(
            store.claimInsertionContext(
                sessionID: session.sessionID,
                fingerprint: "original-field"
            )
        )
        XCTAssertFalse(
            store.claimInsertionContext(
                sessionID: session.sessionID,
                fingerprint: "different-field"
            )
        )
        XCTAssertEqual(
            store.load().insertionContextFingerprint,
            "original-field"
        )
    }

    func testSnapshotWithoutNewCoordinationFieldsStillDecodes() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let sessionID = UUID()
        let oldSnapshot: [String: Any] = [
            "sessionID": sessionID.uuidString,
            "phase": "completed",
            "command": "none",
            "transcript": "From an older build",
            "startedAt": 0.0,
            "updatedAt": 1.0,
        ]
        defaults.set(
            try JSONSerialization.data(withJSONObject: oldSnapshot),
            forKey: SharedDictationConstants.storageKey
        )

        let decoded = SharedDictationStore(suiteName: suiteName).load()
        XCTAssertEqual(decoded.sessionID, sessionID)
        XCTAssertEqual(decoded.transcript, "From an older build")
        XCTAssertNil(decoded.revision)
        XCTAssertNil(decoded.recoveryAction)
    }

    func testSourceApplicationCanRepairMissingReturnTarget() throws {
        let suiteName = "SharedDictationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SharedDictationStore(suiteName: suiteName)

        let session = try XCTUnwrap(store.begin(returnBundleIdentifier: nil))
        store.setReturnBundleIdentifier(
            "com.apple.mobilenotes",
            sessionID: session.sessionID
        )

        XCTAssertEqual(
            store.load().returnBundleIdentifier,
            "com.apple.mobilenotes"
        )
    }

    func testLiveActivityStateRoundTripsBetweenAppAndWidget() throws {
        let state = ElevenLabsActivityAttributes.ContentState(
            phase: .recording,
            recordingStartedAt: Date(timeIntervalSince1970: 1_234),
            elapsedDuration: 18.75,
            visualizationFrame: 3,
            audioLevel: 0.68,
            meterLevels: [0.1, 0.35, 0.8, 0.42, 0.2]
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            ElevenLabsActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertEqual(decoded, state)
    }

    @MainActor
    func testForegroundControlRequestIsConsumedExactlyOnceWithoutSceneGate() {
        _ = ForegroundControlStartRequest.consume()
        ForegroundControlStartRequest.submit(
            notificationCenter: NotificationCenter()
        )

        XCTAssertTrue(ForegroundControlStartRequest.consume())
        XCTAssertFalse(ForegroundControlStartRequest.consume())
    }

    func testLiveActivityStartWaitsForObservedActiveSceneOnly() {
        XCTAssertFalse(
            LiveActivityStartReadiness.permitsRequest(
                hasObservedActiveScene: false,
                applicationIsActive: true
            )
        )
        XCTAssertFalse(
            LiveActivityStartReadiness.permitsRequest(
                hasObservedActiveScene: true,
                applicationIsActive: false
            )
        )
        XCTAssertTrue(
            LiveActivityStartReadiness.permitsRequest(
                hasObservedActiveScene: true,
                applicationIsActive: true
            )
        )
    }

    func testRecordingPreflightReusesOnlyAnActiveMatchingActivity() {
        let sessionID = UUID()

        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: sessionID,
                activityState: .active,
                contentPhase: .paused
            ),
            .reuse
        )
        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: sessionID,
                activityState: .stale,
                contentPhase: .resuming
            ),
            .reuse
        )
        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: nil,
                activityState: nil,
                contentPhase: nil
            ),
            .recreate
        )
        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: sessionID,
                activityState: .dismissed,
                contentPhase: .paused
            ),
            .recreate
        )
        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: UUID(),
                activityState: .active,
                contentPhase: .paused
            ),
            .recreate
        )
        XCTAssertEqual(
            LiveActivityRecordingPreflight.action(
                expectedSessionID: sessionID,
                activitySessionID: sessionID,
                activityState: .active,
                contentPhase: .failed
            ),
            .recreate
        )
    }

    func testLiveActivityMeterEnvelopeIsClampedAndBounded() {
        let state = ElevenLabsActivityAttributes.ContentState(
            phase: .recording,
            meterLevels: [-1] + Array(repeating: 0.5, count: 25) + [2]
        )

        XCTAssertEqual(state.meterLevels?.count, 21)
        XCTAssertEqual(state.meterLevels?.first, 0)
        XCTAssertTrue(state.meterLevels?.allSatisfy { 0...1 ~= $0 } ?? false)
    }

    func testIdleLiveActivityStateRoundTripsBetweenAppAndWidget() throws {
        let state = ElevenLabsActivityAttributes.ContentState(phase: .idle)
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            ElevenLabsActivityAttributes.ContentState.self,
            from: encoded
        )

        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.phase, .idle)
        XCTAssertNil(decoded.recordingStartedAt)
        XCTAssertEqual(decoded.elapsedDuration, 0)
    }

    func testTerminalLiveActivityPolicyReturnsClosedSessionsToLauncher() {
        XCTAssertTrue(
            ElevenLabsActivityAttributes.Phase.completed
                .returnsToIdleLauncher
        )
        XCTAssertTrue(
            ElevenLabsActivityAttributes.Phase.cancelled
                .returnsToIdleLauncher
        )
        XCTAssertFalse(
            ElevenLabsActivityAttributes.Phase.failed
                .returnsToIdleLauncher
        )
        XCTAssertFalse(
            ElevenLabsActivityAttributes.Phase.recording
                .returnsToIdleLauncher
        )
    }

    func testClosedLiveActivitySessionRejectsLateHeartbeatUpdate() {
        let sessionID = UUID()
        var gate = LiveActivitySessionGate()
        gate.begin(sessionID: sessionID)
        XCTAssertTrue(
            gate.permitsUpdate(
                sessionID: sessionID,
                persistedPhase: .recording
            )
        )

        gate.close(sessionID: sessionID)

        // This models a heartbeat that was queued before Send but resumes
        // after the terminal ActivityKit update began.
        XCTAssertFalse(
            gate.permitsUpdate(
                sessionID: sessionID,
                persistedPhase: .recording
            )
        )
        XCTAssertFalse(
            gate.permitsUpdate(
                sessionID: sessionID,
                persistedPhase: .transcribing
            )
        )
    }

    func testNewLiveActivityStateInvalidatesOlderQueuedWrite() {
        let sessionID = UUID()
        var gate = LiveActivityUpdateGate()
        gate.begin(sessionID: sessionID)

        let waveformGeneration = gate.announce(sessionID: sessionID)
        let transcribingGeneration = gate.announce(sessionID: sessionID)

        XCTAssertFalse(
            gate.permits(
                sessionID: sessionID,
                generation: waveformGeneration
            )
        )
        XCTAssertTrue(
            gate.permits(
                sessionID: sessionID,
                generation: transcribingGeneration
            )
        )
        gate.close(sessionID: sessionID)
        XCTAssertFalse(
            gate.permits(
                sessionID: sessionID,
                generation: transcribingGeneration
            )
        )
    }

    func testLiveActivitySessionGateRehydratesOnlyActiveState() {
        let recordingSessionID = UUID()
        var recordingGate = LiveActivitySessionGate()
        XCTAssertTrue(
            recordingGate.permitsUpdate(
                sessionID: recordingSessionID,
                persistedPhase: .recording
            )
        )

        let idleSessionID = UUID()
        var idleGate = LiveActivitySessionGate()
        XCTAssertFalse(
            idleGate.permitsUpdate(
                sessionID: idleSessionID,
                persistedPhase: .idle
            )
        )

        let failedSessionID = UUID()
        var failedGate = LiveActivitySessionGate()
        XCTAssertFalse(
            failedGate.permitsUpdate(
                sessionID: failedSessionID,
                persistedPhase: .failed
            )
        )
    }

    func testLiveActivityStateDecodesPayloadFromEarlierBuild() throws {
        let payload = Data(
            #"{"phase":"paused","elapsedDuration":12.5}"#.utf8
        )
        let decoded = try JSONDecoder().decode(
            ElevenLabsActivityAttributes.ContentState.self,
            from: payload
        )

        XCTAssertEqual(decoded.phase, .paused)
        XCTAssertEqual(decoded.elapsedDuration, 12.5)
        XCTAssertNil(decoded.visualizationFrame)
        XCTAssertNil(decoded.audioLevel)
        XCTAssertNil(decoded.meterLevels)
    }

    func testRealtimeDraftCanOwnInsertionWithoutBatchDuplicatingIt() throws {
        try withIsolatedSharedStores { app, keyboard in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: "com.example.host")
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.updateRealtimeTranscript(
                    "A quick live draft",
                    sessionID: session.sessionID
                )
            )
            XCTAssertTrue(
                app.setPhase(.transcribing, sessionID: session.sessionID)
            )
            XCTAssertNil(
                keyboard.claimRealtimeDraftForInsertion(
                    sessionID: session.sessionID
                )
            )
            XCTAssertTrue(
                app.setRealtimeDraftSendable(
                    true,
                    sessionID: session.sessionID
                )
            )

            XCTAssertEqual(
                keyboard.claimRealtimeDraftForInsertion(
                    sessionID: session.sessionID
                ),
                "A quick live draft"
            )
            XCTAssertEqual(keyboard.load().phase, .inserting)
            XCTAssertEqual(keyboard.load().deliverySource, .realtimeDraft)

            XCTAssertEqual(
                app.publishBatchCompletion(
                    sessionID: session.sessionID,
                    transcript: "A better batch transcript.",
                    historyPersisted: true,
                    elapsedDuration: 3
                ),
                .realtimeDeliveryOwnsSession
            )
            XCTAssertEqual(keyboard.load().phase, .inserting)
            XCTAssertEqual(keyboard.load().transcript, "A quick live draft")
            XCTAssertEqual(keyboard.load().historyPersisted, true)

            keyboard.markInserted(sessionID: session.sessionID)
            XCTAssertEqual(app.load().phase, .inserted)
            XCTAssertEqual(app.load().deliverySource, .realtimeDraft)
            XCTAssertNil(app.load().transcript)
            XCTAssertNil(app.load().realtimeTranscript)
        }
    }

    func testBatchCompletionWinsWhenRealtimeDraftWasNotClaimed() throws {
        try withIsolatedSharedStores { app, keyboard in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(.recording, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.updateRealtimeTranscript(
                    "Unfinished prev",
                    sessionID: session.sessionID
                )
            )
            XCTAssertTrue(
                app.setPhase(.transcribing, sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setRealtimeDraftSendable(
                    true,
                    sessionID: session.sessionID
                )
            )

            XCTAssertEqual(
                app.publishBatchCompletion(
                    sessionID: session.sessionID,
                    transcript: "Finished preview.",
                    historyPersisted: false,
                    elapsedDuration: 2
                ),
                .publishedBatch
            )
            XCTAssertEqual(keyboard.load().phase, .completed)
            XCTAssertEqual(keyboard.load().transcript, "Finished preview.")
            XCTAssertNil(keyboard.load().realtimeTranscript)
            XCTAssertNil(keyboard.load().deliverySource)
            XCTAssertNil(
                keyboard.claimRealtimeDraftForInsertion(
                    sessionID: session.sessionID
                )
            )
            XCTAssertTrue(
                keyboard.markInsertionStarted(sessionID: session.sessionID)
            )
            XCTAssertEqual(keyboard.load().deliverySource, .batch)
        }
    }

    func testBatchFailureAfterRealtimeDeliveryRetiresAudioOnly() throws {
        try withIsolatedSharedStores { app, keyboard in
            let session = try XCTUnwrap(
                app.begin(returnBundleIdentifier: nil)
            )
            XCTAssertNotNil(
                app.claimLaunchingSession(sessionID: session.sessionID)
            )
            XCTAssertTrue(
                app.setPhase(
                    .recording,
                    sessionID: session.sessionID,
                    hasRecoverableAudio: true
                )
            )
            XCTAssertTrue(
                app.updateRealtimeTranscript(
                    "Fast path",
                    sessionID: session.sessionID
                )
            )
            XCTAssertTrue(
                app.setPhase(
                    .transcribing,
                    sessionID: session.sessionID,
                    hasRecoverableAudio: true
                )
            )
            XCTAssertTrue(
                app.setRealtimeDraftSendable(
                    true,
                    sessionID: session.sessionID
                )
            )
            XCTAssertEqual(
                keyboard.claimRealtimeDraftForInsertion(
                    sessionID: session.sessionID
                ),
                "Fast path"
            )

            XCTAssertTrue(
                app.settleRealtimeDeliveryAfterBatchFailure(
                    sessionID: session.sessionID,
                    elapsedDuration: 4
                )
            )
            let settled = keyboard.load()
            XCTAssertEqual(settled.phase, .inserting)
            XCTAssertEqual(settled.transcript, "Fast path")
            XCTAssertEqual(settled.deliverySource, .realtimeDraft)
            XCTAssertEqual(settled.hasRecoverableAudio, false)
            XCTAssertEqual(settled.historyPersisted, false)
            XCTAssertEqual(settled.elapsedDuration, 4)
        }
    }
}
