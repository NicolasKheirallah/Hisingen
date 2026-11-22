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

    /// Two Polestar accounts with the first active, the way a switch leaves them, and the
    /// session slots then emptied the way a quit between the clear and the restore would.
    private func interruptedSwitch(label: String) throws
    -> (scoped: ScopedPreferences, first: StoredAccount) {
        let scoped = ScopedPreferences(label: label)
        let preferences = scoped.store
        preferences.email = "first@example.invalid"
        preferences.vin = "YSMREPAIR0000001"
        try scoped.keychain.saveSessionToken("token-first")
        let store = preferences.accountStore
        let first = try #require(store.activeAccount(for: .polestar))
        _ = try store.addAccount(brand: .polestar, label: "Second")
        preferences.email = "second@example.invalid"
        try scoped.keychain.saveSessionToken("token-second")
        store.commitActiveAccount()
        try store.switchTo(accountID: first.id)

        try scoped.keychain.deleteSessionToken()
        try scoped.keychain.deleteEmail()
        // The marker a switch writes before it moves secrets, still there because the quit came
        // before the switch finished.
        scoped.defaults.set(first.id, forKey: AccountStore.switchMarkerKey)
        preferences.invalidateSessionCache()
        #expect(!preferences.hasResumableSession(for: .polestar))
        return (scoped, first)
    }

    @Test
    func anInterruptedSwitchIsRepairedWhenTheStoreReopens() throws {
        let (scoped, _) = try interruptedSwitch(label: "accounts-repair-reopen")

        _ = AccountStore(preferences: scoped.store, keychain: scoped.keychain, defaults: scoped.defaults)

        #expect(try scoped.keychain.readSessionToken() == "token-first")
        #expect(scoped.store.hasResumableSession(for: .polestar))
    }

    @Test
    func switchingToTheActiveAccountRestoresEmptySlots() throws {
        let (scoped, first) = try interruptedSwitch(label: "accounts-repair-switch")
        let store = scoped.store.accountStore

        try store.switchTo(accountID: first.id)

        #expect(try scoped.keychain.readSessionToken() == "token-first")
    }

    @Test
    func anAccountThatLostItsSessionWithoutAnInterruptedSwitchIsNotRestored() throws {
        let (scoped, _) = try interruptedSwitch(label: "accounts-repair-nomarker")
        scoped.defaults.removeObject(forKey: AccountStore.switchMarkerKey)

        _ = AccountStore(preferences: scoped.store, keychain: scoped.keychain, defaults: scoped.defaults)

        #expect(try scoped.keychain.readSessionToken() == nil)
    }

    @Test
    func aFinishedSwitchLeavesNoMarkerBehind() throws {
        let scoped = ScopedPreferences(label: "accounts-marker-cleared")
        let preferences = scoped.store
        preferences.email = "first@example.invalid"
        try scoped.keychain.saveSessionToken("token-first")
        let store = preferences.accountStore
        let first = try #require(store.activeAccount(for: .polestar))
        let second = try store.addAccount(brand: .polestar, label: "Second")
        preferences.email = "second@example.invalid"
        try scoped.keychain.saveSessionToken("token-second")
        store.commitActiveAccount()

        try store.switchTo(accountID: first.id)
        #expect(scoped.defaults.string(forKey: AccountStore.switchMarkerKey) == nil)
        try store.switchTo(accountID: second.id)
        #expect(scoped.defaults.string(forKey: AccountStore.switchMarkerKey) == nil)
    }

    @Test
    func anAccountTheReaderSignedOutOfIsNotRestored() throws {
        let (scoped, _) = try interruptedSwitch(label: "accounts-repair-signout")
        scoped.store.setExplicitSignOut(for: .polestar)

        _ = AccountStore(preferences: scoped.store, keychain: scoped.keychain, defaults: scoped.defaults)

        #expect(try scoped.keychain.readSessionToken() == nil)
    }

    @Test
    func switchingToAnAccountWithAnUnreadableBundleDoesNotKeepTheOtherAccountsSession() throws {
        let scoped = ScopedPreferences(label: "accounts-bad-bundle")
        let preferences = scoped.store
        preferences.email = "first@example.invalid"
        preferences.vin = "YSMBADBUNDLE0001"
        try scoped.keychain.saveSessionToken("token-first")
        let store = preferences.accountStore
        let first = try #require(store.activeAccount(for: .polestar))
        let second = try store.addAccount(brand: .polestar, label: "Second")
        preferences.email = "second@example.invalid"
        try scoped.keychain.saveSessionToken("token-second")
        store.commitActiveAccount()
        try store.switchTo(accountID: first.id)
        try scoped.keychain.saveAccountCredentialBundle(Data("not json".utf8), accountID: second.id)

        try store.switchTo(accountID: second.id)

        #expect(store.activeAccountID(for: .polestar) == second.id)
        #expect(try scoped.keychain.readSessionToken() == nil)
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
