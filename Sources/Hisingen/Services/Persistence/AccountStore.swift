import Foundation
import OSLog

/// One account Hisingen keeps for a brand. Secrets never live here: the record holds identity
/// and the non-secret preferences that belong to the account, while an exported credential
/// bundle sits in the Keychain under the account id.
struct StoredAccount: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var brand: VehicleBrand
    var label: String
    var email: String
    var vin: String
    var knownVINs: [String]
    var connectionMode: String
    var dataPortalAccountID: String
    var dataPortalClientID: String
    var volvoClientID: String
    var volvoSessionIdentity: String
    var volvoRestrictedScopesEnabled: Bool
    var createdAt: Date
    /// The account that inherited the pre-multi-account Keychain slots when the store migrated.
    /// Its secrets are already in the active slots; no copy is read at migration time.
    var ownsLegacySlots: Bool
}

/// The credential values that move with an account. Exported only on an explicit switch or
/// account update, so launch and migration never touch a Keychain prompt.
private struct AccountCredentials: Codable {
    var email: String?
    var password: String?
    var polestarSession: String?
    var polestarCommandSession: String?
    var volvoClientSecret: String?
    var volvoAPIKey: String?
    var volvoSession: String?
    var portalAccountID: String?
    var portalClientID: String?
    var portalClientSecret: String?
    var portalToken: String?
}

/// Multiple accounts per brand, with the active account's credentials occupying the fixed
/// Keychain slots every provider already reads. Adding or switching accounts moves the exported
/// bundle; single-account installs keep their existing slots untouched and become account one.
///
/// The store owns the records and the switch sequence; it does not drive sign-in. The app calls
/// `commitActiveAccount()` after a successful sign-in so the account's identity and secrets are
/// captured for the next switch.
@MainActor
final class AccountStore {
    private let logger = AppLog.logger("accounts")
    private let preferences: PreferencesStore
    private let keychain: KeychainStore
    private let defaults: UserDefaults
    private(set) var accounts: [StoredAccount] = []

    static let accountsKey = "accounts_v1"

    init(preferences: PreferencesStore, keychain: KeychainStore = .app,
         defaults: UserDefaults = .standard) {
        self.preferences = preferences
        self.keychain = keychain
        self.defaults = defaults
        loadOrMigrate()
        repairInterruptedSwitches()
    }

    // MARK: - Reads

    func accounts(for brand: VehicleBrand) -> [StoredAccount] {
        accounts.filter { $0.brand == brand }
    }

    func account(id: String) -> StoredAccount? {
        accounts.first { $0.id == id }
    }

    func activeAccountID(for brand: VehicleBrand) -> String? {
        if let stored = defaults.string(forKey: activeKey(for: brand)),
           accounts.contains(where: { $0.id == stored && $0.brand == brand }) {
            return stored
        }
        let first = accounts(for: brand).first
        if let first { defaults.set(first.id, forKey: activeKey(for: brand)) }
        return first?.id
    }

    func activeAccount(for brand: VehicleBrand) -> StoredAccount? {
        activeAccountID(for: brand).flatMap(account(id:))
    }

    // MARK: - Adding and switching

    /// Captures the current active account, then makes a fresh empty account active so the
    /// existing sign-in form can fill it. The previous account keeps its record and secrets.
    @discardableResult
    func addAccount(brand: VehicleBrand, label: String) throws -> StoredAccount {
        try captureActiveAccountIfNeeded()
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let account = StoredAccount(
            id: UUID().uuidString,
            brand: brand,
            label: trimmed.isEmpty ? brand.displayName : trimmed,
            email: "",
            vin: "",
            knownVINs: [],
            connectionMode: PreferencesStore.PolestarConnectionMode.polestarID.rawValue,
            dataPortalAccountID: "",
            dataPortalClientID: "",
            volvoClientID: "",
            volvoSessionIdentity: VolvoIdentityProvider.legacy.rawValue,
            volvoRestrictedScopesEnabled: true,
            createdAt: Date(),
            ownsLegacySlots: false)
        accounts.append(account)
        defaults.set(account.id, forKey: activeKey(for: brand))
        try clearCredentials(for: brand)
        apply(account)
        preferences.invalidateSessionCache()
        save()
        return account
    }

    /// Switches the active account. The current account's secrets are exported first; the
    /// target's bundle then replaces the fixed slots, so every existing provider path reads the
    /// newly selected account without knowing accounts exist.
    func switchTo(accountID: String) throws {
        guard let target = account(id: accountID) else {
            throw AccountStoreError.unknownAccount
        }
        if activeAccountID(for: target.brand) == target.id {
            // The account already owns this brand's slots; only the active brand moves.
            preferences.activeBrand = target.brand
            apply(target)
            try restoreIfSlotsAreEmpty(for: target)
            preferences.invalidateSessionCache()
            save()
            return
        }
        try captureActiveAccountIfNeeded()
        // The brand being switched may not be the active brand. Its current account's
        // credentials still occupy that brand's slots, so capture them before replacing them.
        if let current = activeAccount(for: target.brand) {
            try captureCredentials(into: current.id, brand: target.brand)
        }
        // `restoreCredentials` clears the brand's slots itself, right before it writes the
        // target's bundle. Clearing earlier would leave a longer stretch with empty slots.
        defaults.set(target.id, forKey: activeKey(for: target.brand))
        preferences.activeBrand = target.brand
        apply(target)
        try restoreCredentials(for: target)
        preferences.invalidateSessionCache()
        save()
    }

    /// Called after an interactive sign-in (or a credential save) so the active account's
    /// identity and secrets match what was just written.
    func commitActiveAccount() {
        let brand = preferences.activeBrand
        do {
            guard let active = activeAccount(for: brand) else {
                // A fresh install signs in before any account record exists.
                let created = recordFromCurrentState(brand: brand, label: "")
                accounts.append(created)
                defaults.set(created.id, forKey: activeKey(for: brand))
                try captureCredentials(into: created.id, brand: brand)
                save()
                return
            }
            var updated = recordFromCurrentState(brand: brand, label: active.label)
            updated.id = active.id
            updated.createdAt = active.createdAt
            updated.ownsLegacySlots = active.ownsLegacySlots
            updated.label = resolvedLabel(brand: brand, fallback: active.label)
            if let index = accounts.firstIndex(where: { $0.id == active.id }) {
                accounts[index] = updated
            }
            try captureCredentials(into: active.id, brand: brand)
            save()
            preferences.invalidateSessionCache()
        } catch {
            logger.error("Capturing the active account failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Removing and erasing

    func removeAccount(id: String) throws {
        guard let target = account(id: id) else { return }
        try? keychain.deleteAccountCredentialBundle(accountID: id)
        let wasActive = activeAccountID(for: target.brand) == id
        accounts.removeAll { $0.id == id }
        defaults.removeObject(forKey: activeKey(for: target.brand))

        if wasActive {
            if let replacement = accounts(for: target.brand).first {
                defaults.set(replacement.id, forKey: activeKey(for: target.brand))
                try clearCredentials(for: target.brand)
                preferences.activeBrand = target.brand
                apply(replacement)
                try restoreCredentials(for: replacement)
            } else {
                try clearCredentials(for: target.brand)
                clearBrandState(target.brand)
                if preferences.activeBrand == target.brand,
                   let otherBrand = VehicleBrand.allCases.first(where: { !accounts(for: $0).isEmpty }) {
                    preferences.activeBrand = otherBrand
                    if let replacement = accounts(for: otherBrand).first {
                        apply(replacement)
                        try restoreCredentials(for: replacement)
                    }
                }
            }
            preferences.invalidateSessionCache()
        }
        save()
    }

    /// Erase every account and every exported bundle. The active slots go too, so an erase
    /// cannot leave one account's credentials behind in the Keychain.
    func removeAll() {
        for account in accounts {
            try? keychain.deleteAccountCredentialBundle(accountID: account.id)
        }
        accounts = []
        for brand in VehicleBrand.allCases {
            defaults.removeObject(forKey: activeKey(for: brand))
        }
        defaults.removeObject(forKey: Self.accountsKey)
        for brand in VehicleBrand.allCases { try? clearCredentials(for: brand) }
        preferences.invalidateSessionCache()
    }

    // MARK: - Migration

    private func loadOrMigrate() {
        if let data = defaults.data(forKey: Self.accountsKey),
           let decoded = try? JSONDecoder().decode([StoredAccount].self, from: data),
           !decoded.isEmpty {
            accounts = decoded
            return
        }
        accounts = []
        for brand in VehicleBrand.allCases where hasLegacyAccountData(for: brand) {
            let account = recordFromCurrentState(brand: brand, label: "")
            accounts.append(account)
            if preferences.activeBrand == brand || activeAccountID(for: brand) == nil {
                defaults.set(account.id, forKey: activeKey(for: brand))
            }
        }
        if !accounts.isEmpty {
            // The migrated account's credentials are already in the fixed slots; do not read
            // them here. The first switch away captures them into the account bundle.
            save()
        }
    }

    /// Presence-only evidence. No secret is read, so upgrading does not trigger a Keychain
    /// prompt and a signed-in installation keeps its session untouched.
    private func hasLegacyAccountData(for brand: VehicleBrand) -> Bool {
        switch brand {
        case .polestar:
            return !preferences.email.isEmpty
                || !preferences.vin(for: .polestar).isEmpty
                || !preferences.polestarDataPortalClientID.isEmpty
                || !preferences.polestarDataPortalAccountID.isEmpty
                || preferences.hasResumableSession(for: .polestar)
        case .volvo:
            // `preferences.volvoClientID` falls back to the built-in developer client. Only a
            // stored client id proves the reader configured an account.
            let storedClientID = defaults.string(forKey: "volvo_client_id") ?? ""
            return !preferences.vin(for: .volvo).isEmpty
                || !storedClientID.isEmpty
                || preferences.hasResumableSession(for: .volvo)
        }
    }

    // MARK: - Interrupted switches

    /// A switch moves secrets in several Keychain writes. If the app quits or a write fails after
    /// the old slots are cleared, the target account is active with empty slots, and its bundle
    /// still holds the credentials. Called at launch and when switching to the account that is
    /// already active.
    ///
    /// Nothing is restored for an account the reader signed out of, or when no bundle exists. An
    /// account that has a resumable session already is left alone, so the common launch reads no
    /// secret at all.
    private func restoreIfSlotsAreEmpty(for account: StoredAccount) throws {
        guard !preferences.hasResumableSession(for: account.brand),
              !preferences.hasExplicitSignOut(for: account.brand) else { return }
        try restoreCredentials(for: account)
        preferences.invalidateSessionCache()
    }

    private func repairInterruptedSwitches() {
        for brand in VehicleBrand.allCases {
            guard let active = activeAccount(for: brand) else { continue }
            do {
                try restoreIfSlotsAreEmpty(for: active)
            } catch {
                logger.error("Restoring an interrupted account switch failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Credential movement

    private func captureActiveAccountIfNeeded() throws {
        let brand = preferences.activeBrand
        guard let active = activeAccount(for: brand) else { return }
        var updated = recordFromCurrentState(brand: brand, label: active.label)
        updated.id = active.id
        updated.createdAt = active.createdAt
        updated.ownsLegacySlots = active.ownsLegacySlots
        if let index = accounts.firstIndex(where: { $0.id == active.id }) {
            accounts[index] = updated
        }
        try captureCredentials(into: active.id, brand: brand)
        save()
    }

    private func captureCredentials(into accountID: String, brand: VehicleBrand) throws {
        var bundle = AccountCredentials()
        switch brand {
        case .polestar:
            bundle.email = try keychain.readEmail()
            bundle.password = try keychain.readPassword()
            bundle.polestarSession = try keychain.readSessionToken()
            bundle.polestarCommandSession = try keychain.readCommandSessionToken()
            bundle.portalAccountID = try keychain.readPolestarDataPortalAccountID()
            bundle.portalClientID = try keychain.readPolestarDataPortalClientID()
            bundle.portalClientSecret = try keychain.readPolestarDataPortalClientSecret()
            bundle.portalToken = try keychain.readPolestarDataPortalToken()
        case .volvo:
            bundle.volvoClientSecret = try keychain.readVolvoClientSecret()
            bundle.volvoAPIKey = try keychain.readVolvoApiKey()
            bundle.volvoSession = try keychain.readVolvoSessionToken()
        }
        let data = try JSONEncoder().encode(bundle)
        try keychain.saveAccountCredentialBundle(data, accountID: accountID)
    }

    private func restoreCredentials(for account: StoredAccount) throws {
        guard let data = try keychain.readAccountCredentialBundle(accountID: account.id),
              let bundle = try? JSONDecoder().decode(AccountCredentials.self, from: data) else {
            return
        }
        try clearCredentials(for: account.brand)
        switch account.brand {
        case .polestar:
            try save(bundle.email, using: keychain.saveEmail)
            try save(bundle.password, using: keychain.savePassword)
            try save(bundle.polestarSession, using: keychain.saveSessionToken)
            try save(bundle.polestarCommandSession, using: keychain.saveCommandSessionToken)
            if let id = bundle.portalClientID, !id.isEmpty {
                try keychain.savePolestarDataPortalCredentials(
                    accountID: bundle.portalAccountID,
                    clientID: id,
                    clientSecret: bundle.portalClientSecret ?? "")
            }
            try save(bundle.portalToken, using: keychain.savePolestarDataPortalToken)
        case .volvo:
            try save(bundle.volvoClientSecret, using: keychain.saveVolvoClientSecret)
            try save(bundle.volvoAPIKey, using: keychain.saveVolvoApiKey)
            try save(bundle.volvoSession, using: keychain.saveVolvoSessionToken)
        }
    }

    private func clearCredentials(for brand: VehicleBrand) throws {
        switch brand {
        case .polestar:
            try? keychain.deleteEmail()
            try? keychain.deletePassword()
            try? keychain.deleteSessionToken()
            try? keychain.deleteCommandSessionToken()
            try? keychain.deletePolestarDataPortalCredentials()
            try? keychain.deletePolestarDataPortalToken()
        case .volvo:
            try? keychain.deleteVolvoClientSecret()
            try? keychain.deleteVolvoApiKey()
            try? keychain.deleteVolvoSessionToken()
        }
    }

    private func save(_ value: String?, using write: (String) throws -> Void) throws {
        guard let value, !value.isEmpty else { return }
        try write(value)
    }

    // MARK: - Records

    private func recordFromCurrentState(brand: VehicleBrand, label: String) -> StoredAccount {
        let vin = preferences.vin(for: brand)
        return StoredAccount(
            id: UUID().uuidString,
            brand: brand,
            label: resolvedLabel(brand: brand, fallback: label),
            email: brand == .polestar ? preferences.email : "",
            vin: vin,
            knownVINs: preferences.knownVINs(for: brand),
            connectionMode: preferences.polestarConnectionMode.rawValue,
            dataPortalAccountID: preferences.polestarDataPortalAccountID,
            dataPortalClientID: preferences.polestarDataPortalClientID,
            volvoClientID: preferences.volvoClientID,
            volvoSessionIdentity: preferences.volvoSessionIdentity.rawValue,
            volvoRestrictedScopesEnabled: preferences.volvoRestrictedScopesEnabled,
            createdAt: Date(),
            ownsLegacySlots: true)
    }

    private func resolvedLabel(brand: VehicleBrand, fallback: String) -> String {
        let email = brand == .polestar ? preferences.email : ""
        if !email.isEmpty { return email }
        let vin = preferences.vin(for: brand)
        if !vin.isEmpty {
            let nickname = preferences.vehicleNickname(for: vin)
            if !nickname.isEmpty { return nickname }
            return vin
        }
        let trimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? brand.displayName : trimmed
    }

    private func apply(_ account: StoredAccount) {
        preferences.activeBrand = account.brand
        switch account.brand {
        case .polestar:
            preferences.email = account.email
            preferences.polestarConnectionMode = PreferencesStore.PolestarConnectionMode(
                rawValue: account.connectionMode) ?? .polestarID
            preferences.polestarDataPortalAccountID = account.dataPortalAccountID
            preferences.polestarDataPortalClientID = account.dataPortalClientID
        case .volvo:
            preferences.volvoClientID = account.volvoClientID
            preferences.volvoSessionIdentity = VolvoIdentityProvider(
                rawValue: account.volvoSessionIdentity) ?? .legacy
            preferences.volvoRestrictedScopesEnabled = account.volvoRestrictedScopesEnabled
        }
        preferences.clearKnownVINs(for: account.brand)
        preferences.rememberKnownVINs(account.knownVINs, for: account.brand)
        preferences.setVin(account.vin, for: account.brand)
    }

    private func clearBrandState(_ brand: VehicleBrand) {
        preferences.setVin("", for: brand)
        preferences.clearKnownVINs(for: brand)
        preferences.clearDetachedVehicles(for: brand)
        if brand == .polestar {
            preferences.email = ""
            preferences.polestarDataPortalAccountID = ""
            preferences.polestarDataPortalClientID = ""
        } else {
            preferences.volvoClientID = ""
        }
        preferences.invalidateSessionCache()
    }

    // MARK: - Persistence

    private func activeKey(for brand: VehicleBrand) -> String {
        "active_account_v1_\(brand.rawValue)"
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        defaults.set(data, forKey: Self.accountsKey)
    }
}

enum AccountStoreError: Error, Equatable {
    case unknownAccount
}
