import Foundation
import Security
import Testing
@testable import Hisingen

/// A `KeychainSecurity` that answers from memory and records the operation order, so the
/// model's save paths can be observed without touching the real keychain. Named accounts
/// in `failingAccounts` are denied with `errSecInteractionRequired`, the status a pending
/// ACL consent prompt produces, so denial paths exercise the same error shape as prod.
private final class ScriptedKeychainSecurity: KeychainSecurity, @unchecked Sendable {
    let failingAccounts: Set<String>
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    var operations: [String] = []

    init(failingAccounts: Set<String> = []) {
        self.failingAccounts = failingAccounts
    }

    private func account(of query: [String: Any]) -> String? {
        query[kSecAttrAccount as String] as? String
    }

    func copy(_ query: [String: Any]) -> (OSStatus, Data?) {
        let account = account(of: query) ?? "?"
        lock.lock()
        operations.append("copy:\(account)")
        let data = items[account]
        lock.unlock()
        if let data { return (errSecSuccess, data) }
        return (errSecItemNotFound, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        let account = account(of: query) ?? "?"
        lock.lock()
        operations.append("update:\(account)")
        defer { lock.unlock() }
        if failingAccounts.contains(account) { return errSecInteractionRequired }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        let account = attributes[kSecAttrAccount as String] as? String ?? "?"
        lock.lock()
        operations.append("add:\(account)")
        defer { lock.unlock() }
        if failingAccounts.contains(account) { return errSecInteractionRequired }
        items[account] = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        let account = account(of: query) ?? "?"
        lock.lock()
        operations.append("delete:\(account)")
        defer { lock.unlock() }
        items.removeValue(forKey: account)
        return errSecSuccess
    }

    func storedValue(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return items[account].flatMap { String(data: $0, encoding: .utf8) }
    }
}

@MainActor
struct AccountConnectionModelTests {
    private let passwordAccount = "polestar-password"
    private let portalBundleAccount = "polestar-dataportal-credentials"

    /// A store and model wired to the same scripted keychain, so a save's full sequence —
    /// the model's secret writes and the store's identity writes — lands in one recording.
    private func makeScriptedPair(label: String, failingAccounts: Set<String> = [])
        -> (model: AccountConnectionModel, store: PreferencesStore, security: ScriptedKeychainSecurity, suite: String) {
        let suite = "HisingenTests.\(label).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let security = ScriptedKeychainSecurity(failingAccounts: failingAccounts)
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.scripted.\(UUID().uuidString)", security: security)
        let store = PreferencesStore(defaults: defaults, keychain: keychain)
        return (AccountConnectionModel(preferences: store, keychain: keychain), store, security, suite)
    }

    /// Presence bits read and write `UserDefaults.standard` even for throwaway keychain
    /// services, so every test that flips them snapshots and restores the full set. The
    /// suite runs serially, which is what makes the snapshot itself race-free.
    private func withPresenceFlags<T>(_ body: () throws -> T) rethrows -> T {
        let keys = ["has_polestar_email", "has_polestar_password", "has_polestar_session",
                    "has_polestar_cmd_session", "has_volvo_session", "has_volvo_client_secret",
                    "has_polestar_dataportal_credentials"]
        let saved = keys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        for key in keys { UserDefaults.standard.removeObject(forKey: key) }
        return try body()
    }

    // MARK: - Health

    @Test
    func connectedBrandWithAuthFamilyFailureReadsSessionExpired() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-health-auth")
            UserDefaults.standard.set(true, forKey: "has_polestar_session")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)

            let authFailure = ConnectionCheck(success: false, message: "anything", failureKind: .sessionExpired)
            #expect(model.health(for: .polestar, isActiveBrand: true, lastCheck: authFailure) == .sessionExpired)

            let transient = ConnectionCheck(success: false, message: "offline", failureKind: .transient)
            #expect(model.health(for: .polestar, isActiveBrand: true, lastCheck: transient) == .active)
        }
    }

    @Test
    func expiredRenewableBeatsNeverConnected() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-health-renewable")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)

            // Nothing on file: never set up.
            #expect(model.health(for: .polestar, isActiveBrand: false, lastCheck: nil) == .notConnected)

            // Email present plus a known VIN: the browser handshake can renew alone.
            UserDefaults.standard.set(true, forKey: "has_polestar_email")
            scoped.store.setVin("YSMTESTVNN0000001", for: .polestar)
            #expect(model.health(for: .polestar, isActiveBrand: false, lastCheck: nil) == .sessionExpired)
            #expect(model.isRenewable(.polestar))
        }
    }

    @Test
    func volvoRenewabilityNeedsClientIDAndAppCredentials() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-health-volvo")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            scoped.store.setVin("YV1TESTVNN0000001", for: .volvo)

            // The app-credentials presence bit is derived from the test service's store.
            // Built-in developer keys may or may not be compiled into this build; when they
            // are, the brand is renewable before anything is stored.
            if !BuiltinVolvoSecrets.isConfigured {
                #expect(model.isRenewable(.volvo) == false)
            }
            try? scoped.keychain.saveVolvoClientSecret("s")
            try? scoped.keychain.saveVolvoApiKey("k")
            #expect(model.isRenewable(.volvo) == true)
        }
    }

    // MARK: - Draft seeding

    @Test
    func seedTakesStoreValuesButTypedValuesSurvive() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-seed")
            scoped.store.setVin("YSMTESTVNN0000002", for: .polestar)
            scoped.store.setVehicleNickname("Midnight", for: "YSMTESTVNN0000002")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)

            model.seedDraftFromStore()
            #expect(model.draft.polestarVIN == "YSMTESTVNN0000002")
            #expect(model.draft.polestarNickname == "Midnight")

            model.draft.polestarNickname = "Typed name"
            model.seedDraftFromStore()
            #expect(model.draft.polestarNickname == "Typed name")

            // Write-only secrets are never seeded from the Keychain.
            #expect(model.draft.polestarPassword.isEmpty)
            #expect(model.draft.polestarDataPortalClientSecret.isEmpty)
        }
    }

    // MARK: - Polestar saves

    @Test
    func polestarIDSavePersistsPasswordBeforeIdentity() {
        withPresenceFlags {
            let (model, store, security, suite) = makeScriptedPair(label: "acm-order")
            defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
            model.draft.polestarEmail = " driver@example.com "
            model.draft.polestarPassword = "s3cret"
            model.draft.polestarVIN = " ysmtestvnn0000003 "
            model.draft.polestarNickname = "Night"

            let outcome = model.savePolestar(mode: .polestarID)

            #expect(outcome?.saved == true)
            #expect(outcome?.effect == .credentialsChanged)
            #expect(outcome?.keychainError == nil)
            // The plaintext leaves the draft once the Keychain holds it.
            #expect(model.draft.polestarPassword.isEmpty)
            // The password *write* precedes the email *write*: a Keychain denial must not
            // leave an email pointing at credentials that never landed. Reads (the store
            // resolving its cached email) are not part of the ordering.
            let isWrite = { (op: String) in op.hasPrefix("add:") || op.hasPrefix("update:") }
            guard let firstPasswordWrite = security.operations.firstIndex(where: { isWrite($0) && $0.hasSuffix(passwordAccount) }),
                  let firstEmailWrite = security.operations.firstIndex(where: { isWrite($0) && $0.contains("polestar-email") }) else {
                Issue.record("expected both writes recorded, got \(security.operations)")
                return
            }
            #expect(firstPasswordWrite < firstEmailWrite)
            // Identity is normalized: trimmed email, upper-cased VIN.
            #expect(security.storedValue(for: passwordAccount) == "s3cret")
            #expect(store.email == "driver@example.com")
            #expect(store.vin(for: .polestar) == "YSMTESTVNN0000003")
            #expect(store.vehicleNickname(for: "YSMTESTVNN0000003") == "Night")
        }
    }

    @Test
    func keychainDenialLeavesIdentityUnwritten() {
        withPresenceFlags {
            let (model, store, security, suite) = makeScriptedPair(label: "acm-denial",
                                                                   failingAccounts: [passwordAccount])
            defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
            model.draft.polestarEmail = "driver@example.com"
            model.draft.polestarPassword = "s3cret"
            model.draft.polestarVIN = "YSMTESTVNN0000004"

            let outcome = model.savePolestar(mode: .polestarID)

            #expect(outcome?.saved == false)
            #expect(outcome?.effect == nil)
            #expect(outcome?.keychainError != nil)
            // The denial must not leave email/VIN pointing at credentials that were not saved.
            #expect(store.email.isEmpty)
            #expect(store.vin(for: .polestar).isEmpty)
            // A denied password also stays out of the store's memory mirror.
            #expect(security.storedValue(for: passwordAccount) == nil)
        }
    }

    @Test
    func augmentedSaveSurfacesPasswordDenialEvenWhenPortalSucceeds() {
        withPresenceFlags {
            let (model, store, security, suite) = makeScriptedPair(label: "acm-augmented",
                                                                   failingAccounts: [passwordAccount])
            defer { UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite) }
            model.draft.polestarEmail = "driver@example.com"
            model.draft.polestarPassword = "s3cret"
            model.draft.polestarVIN = "YSMTESTVNN0000005"
            model.draft.polestarDataPortalAccountID = "acct"
            model.draft.polestarDataPortalClientID = "client"
            model.draft.polestarDataPortalClientSecret = "portal-secret"

            let outcome = model.savePolestar(mode: .augmented)

            // The portal save landed, but a denied password must not be hidden by it.
            #expect(outcome?.saved == true)
            #expect(outcome?.effect == .credentialsChanged)
            #expect(outcome?.keychainError != nil)
            #expect(security.storedValue(for: portalBundleAccount)?.contains("portal-secret") == true)
            #expect(store.polestarDataPortalClientID == "client")
            // Identity stays unwritten; the portal secret does leave the draft.
            #expect(store.email.isEmpty)
            #expect(model.draft.polestarDataPortalClientSecret.isEmpty)
        }
    }

    @Test
    func dataPortalOnlySaveSkipsWhenClientIDEmpty() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-portal-empty")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            model.draft.polestarDataPortalClientSecret = "secret-only"

            #expect(model.savePolestar(mode: .dataPortal) == nil)
        }
    }

    @Test
    func invalidPolestarEmailShortCircuitsIDSave() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-invalid")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            model.draft.polestarEmail = "not-an-email"

            #expect(model.savePolestar(mode: .polestarID) == nil)
            #expect(scoped.store.email.isEmpty)
        }
    }

    // MARK: - Volvo handoff

    @Test
    func volvoSignInRecordsIdentityAndDropsSecrets() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-volvo")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            model.draft.volvoClientID = " client-id "
            model.draft.volvoClientSecret = "client-secret"
            model.draft.volvoApiKey = "api-key"
            model.draft.volvoVIN = " yv1testvnn0000001 "
            model.draft.volvoNickname = "Family car"

            guard let request = model.beginVolvoSignIn() else {
                Issue.record("expected a sign-in request")
                return
            }

            #expect(request.clientID == "client-id")
            #expect(request.clientSecret == "client-secret")
            #expect(request.vccApiKey == "api-key")
            #expect(request.nickname == "Family car")
            #expect(scoped.store.volvoClientID == "client-id")
            #expect(scoped.store.vin(for: .volvo) == "YV1TESTVNN0000001")
            #expect(scoped.store.vehicleNickname(for: "YV1TESTVNN0000001") == "Family car")
            // The secrets were handed to the sign-in flow; they must not outlive it.
            #expect(model.draft.volvoClientSecret.isEmpty)
            #expect(model.draft.volvoApiKey.isEmpty)
        }
    }

    @Test
    func volvoSignInWithInvalidVINWritesNothing() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-volvo-invalid")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            model.draft.volvoClientID = "client-id"
            model.draft.volvoVIN = "TOOSHORT"

            #expect(model.beginVolvoSignIn() == nil)
            #expect(model.draft.volvoClientSecret.isEmpty)
            #expect(scoped.store.vin(for: .volvo).isEmpty)
        }
    }

    // MARK: - Derived facts

    @Test
    func portalFactsFoldTheDraftAndStoredPresence() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-portal-facts")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)
            model.draft.polestarDataPortalClientID = "client"
            model.draft.polestarVIN = "BAD"

            #expect(model.canConnectDataPortal == false)
            model.draft.polestarVIN = "YSMTESTVNN0000006"
            #expect(model.canConnectDataPortal == true)
            // Portal presence comes from the test service's keychain, not the draft.
            if BuiltinPolestarSecrets.dataPortalClientSecret.isEmpty {
                #expect(model.isDataPortalConfigured == false)
            }

            try? scoped.keychain.savePolestarDataPortalCredentials(accountID: "acct", clientID: "client", clientSecret: "secret")
            #expect(model.isDataPortalConfigured == true)
        }
    }

    @Test
    func volvoResumeNeedsMatchingClientIDAndNoTypedSecrets() {
        withPresenceFlags {
            let scoped = ScopedPreferences(label: "acm-volvo-resume")
            scoped.store.volvoClientID = "stored-client"
            UserDefaults.standard.set(true, forKey: "has_volvo_session")
            let model = AccountConnectionModel(preferences: scoped.store, keychain: scoped.keychain)

            model.draft.volvoClientID = "other-client"
            #expect(model.hasResumableVolvoSession == false)

            model.draft.volvoClientID = "stored-client"
            #expect(model.hasResumableVolvoSession == true)

            model.draft.volvoClientSecret = "typed"
            #expect(model.hasResumableVolvoSession == false)
        }
    }
}
