import Foundation
import Security
import Testing
@testable import Hisingen

private final class RecordingKeychainSecurity: KeychainSecurity, @unchecked Sendable {
    var dpReadStatus: OSStatus = errSecItemNotFound
    var legacyReadStatus: OSStatus = errSecSuccess
    var dpWriteStatus: OSStatus = errSecMissingEntitlement
    var legacyValue: Data? = Data("saved-token".utf8)
    var reads = 0
    var legacyReads = 0
    var legacyDeletes = 0
    var writes = 0

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        reads += 1
        if query[kSecUseDataProtectionKeychain as String] as? Bool == true {
            return (dpReadStatus, dpReadStatus == errSecSuccess ? legacyValue : nil)
        }
        legacyReads += 1
        return (legacyReadStatus, legacyValue)
    }
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        writes += 1
        return query[kSecUseDataProtectionKeychain as String] as? Bool == true
            ? dpWriteStatus : errSecSuccess
    }
    func add(_ attributes: [String: Any]) -> OSStatus { errSecSuccess }
    func delete(_ query: [String: Any]) -> OSStatus {
        if query[kSecUseDataProtectionKeychain as String] as? Bool != true {
            legacyDeletes += 1
            legacyValue = nil
        }
        return errSecSuccess
    }
}

struct KeychainMigrationTests {
    private func store(_ security: RecordingKeychainSecurity) -> KeychainStore {
        // This service deliberately exercises the injected Security boundary.
        KeychainStore(service: "migration-regression.\(UUID())", security: security)
    }

    @Test func unavailableDestinationPreservesLegacyCredential() throws {
        let security = RecordingKeychainSecurity()
        let keychain = store(security)
        #expect(try keychain.readSessionToken() == "saved-token")
        #expect(security.legacyDeletes == 0)
        #expect(security.legacyValue != nil)
        #expect(try keychain.readSessionToken() == "saved-token")
        #expect(security.legacyReads == 1)
    }

    @Test func successfulMigrationDeletesLegacyOnlyAfterDestinationWrite() throws {
        let security = RecordingKeychainSecurity()
        security.dpWriteStatus = errSecSuccess
        #expect(try store(security).readSessionToken() == "saved-token")
        #expect(security.writes == 1)
        #expect(security.legacyDeletes == 1)
    }

    @Test func deniedReadDoesNotTryAnotherKeychain() {
        let security = RecordingKeychainSecurity()
        security.dpReadStatus = errSecUserCanceled
        #expect(throws: (any Error).self) { try store(security).readSessionToken() }
        #expect(security.legacyReads == 0)
        #expect(security.writes == 0)
    }

    @Test func deniedLegacyBundleDoesNotReadOrOverwriteIndividualCredentials() {
        let security = RecordingKeychainSecurity()
        security.legacyReadStatus = errSecAuthFailed
        #expect(throws: (any Error).self) { try store(security).saveVolvoApiKey("replacement") }
        #expect(security.legacyReads == 1)
        #expect(security.writes == 0)
    }

    @Test func missingCredentialIsCachedUntilSaved() throws {
        let security = RecordingKeychainSecurity()
        security.legacyReadStatus = errSecItemNotFound
        let keychain = store(security)
        #expect(try keychain.readSessionToken() == nil)
        #expect(try keychain.readSessionToken() == nil)
        #expect(security.reads == 2)
        try keychain.saveSessionToken("replacement")
        #expect(try keychain.readSessionToken() == "replacement")
    }

    @Test func deniedWriteDoesNotFallBackToLegacy() {
        let security = RecordingKeychainSecurity()
        security.dpWriteStatus = errSecAuthFailed
        #expect(throws: (any Error).self) { try store(security).saveSessionToken("replacement") }
        #expect(security.writes == 1)
    }
}
