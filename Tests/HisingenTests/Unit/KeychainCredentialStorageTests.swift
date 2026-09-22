import Foundation
import Testing
@testable import Hisingen


@MainActor
struct KeychainCredentialStorageTests {

    @Test
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
}
