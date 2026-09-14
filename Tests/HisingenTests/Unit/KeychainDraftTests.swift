import Foundation
import Testing
@testable import Hisingen


struct KeychainDraftTests {

    @Test
    @MainActor
    func testEmailMigratesFromUserDefaultsIntoKeychain() throws {
        let service = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? keychain.deleteEmail()
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("driver@example.invalid", forKey: "polestar_email")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)

        #expect(preferences.email == "driver@example.invalid")
        #expect(defaults.string(forKey: "polestar_email") == nil)
        try #expect(keychain.readEmail() == "driver@example.invalid")

        preferences.email = "updated@example.invalid"
        try #expect(keychain.readEmail() == "updated@example.invalid")
        #expect(defaults.string(forKey: "polestar_email") == nil)

        preferences.email = ""
        try #expect(keychain.readEmail() == nil)
    }

    @Test
    func testPasswordDraftNeverCollidesWithCommittedPassword() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deletePassword()
            try? store.deletePasswordDraft()
        }
        try store.savePassword("committed-password")
        try store.savePasswordDraft("draft-in-progress")

        try #expect(store.readPassword() == "committed-password")
        try #expect(store.readPasswordDraft() == "draft-in-progress")


        try store.deletePasswordDraft()
        try #expect(store.readPasswordDraft() == nil)
        try #expect(store.readPassword() == "committed-password")
    }

    @Test
    func testVolvoDraftsNeverCollideWithCommittedCredentials() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deleteVolvoClientSecret()
            try? store.deleteVolvoApiKey()
            try? store.deleteVolvoClientSecretDraft()
            try? store.deleteVolvoApiKeyDraft()
        }
        try store.saveVolvoClientSecret("committed-secret")
        try store.saveVolvoApiKey("committed-api-key")
        try store.saveVolvoClientSecretDraft("draft-secret")
        try store.saveVolvoApiKeyDraft("draft-api-key")

        try #expect(store.readVolvoClientSecret() == "committed-secret")
        try #expect(store.readVolvoApiKey() == "committed-api-key")
        try #expect(store.readVolvoClientSecretDraft() == "draft-secret")
        try #expect(store.readVolvoApiKeyDraft() == "draft-api-key")

        try store.deleteVolvoClientSecretDraft()
        try store.deleteVolvoApiKeyDraft()
        try #expect(store.readVolvoClientSecretDraft() == nil)
        try #expect(store.readVolvoApiKeyDraft() == nil)


        try #expect(store.readVolvoClientSecret() == "committed-secret")
        try #expect(store.readVolvoApiKey() == "committed-api-key")
    }

    @Test
    func testEmptyDraftReadsAsNilNotEmptyString() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")


        try #expect(store.readPasswordDraft() == nil)
        try #expect(store.readVolvoClientSecretDraft() == nil)
        try #expect(store.readVolvoApiKeyDraft() == nil)
    }
}

