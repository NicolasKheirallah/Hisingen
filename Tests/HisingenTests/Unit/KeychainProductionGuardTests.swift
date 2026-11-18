import Foundation
import Testing
@testable import Hisingen

/// A test that builds a store on the default Keychain once overwrote the developer's real
/// Polestar email with `test@example.invalid`. The production items are off limits to tests.
struct KeychainProductionGuardTests {
    @Test func testsCannotWriteTheProductionKeychainItems() {
        let production = KeychainStore.app
        #expect(throws: KeychainError.self) { try production.saveEmail("test@example.invalid") }
        #expect(throws: KeychainError.self) { try production.deleteEmail() }
    }

    @Test func aDefaultConstructedPreferencesStoreDoesNotPersistAnEmail() throws {
        let suite = "KeychainProductionGuardTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.email = "test@example.invalid"
        #expect(defaults.string(forKey: "polestar_email") == nil)
        #expect(throws: KeychainError.self) { _ = try KeychainStore.app.saveEmail("x@example.invalid") }
    }
}
