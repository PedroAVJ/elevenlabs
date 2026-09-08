import Security
import XCTest
@testable import ElevenLabsKeychain

final class KeychainStoreTests: XCTestCase {
    func testPrivateBetaBootstrapInstallsBundledKeyBeforeFirstModelLoad() {
        var stored: String?
        var savedValues: [String] = []
        let bootstrap = PrivateBetaAPIKeyBootstrap(
            bundledValue: { "  private-beta-key\n" },
            storedValue: { stored },
            saveValue: { value in
                savedValues.append(value)
                stored = value
            }
        )

        XCTAssertEqual(bootstrap.installIfPresent(), .installed)
        XCTAssertEqual(savedValues, ["private-beta-key"])
        XCTAssertEqual(stored, "private-beta-key")
    }

    func testPrivateBetaBootstrapRotatesAnExistingKey() {
        var stored: String? = "old-key"
        let bootstrap = PrivateBetaAPIKeyBootstrap(
            bundledValue: { "new-key" },
            storedValue: { stored },
            saveValue: { stored = $0 }
        )

        XCTAssertEqual(bootstrap.installIfPresent(), .installed)
        XCTAssertEqual(stored, "new-key")
    }

    func testPrivateBetaBootstrapDoesNotRewriteCurrentKey() {
        var saveCount = 0
        let bootstrap = PrivateBetaAPIKeyBootstrap(
            bundledValue: { "current-key" },
            storedValue: { "current-key" },
            saveValue: { _ in saveCount += 1 }
        )

        XCTAssertEqual(bootstrap.installIfPresent(), .alreadyCurrent)
        XCTAssertEqual(saveCount, 0)
    }

    func testPrivateBetaBootstrapRejectsMissingAndUnexpandedValues() {
        for value in [nil, "", "$(ELEVENLABS_PRIVATE_BETA_API_KEY)", "${PRIVATE_KEY}"] {
            var saveCount = 0
            let bootstrap = PrivateBetaAPIKeyBootstrap(
                bundledValue: { value },
                storedValue: { nil },
                saveValue: { _ in saveCount += 1 }
            )

            XCTAssertEqual(bootstrap.installIfPresent(), .unavailable)
            XCTAssertEqual(saveCount, 0)
        }
    }

    func testPrivateBetaBootstrapFailsClosedWhenKeychainSaveFails() {
        struct ExpectedError: Error {}
        let bootstrap = PrivateBetaAPIKeyBootstrap(
            bundledValue: { "private-beta-key" },
            storedValue: { nil },
            saveValue: { _ in throw ExpectedError() }
        )

        XCTAssertEqual(bootstrap.installIfPresent(), .failed)
    }

    func testSaveMakesTraditionalMacStoreAuthoritativeAndSynchronizesDataProtection() throws {
        var writes: [Bool] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { _ in nil },
                upsertData: { _, query, _ in
                    writes.append(usesDataProtectionKeychain(query))
                    return errSecSuccess
                }
            )
        )

        try store.save("new-key")

        XCTAssertEqual(writes, [false, true])
    }

    func testSaveStillSucceedsWhenAdHocBuildCannotSynchronizeDataProtection() throws {
        var baseValue: String?
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "stale-signed-key" : baseValue
                },
                upsertData: { data, query, _ in
                    if usesDataProtectionKeychain(query) { return errSecMissingEntitlement }
                    baseValue = String(data: data, encoding: .utf8)
                    return errSecSuccess
                }
            )
        )

        try store.save("current-dev-key")

        XCTAssertEqual(store.load(), "current-dev-key")
    }

    func testLoadPrefersTraditionalStoreOverStaleDataProtectionValue() {
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "stale-key" : "current-key"
                }
            )
        )

        XCTAssertEqual(store.load(), "current-key")
    }

    func testLoadFallsBackToOriginalSignedServiceWithoutExposingOrReplacingItsKey() {
        var reads: [String] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecItemNotFound },
                loadString: { query in
                    let service = keychainService(query)
                    reads.append("\(service):\(usesDataProtectionKeychain(query))")
                    if service == "com.pedro.elevenlabs",
                       !usesDataProtectionKeychain(query) {
                        return "original-signed-key"
                    }
                    return nil
                }
            )
        )

        XCTAssertEqual(store.load(), "original-signed-key")
        XCTAssertEqual(
            reads,
            [
                "com.example.elevenlabs:false",
                "com.example.elevenlabs:true",
                "com.pedro.elevenlabs:false",
            ]
        )
    }

    func testDeleteAcceptsSuccessAndAlreadyMissingThenVerifiesEveryStoreIsEmpty() throws {
        var deletedDataProtectionStore = false
        var deletedFallbackStore = false
        var loadedDataProtectionStore = false
        var loadedFallbackStore = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        deletedDataProtectionStore = true
                        return errSecSuccess
                    }
                    deletedFallbackStore = true
                    return errSecItemNotFound
                },
                loadString: { query in
                    if usesDataProtectionKeychain(query) {
                        loadedDataProtectionStore = true
                    } else {
                        loadedFallbackStore = true
                    }
                    return nil
                }
            )
        )

        try store.delete()

        XCTAssertTrue(deletedDataProtectionStore)
        XCTAssertTrue(deletedFallbackStore)
        XCTAssertTrue(loadedDataProtectionStore)
        XCTAssertTrue(loadedFallbackStore)
    }

    func testDeleteAttemptsEveryStoreAndThrowsWhenEitherDeletionFails() {
        var fallbackDeleteAttempted = false
        var verificationAttempted = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        return errSecAuthFailed
                    }
                    fallbackDeleteAttempted = true
                    return errSecSuccess
                },
                loadString: { _ in
                    verificationAttempted = true
                    return nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .unexpectedDeleteStatus(errSecAuthFailed)
            )
        }
        XCTAssertTrue(fallbackDeleteAttempted)
        XCTAssertFalse(verificationAttempted)
    }

    func testDeleteReportsUnverifiableDataProtectionStoreButStillDeletesFallback() {
        var fallbackDeleteAttempted = false
        var verificationAttempted = false
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    if usesDataProtectionKeychain(query) {
                        return errSecMissingEntitlement
                    }
                    fallbackDeleteAttempted = true
                    return errSecSuccess
                },
                loadString: { _ in
                    verificationAttempted = true
                    return nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(
                error as? KeychainStoreError,
                .unexpectedDeleteStatus(errSecMissingEntitlement)
            )
        }

        XCTAssertTrue(fallbackDeleteAttempted)
        XCTAssertFalse(verificationAttempted)
    }

    func testDeleteThrowsWhenKeyRemainsAfterSuccessfulStatuses() {
        let store = KeychainStore(
            access: .init(
                deleteItem: { _ in errSecSuccess },
                loadString: { query in
                    usesDataProtectionKeychain(query) ? "still-present" : nil
                }
            )
        )

        XCTAssertThrowsError(try store.delete()) { error in
            XCTAssertEqual(error as? KeychainStoreError, .deletionVerificationFailed)
        }
    }

    func testDeleteCoversCurrentAndOriginalServiceBackends() throws {
        var deleted: [String] = []
        let store = KeychainStore(
            access: .init(
                deleteItem: { query in
                    deleted.append(
                        "\(keychainService(query)):\(usesDataProtectionKeychain(query))"
                    )
                    return errSecItemNotFound
                },
                loadString: { _ in nil }
            )
        )

        try store.delete()

        XCTAssertEqual(
            Set(deleted),
            Set([
                "com.example.elevenlabs:true",
                "com.example.elevenlabs:false",
                "com.pedro.elevenlabs:true",
                "com.pedro.elevenlabs:false",
            ])
        )
    }
}

private func usesDataProtectionKeychain(_ query: [String: Any]) -> Bool {
    query[kSecUseDataProtectionKeychain as String] as? Bool == true
}

private func keychainService(_ query: [String: Any]) -> String {
    query[kSecAttrService as String] as? String ?? ""
}
