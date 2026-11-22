import Foundation
import Testing
@testable import Hisingen

/// The multi-account store and its upgrade path. Serialized because a store writes the
/// account records into the scoped defaults domain it is given, and the migration path is
/// presence-sensitive.
@Suite("Accounts", .serialized)
@MainActor
struct AccountStoreTests {
    @Test
    func anExistingInstallMigratesToItsFirstAccountWithoutTouchingTheSession() throws {
        let scoped = ScopedPreferences(label: "accounts-migration")
        let preferences = scoped.store
        preferences.email = "driver@example.invalid"
        preferences.vin = "YSMMIGRATION00001"
        try scoped.keychain.saveSessionToken("existing-refresh-token")

        let store = preferences.accountStore

        let account = try #require(store.activeAccount(for: .polestar))
        #expect(store.accounts(for: .polestar).count == 1)
        #expect(account.email == "driver@example.invalid")
        #expect(account.vin == "YSMMIGRATION00001")
        #expect(account.ownsLegacySlots)
        #expect(preferences.hasResumableSession(for: .polestar))
        #expect(try scoped.keychain.readSessionToken() == "existing-refresh-token")
        #expect(store.accounts(for: .volvo).isEmpty)
    }

    @Test
    func twoPolestarAccountsCanBeAddedAndSwitched() throws {
        let scoped = ScopedPreferences(label: "accounts-switch")
        let preferences = scoped.store
        preferences.email = "first@example.invalid"
        preferences.vin = "YSMSWITCH0000001"
        try scoped.keychain.saveSessionToken("token-first")
        let store = preferences.accountStore
        let first = try #require(store.activeAccount(for: .polestar))

        let second = try store.addAccount(brand: .polestar, label: "Second")
        preferences.email = "second@example.invalid"
        preferences.vin = "YSMSWITCH0000002"
        try scoped.keychain.saveSessionToken("token-second")
        store.commitActiveAccount()

        #expect(store.accounts(for: .polestar).count == 2)
        #expect(store.activeAccount(for: .polestar)?.label == "second@example.invalid")
        #expect(try scoped.keychain.readSessionToken() == "token-second")

        try store.switchTo(accountID: first.id)
        #expect(store.activeAccountID(for: .polestar) == first.id)
        #expect(preferences.email == "first@example.invalid")
        #expect(preferences.vin(for: .polestar) == "YSMSWITCH0000001")
        #expect(try scoped.keychain.readSessionToken() == "token-first")

        try store.switchTo(accountID: second.id)
        #expect(store.activeAccountID(for: .polestar) == second.id)
        #expect(preferences.email == "second@example.invalid")
        #expect(preferences.vin(for: .polestar) == "YSMSWITCH0000002")
        #expect(try scoped.keychain.readSessionToken() == "token-second")
    }

    @Test
    func eraseClearsEveryAccountAndItsBundle() throws {
        let scoped = ScopedPreferences(label: "accounts-erase")
        let preferences = scoped.store
        preferences.email = "erase@example.invalid"
        preferences.vin = "YSMERASE00000001"
        try scoped.keychain.saveSessionToken("erase-token")
        let store = preferences.accountStore
        _ = try store.addAccount(brand: .polestar, label: "Second")

        store.removeAll()

        #expect(store.accounts.isEmpty)
        #expect(scoped.defaults.data(forKey: AccountStore.accountsKey) == nil)
        #expect(try scoped.keychain.readEmail() == nil)
        #expect(try scoped.keychain.readSessionToken() == nil)
    }
}
