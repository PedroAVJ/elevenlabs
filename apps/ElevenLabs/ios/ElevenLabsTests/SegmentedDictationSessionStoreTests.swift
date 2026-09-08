import XCTest
@testable import ElevenLabs

final class SegmentedDictationSessionStoreTests: XCTestCase {
    func testManifestReloadPreservesParentAndSegmentOrder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parentID = UUID()
        let first = fixture.entry(duration: 1.5)
        let second = fixture.entry(duration: 2.5)

        _ = try fixture.store.create(sessionID: parentID)
        _ = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: first.id,
            ordinal: 0
        )
        _ = try fixture.store.appendFinalizedSegment(
            sessionID: parentID,
            entry: first,
            ordinal: 0,
            lifecycle: .paused
        )
        _ = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: second.id,
            ordinal: 1
        )
        _ = try fixture.store.appendFinalizedSegment(
            sessionID: parentID,
            entry: second,
            ordinal: 1,
            lifecycle: .paused
        )

        let relaunched = SegmentedDictationSessionStore(
            rootDirectory: fixture.root
        )
        let manifest = try XCTUnwrap(relaunched.load(sessionID: parentID))
        XCTAssertEqual(manifest.id, parentID)
        XCTAssertEqual(manifest.lifecycle, .paused)
        XCTAssertEqual(manifest.orderedSegments.map(\.id), [first.id, second.id])
        XCTAssertEqual(manifest.orderedSegments.map(\.ordinal), [0, 1])
        XCTAssertEqual(manifest.totalDuration, 4)
        XCTAssertNil(manifest.activeCapture)
    }

    func testCrashLeftActiveCaptureAdoptsOnlyItsMatchingJournalEntry() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parentID = UUID()
        let activeID = UUID()
        let unrelated = fixture.entry(duration: 8)
        let adopted = fixture.entry(id: activeID, duration: 0)

        _ = try fixture.store.create(sessionID: parentID)
        let recording = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: activeID,
            ordinal: 0
        )
        XCTAssertEqual(
            recording.activeCapture,
            .init(id: activeID, ordinal: 0)
        )

        let recovered = try fixture.store.adoptFinalizedActiveCapture(
            sessionID: parentID,
            from: [unrelated, adopted]
        )
        XCTAssertEqual(recovered.lifecycle, .paused)
        XCTAssertNil(recovered.activeCapture)
        XCTAssertEqual(recovered.segments.map(\.id), [activeID])
    }

    func testRecoveryGroupUsesManifestOrderInsteadOfJournalOrder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parentID = UUID()
        let first = fixture.entry(duration: 1)
        let second = fixture.entry(duration: 2)
        _ = try fixture.store.create(sessionID: parentID)
        _ = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: first.id,
            ordinal: 0
        )
        _ = try fixture.store.appendFinalizedSegment(
            sessionID: parentID,
            entry: first,
            ordinal: 0,
            lifecycle: .paused
        )
        _ = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: second.id,
            ordinal: 1
        )
        let manifest = try fixture.store.appendFinalizedSegment(
            sessionID: parentID,
            entry: second,
            ordinal: 1,
            lifecycle: .failed
        )

        let group = try fixture.store.recoveryGroup(
            for: manifest,
            journalEntries: [second, first]
        )
        XCTAssertEqual(group.entries.map(\.id), [first.id, second.id])
        XCTAssertEqual(group.manifest.id, parentID)
    }

    func testEmptyActiveCaptureClearsWithoutInventingSegment() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let parentID = UUID()
        let captureID = UUID()
        _ = try fixture.store.create(sessionID: parentID)
        _ = try fixture.store.setActiveCapture(
            sessionID: parentID,
            captureID: captureID,
            ordinal: 0
        )

        let cleared = try fixture.store.clearEmptyActiveCapture(
            sessionID: parentID,
            captureID: captureID,
            ordinal: 0,
            lifecycle: .failed
        )

        XCTAssertNil(cleared.activeCapture)
        XCTAssertTrue(cleared.segments.isEmpty)
        XCTAssertEqual(cleared.lifecycle, .failed)
        XCTAssertEqual(cleared.nextOrdinal, 0)
    }

    func testDeletingOneManifestLeavesOtherSessionIntact() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstID = UUID()
        let secondID = UUID()
        _ = try fixture.store.create(sessionID: firstID)
        _ = try fixture.store.create(sessionID: secondID)

        try fixture.store.delete(sessionID: firstID)

        XCTAssertNil(try fixture.store.load(sessionID: firstID))
        XCTAssertEqual(
            try fixture.store.load(sessionID: secondID)?.id,
            secondID
        )
        XCTAssertEqual(try fixture.store.allManifests().map(\.id), [secondID])
    }

    func testDiscardSessionDeletesOnlyItsAudioAndManifest() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let cancelledID = UUID()
        let retainedID = UUID()
        let cancelledEntry = try fixture.finalizedEntry(
            data: Data("cancel this dictation".utf8),
            duration: 1
        )
        let retainedEntry = try fixture.finalizedEntry(
            data: Data("keep this unrelated recording".utf8),
            duration: 2
        )

        _ = try fixture.store.create(sessionID: cancelledID)
        _ = try fixture.store.setActiveCapture(
            sessionID: cancelledID,
            captureID: cancelledEntry.id,
            ordinal: 0
        )
        _ = try fixture.store.appendFinalizedSegment(
            sessionID: cancelledID,
            entry: cancelledEntry,
            ordinal: 0,
            lifecycle: .cancelled
        )
        _ = try fixture.store.create(sessionID: retainedID)
        _ = try fixture.store.setActiveCapture(
            sessionID: retainedID,
            captureID: retainedEntry.id,
            ordinal: 0
        )
        _ = try fixture.store.appendFinalizedSegment(
            sessionID: retainedID,
            entry: retainedEntry,
            ordinal: 0,
            lifecycle: .paused
        )

        try fixture.store.discardSession(
            sessionID: cancelledID,
            recordingJournal: fixture.journal
        )

        XCTAssertNil(try fixture.store.load(sessionID: cancelledID))
        XCTAssertEqual(try fixture.store.load(sessionID: retainedID)?.id, retainedID)
        XCTAssertEqual(
            try fixture.journal.recoverableEntries().map(\.id),
            [retainedEntry.id]
        )
    }

    func testDiscardSessionRefusesAnActiveCapture() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let sessionID = UUID()
        _ = try fixture.store.create(sessionID: sessionID)
        _ = try fixture.store.setActiveCapture(
            sessionID: sessionID,
            captureID: UUID(),
            ordinal: 0
        )

        XCTAssertThrowsError(
            try fixture.store.discardSession(
                sessionID: sessionID,
                recordingJournal: fixture.journal
            )
        ) { error in
            XCTAssertEqual(
                error as? SegmentedDictationSessionStoreError,
                .invalidTransition
            )
        }
        XCTAssertNotNil(try fixture.store.load(sessionID: sessionID))
    }

    func testFailedSessionRepairRetiresExactEmptyCaptureAndResetsSharedState() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let shared = try fixture.makeSharedStore()
        let parent = try XCTUnwrap(shared.beginBackgroundSession())
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        _ = try fixture.store.create(
            sessionID: parent.sessionID,
            lifecycle: .failed
        )
        _ = try fixture.store.setActiveCapture(
            sessionID: parent.sessionID,
            captureID: capture.id,
            ordinal: 0,
            lifecycle: .failed
        )
        shared.setPhase(
            .failed,
            sessionID: parent.sessionID,
            errorMessage: "The microphone could not start.",
            hasRecoverableAudio: true,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(shared.releaseCaptureLease(ownerID: parent.sessionID))

        XCTAssertTrue(
            SegmentedDictationFailureRepair.resetIfProvablyEmpty(
                snapshot: shared.load(),
                sharedStore: shared,
                sessionStore: fixture.store,
                recordingJournal: fixture.journal
            )
        )

        XCTAssertEqual(shared.load().phase, .idle)
        XCTAssertNil(try fixture.store.load(sessionID: parent.sessionID))
        XCTAssertThrowsError(try fixture.journal.audioURL(for: capture)) { error in
            XCTAssertEqual(error as? RecordingJournalError, .captureMissing)
        }
    }

    func testFailedSessionRepairNeverDiscardsNonemptyCapture() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let shared = try fixture.makeSharedStore()
        let parent = try XCTUnwrap(shared.beginBackgroundSession())
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        let audio = Data("short but real speech".utf8)
        let audioURL = try fixture.journal.audioURL(for: capture)
        try audio.write(to: audioURL, options: .withoutOverwriting)
        _ = try fixture.store.create(
            sessionID: parent.sessionID,
            lifecycle: .failed
        )
        _ = try fixture.store.setActiveCapture(
            sessionID: parent.sessionID,
            captureID: capture.id,
            ordinal: 0,
            lifecycle: .failed
        )
        shared.setPhase(
            .failed,
            sessionID: parent.sessionID,
            errorMessage: "The recording was saved.",
            hasRecoverableAudio: true,
            recoveryAction: .retryTranscription
        )
        XCTAssertTrue(shared.releaseCaptureLease(ownerID: parent.sessionID))

        XCTAssertFalse(
            SegmentedDictationFailureRepair.resetIfProvablyEmpty(
                snapshot: shared.load(),
                sharedStore: shared,
                sessionStore: fixture.store,
                recordingJournal: fixture.journal
            )
        )

        XCTAssertEqual(shared.load().phase, .failed)
        XCTAssertTrue(shared.load().hasRecoverableAudio == true)
        XCTAssertEqual(try Data(contentsOf: audioURL), audio)
        XCTAssertNotNil(try fixture.store.load(sessionID: parent.sessionID))
    }

    func testFailedSessionRepairAcceptsLegacyNilKindWithExactManifestProof() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let shared = try fixture.makeSharedStore()
        let parent = try XCTUnwrap(shared.beginBackgroundSession())
        let capture = try fixture.journal.beginCapture(
            ownerProcessIdentifier: .max
        )
        _ = try fixture.store.create(
            sessionID: parent.sessionID,
            lifecycle: .failed
        )
        _ = try fixture.store.setActiveCapture(
            sessionID: parent.sessionID,
            captureID: capture.id,
            ordinal: 0,
            lifecycle: .failed
        )
        shared.setPhase(
            .failed,
            sessionID: parent.sessionID,
            errorMessage: "Legacy failed start.",
            hasRecoverableAudio: true,
            recoveryAction: .openContainingApp
        )
        XCTAssertTrue(shared.releaseCaptureLease(ownerID: parent.sessionID))
        var legacy = shared.load()
        legacy.sessionKind = nil
        try fixture.writeSharedSnapshot(legacy)
        XCTAssertNil(shared.load().sessionKind)

        XCTAssertTrue(
            SegmentedDictationFailureRepair.resetIfProvablyEmpty(
                snapshot: shared.load(),
                sharedStore: shared,
                sessionStore: fixture.store,
                recordingJournal: fixture.journal
            )
        )

        XCTAssertEqual(shared.load().phase, .idle)
        XCTAssertNil(try fixture.store.load(sessionID: parent.sessionID))
    }

    private struct Fixture {
        let baseDirectory: URL
        let sharedSuiteName: String
        let sharedDirectory: URL
        let root: URL
        let store: SegmentedDictationSessionStore
        let journal: RecordingJournal

        init() throws {
            let identifier = UUID().uuidString
            baseDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent(identifier, isDirectory: true)
            sharedSuiteName = "SegmentedDictationRepairTests-\(identifier)"
            sharedDirectory = baseDirectory.appendingPathComponent(
                "Shared",
                isDirectory: true
            )
            root = baseDirectory.appendingPathComponent(
                "Sessions",
                isDirectory: true
            )
            store = SegmentedDictationSessionStore(rootDirectory: root)
            journal = RecordingJournal(
                rootDirectory: baseDirectory.appendingPathComponent(
                    "Journal",
                    isDirectory: true
                )
            )
        }

        func makeSharedStore() throws -> SharedDictationStore {
            guard let defaults = UserDefaults(suiteName: sharedSuiteName) else {
                throw SegmentedDictationSessionStoreError.unavailable
            }
            defaults.removePersistentDomain(forName: sharedSuiteName)
            return SharedDictationStore(
                suiteName: sharedSuiteName,
                storageDirectory: sharedDirectory
            )
        }

        func writeSharedSnapshot(
            _ snapshot: SharedDictationSnapshot
        ) throws {
            try FileManager.default.createDirectory(
                at: sharedDirectory,
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(snapshot).write(
                to: sharedDirectory.appendingPathComponent(
                    SharedDictationConstants.stateFileName
                ),
                options: .atomic
            )
        }

        func entry(
            id: UUID = UUID(),
            duration: TimeInterval
        ) -> RecordingJournalEntry {
            RecordingJournalEntry(
                id: id,
                createdAt: Date(),
                duration: duration,
                byteCount: 128,
                audioFileExtension: "m4a"
            )
        }

        func finalizedEntry(
            data: Data,
            duration: TimeInterval
        ) throws -> RecordingJournalEntry {
            let capture = try journal.beginCapture(
                ownerProcessIdentifier: .max
            )
            try data.write(
                to: journal.audioURL(for: capture),
                options: .withoutOverwriting
            )
            return try journal.finalizeCapture(capture, duration: duration)
        }

        func cleanUp() {
            UserDefaults(suiteName: sharedSuiteName)?
                .removePersistentDomain(forName: sharedSuiteName)
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }
}
