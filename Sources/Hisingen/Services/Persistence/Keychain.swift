

import Foundation
import OSLog
import Security

enum KeychainError: Error, LocalizedError {
    case status(OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let code):
            let msg = SecCopyErrorMessageString(code, nil) as String? ?? "OSStatus \(code)"
            return L10n.format("Keychain error: %@", msg)
        }
    }
}

private final class InMemorySecretCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func set(_ key: String, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
    }
}

private final class TestSecretStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        if let value { values[key] = value } else { values.removeValue(forKey: key) }
    }
}

private struct VolvoSecretBundle: Codable {
    var clientSecret: String?
    var apiKey: String?
    var sessionToken: String?
}

struct KeychainStore: Sendable {
    static let app = KeychainStore(service: "io.kheirallah.hisingen")
    private static let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "keychain")

    let service: String
    private let memoryCache: InMemorySecretCache
    private let volvoBundleLock = NSLock()

    init(service: String) {
        self.service = service
        self.memoryCache = InMemorySecretCache()
    }

    private static let passwordAccount = "polestar-password"
    private static let emailAccount = "polestar-email"
    private static let sessionAccount = "polestar-refresh-token"
    private static let volvoBundleAccount = "volvo-credentials-bundle"
    private static let commandSessionAccount = "polestar-command-refresh-token"

    func saveEmail(_ email: String) throws {
        try save(email, account: Self.emailAccount)
    }
    func readEmail() throws -> String? {
        try read(account: Self.emailAccount)
    }
    func deleteEmail() throws {
        try delete(account: Self.emailAccount)
    }

    func savePassword(_ password: String) throws {
        UserDefaults.standard.set(!password.isEmpty, forKey: "has_polestar_password")
        try save(password, account: Self.passwordAccount)
    }
    func readPassword() throws -> String? {
        return try read(account: Self.passwordAccount)
    }
    func deletePassword() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_password")
        try delete(account: Self.passwordAccount)
    }

    func saveSessionToken(_ token: String) throws {
        UserDefaults.standard.set(!token.isEmpty, forKey: "has_polestar_session")
        try save(token, account: Self.sessionAccount)
    }
    func readSessionToken() throws -> String? {
        return try read(account: Self.sessionAccount)
    }
    func deleteSessionToken() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_session")
        try delete(account: Self.sessionAccount)
    }

    /// Refresh token for the Polestar command client, kept separate from the primary session
    /// because the two are issued to different OAuth clients and expire independently.
    func saveCommandSessionToken(_ token: String) throws {
        UserDefaults.standard.set(!token.isEmpty, forKey: "has_polestar_cmd_session")
        try save(token, account: Self.commandSessionAccount)
    }
    func readCommandSessionToken() throws -> String? {
        return try read(account: Self.commandSessionAccount)
    }
    func deleteCommandSessionToken() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_cmd_session")
        try delete(account: Self.commandSessionAccount)
    }

    func saveVolvoSessionToken(_ token: String) throws {
        try mutateVolvoBundle { $0.sessionToken = token }
    }

    func readVolvoSessionToken() throws -> String? {
        readVolvoBundle().sessionToken
    }

    func deleteVolvoSessionToken() throws {
        try mutateVolvoBundle { $0.sessionToken = nil }
    }

    func saveVolvoClientSecret(_ value: String) throws {
        try mutateVolvoBundle { $0.clientSecret = value }
    }

    func readVolvoClientSecret() throws -> String? {
        readVolvoBundle().clientSecret
    }

    func deleteVolvoClientSecret() throws {
        try mutateVolvoBundle { $0.clientSecret = nil }
    }

    func saveVolvoApiKey(_ value: String) throws {
        try mutateVolvoBundle { $0.apiKey = value }
    }

    func readVolvoApiKey() throws -> String? {
        readVolvoBundle().apiKey
    }

    func deleteVolvoApiKey() throws {
        try mutateVolvoBundle { $0.apiKey = nil }
    }

    private static let passwordDraftAccount = "polestar-password-draft"
    private static let volvoClientSecretDraftAccount = "volvo-client-secret-draft"
    private static let volvoApiKeyDraftAccount = "volvo-vcc-api-key-draft"

    func savePasswordDraft(_ value: String) throws {
        UserDefaults.standard.set(!value.isEmpty, forKey: "has_polestar_pw_draft")
        try save(value, account: Self.passwordDraftAccount)
    }

    func readPasswordDraft() throws -> String? {
        return try read(account: Self.passwordDraftAccount)
    }

    func deletePasswordDraft() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_pw_draft")
        try delete(account: Self.passwordDraftAccount)
    }

    func saveVolvoClientSecretDraft(_ value: String) throws {
        UserDefaults.standard.set(!value.isEmpty, forKey: "has_volvo_secret_draft")
        try save(value, account: Self.volvoClientSecretDraftAccount)
    }

    func readVolvoClientSecretDraft() throws -> String? {
        return try read(account: Self.volvoClientSecretDraftAccount)
    }

    func deleteVolvoClientSecretDraft() throws {
        UserDefaults.standard.set(false, forKey: "has_volvo_secret_draft")
        try delete(account: Self.volvoClientSecretDraftAccount)
    }

    func saveVolvoApiKeyDraft(_ value: String) throws {
        UserDefaults.standard.set(!value.isEmpty, forKey: "has_volvo_key_draft")
        try save(value, account: Self.volvoApiKeyDraftAccount)
    }

    func readVolvoApiKeyDraft() throws -> String? {
        return try read(account: Self.volvoApiKeyDraftAccount)
    }

    func deleteVolvoApiKeyDraft() throws {
        UserDefaults.standard.set(false, forKey: "has_volvo_key_draft")
        try delete(account: Self.volvoApiKeyDraftAccount)
    }

    /// Wipes all stored credentials, tokens, session state, and presence flags.
    func wipeAll() {
        attemptWipe("Polestar email") { try deleteEmail() }
        attemptWipe("Polestar password") { try deletePassword() }
        attemptWipe("Polestar session") { try deleteSessionToken() }
        attemptWipe("Polestar command session") { try deleteCommandSessionToken() }
        attemptWipe("Polestar password draft") { try deletePasswordDraft() }
        attemptWipe("Volvo session") { try deleteVolvoSessionToken() }
        attemptWipe("Volvo client secret") { try deleteVolvoClientSecret() }
        attemptWipe("Volvo API key") { try deleteVolvoApiKey() }
        attemptWipe("Volvo client secret draft") { try deleteVolvoClientSecretDraft() }
        attemptWipe("Volvo API key draft") { try deleteVolvoApiKeyDraft() }
        attemptWipe("Volvo credential bundle") { try delete(account: Self.volvoBundleAccount) }
        UserDefaults.standard.removeObject(forKey: "has_polestar_password")
        UserDefaults.standard.removeObject(forKey: "has_polestar_session")
        UserDefaults.standard.removeObject(forKey: "has_polestar_cmd_session")
        UserDefaults.standard.removeObject(forKey: "has_volvo_session")
        UserDefaults.standard.removeObject(forKey: "has_polestar_pw_draft")
        UserDefaults.standard.removeObject(forKey: "has_volvo_secret_draft")
        UserDefaults.standard.removeObject(forKey: "has_volvo_key_draft")
    }

    private func attemptWipe(_ item: String, _ action: () throws -> Void) {
        do {
            try action()
        } catch {
            Self.logger.error("Could not remove \(item, privacy: .public) from Keychain: \(error, privacy: .public)")
        }
    }

    /// Read-modify-write of the Volvo credential bundle. The bundle is one Keychain item
    /// holding three secrets, so concurrent single-field writes (e.g. a sign-in flow saving
    /// the client secret while a token refresh persists the session token) would otherwise
    /// drop one of the fields — last writer wins with its stale copy of the other two.
    private func mutateVolvoBundle(_ mutate: (inout VolvoSecretBundle) -> Void) throws {
        volvoBundleLock.lock()
        defer { volvoBundleLock.unlock() }
        var bundle = readVolvoBundle()
        mutate(&bundle)
        try saveVolvoBundle(bundle)
    }

    private func readVolvoBundle() -> VolvoSecretBundle {
        if let raw = try? read(account: Self.volvoBundleAccount),
           let data = raw.data(using: .utf8),
           let bundle = try? JSONDecoder().decode(VolvoSecretBundle.self, from: data) {
            return bundle
        }
        let legacySecret = try? read(account: "volvo-client-secret")
        let legacyApiKey = try? read(account: "volvo-vcc-api-key")
        let legacySession = try? read(account: "volvo-refresh-token")
        let bundle = VolvoSecretBundle(clientSecret: legacySecret ?? nil, apiKey: legacyApiKey ?? nil, sessionToken: legacySession ?? nil)
        if legacySecret != nil || legacyApiKey != nil || legacySession != nil {
            try? saveVolvoBundle(bundle)
        }
        return bundle
    }

    private func saveVolvoBundle(_ bundle: VolvoSecretBundle) throws {
        let hasValid = (bundle.clientSecret?.isEmpty == false) && (bundle.apiKey?.isEmpty == false) && (bundle.sessionToken?.isEmpty == false)
        UserDefaults.standard.set(hasValid, forKey: "has_volvo_session")
        if bundle.clientSecret == nil && bundle.apiKey == nil && bundle.sessionToken == nil {
            try delete(account: Self.volvoBundleAccount)
            return
        }
        let data = try JSONEncoder().encode(bundle)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try save(str, account: Self.volvoBundleAccount)
    }

    /// Only explicitly test-prefixed services bypass the real Keychain. The previous check
    /// treated *any* service name other than the production one as a test store, so renaming
    /// or adding a second production service would have silently persisted nothing.
    private var isTestService: Bool {
        service.hasPrefix("io.kheirallah.hisingen.tests.")
            || service.hasPrefix("io.kheirallah.hisingen.live-")
            || service.hasPrefix("io.kheirallah.hisingen.diagnostic-")
    }

    private static let testStore = TestSecretStore()

    private func cacheKey(account: String) -> String {
        "\(service)|\(account)"
    }

    private func baseQuery(account: String, useDataProtection: Bool = true) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if useDataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private func save(_ value: String, account: String) throws {
        memoryCache.set(cacheKey(account: account), value: value)
        if isTestService {
            Self.testStore.set(cacheKey(account: account), value: value)
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let dpQuery = baseQuery(account: account, useDataProtection: true)
        let dpUpdate = SecItemUpdate(dpQuery as CFDictionary, attributes as CFDictionary)
        if dpUpdate == errSecSuccess {
            _ = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
            return
        }
        if dpUpdate == errSecItemNotFound {
            var dpAdd = dpQuery
            attributes.forEach { dpAdd[$0.key] = $0.value }
            let dpAddStatus = SecItemAdd(dpAdd as CFDictionary, nil)
            if dpAddStatus == errSecSuccess {
                _ = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
                return
            }
        }

        let legacyQuery = baseQuery(account: account, useDataProtection: false)
        let legacyUpdate = SecItemUpdate(legacyQuery as CFDictionary, attributes as CFDictionary)
        if legacyUpdate == errSecSuccess { return }
        guard legacyUpdate == errSecItemNotFound else {
            throw KeychainError.status(legacyUpdate)
        }

        var legacyAdd = legacyQuery
        attributes.forEach { legacyAdd[$0.key] = $0.value }
        let legacyAddStatus = SecItemAdd(legacyAdd as CFDictionary, nil)
        guard legacyAddStatus == errSecSuccess else { throw KeychainError.status(legacyAddStatus) }
    }

    private func read(account: String) throws -> String? {
        if let cached = memoryCache.get(cacheKey(account: account)) {
            return cached
        }
        if isTestService {
            return Self.testStore.get(cacheKey(account: account))
        }

        var dpQuery = baseQuery(account: account, useDataProtection: true)
        dpQuery[kSecReturnData as String] = true
        dpQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let dpStatus = SecItemCopyMatching(dpQuery as CFDictionary, &item)
        if dpStatus == errSecSuccess, let data = item as? Data, let result = String(data: data, encoding: .utf8) {
            memoryCache.set(cacheKey(account: account), value: result)
            return result
        }

        var legacyQuery = baseQuery(account: account, useDataProtection: false)
        legacyQuery[kSecReturnData as String] = true
        legacyQuery[kSecMatchLimit as String] = kSecMatchLimitOne

        var legacyItem: CFTypeRef?
        let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
        if legacyStatus == errSecSuccess, let data = legacyItem as? Data, let result = String(data: data, encoding: .utf8) {
            memoryCache.set(cacheKey(account: account), value: result)
            // Migrate the legacy (file-based keychain) item into the data-protection
            // keychain. The legacy copy is deleted only once the new write has verifiably
            // succeeded — deleting first (or ignoring a failed save) permanently destroys
            // the credential when the DP keychain is unavailable, which is exactly what
            // happens when code-signing identities change between builds.
            do {
                try save(result, account: account)
                _ = SecItemDelete(legacyQuery as CFDictionary)
            } catch {
                Self.logger.error("Keychain migration for \(account, privacy: .public) deferred: DP save failed, legacy item kept")
            }
            return result
        }

        return nil
    }

    private func delete(account: String) throws {
        memoryCache.set(cacheKey(account: account), value: nil)
        if isTestService {
            Self.testStore.set(cacheKey(account: account), value: nil)
            return
        }
        _ = SecItemDelete(baseQuery(account: account, useDataProtection: true) as CFDictionary)
        _ = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
    }
}

enum Keychain {
    static func saveEmail(_ email: String) throws { try KeychainStore.app.saveEmail(email) }
    static func readEmail() throws -> String? { try KeychainStore.app.readEmail() }
    static func deleteEmail() throws { try KeychainStore.app.deleteEmail() }
    static func savePassword(_ password: String) throws { try KeychainStore.app.savePassword(password) }
    static func readPassword() throws -> String? { try KeychainStore.app.readPassword() }
    static func deletePassword() throws { try KeychainStore.app.deletePassword() }
    static func saveSessionToken(_ token: String) throws { try KeychainStore.app.saveSessionToken(token) }
    static func readSessionToken() throws -> String? { try KeychainStore.app.readSessionToken() }
    static func deleteSessionToken() throws { try KeychainStore.app.deleteSessionToken() }

    static func saveVolvoSessionToken(_ token: String) throws { try KeychainStore.app.saveVolvoSessionToken(token) }
    static func readVolvoSessionToken() throws -> String? { try KeychainStore.app.readVolvoSessionToken() }
    static func deleteVolvoSessionToken() throws { try KeychainStore.app.deleteVolvoSessionToken() }
    static func saveVolvoClientSecret(_ value: String) throws { try KeychainStore.app.saveVolvoClientSecret(value) }
    static func readVolvoClientSecret() throws -> String? { try KeychainStore.app.readVolvoClientSecret() }
    static func deleteVolvoClientSecret() throws { try KeychainStore.app.deleteVolvoClientSecret() }
    static func saveVolvoApiKey(_ value: String) throws { try KeychainStore.app.saveVolvoApiKey(value) }
    static func readVolvoApiKey() throws -> String? { try KeychainStore.app.readVolvoApiKey() }
    static func deleteVolvoApiKey() throws { try KeychainStore.app.deleteVolvoApiKey() }

    static func savePasswordDraft(_ value: String) throws { try KeychainStore.app.savePasswordDraft(value) }
    static func readPasswordDraft() throws -> String? { try KeychainStore.app.readPasswordDraft() }
    static func deletePasswordDraft() throws { try KeychainStore.app.deletePasswordDraft() }

    static func saveVolvoClientSecretDraft(_ value: String) throws { try KeychainStore.app.saveVolvoClientSecretDraft(value) }
    static func readVolvoClientSecretDraft() throws -> String? { try KeychainStore.app.readVolvoClientSecretDraft() }
    static func deleteVolvoClientSecretDraft() throws { try KeychainStore.app.deleteVolvoClientSecretDraft() }

    static func saveVolvoApiKeyDraft(_ value: String) throws { try KeychainStore.app.saveVolvoApiKeyDraft(value) }
    static func readVolvoApiKeyDraft() throws -> String? { try KeychainStore.app.readVolvoApiKeyDraft() }
    static func deleteVolvoApiKeyDraft() throws { try KeychainStore.app.deleteVolvoApiKeyDraft() }
}
