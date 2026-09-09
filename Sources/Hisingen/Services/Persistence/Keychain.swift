

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
    enum Entry { case value(String?) }
    private var cache: [String: Entry] = [:]

    func get(_ key: String) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        return cache[key]
    }

    func set(_ key: String, value: String?) {
        lock.lock()
        defer { lock.unlock() }
        cache[key] = .value(value)
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

    let service: String
    private let memoryCache: InMemorySecretCache
    private let volvoBundleLock = NSLock()
    private let operationLock = NSRecursiveLock()
    private let security: any KeychainSecurity

    init(service: String, security: any KeychainSecurity = SystemKeychainSecurity()) {
        self.service = service
        self.security = security
        self.memoryCache = InMemorySecretCache()
    }

    private static let passwordAccount = "polestar-password"
    private static let emailAccount = "polestar-email"
    private static let sessionAccount = "polestar-refresh-token"
    private static let volvoBundleAccount = "volvo-credentials-bundle"
    private static let commandSessionAccount = "polestar-command-refresh-token"

    /// Non-secret mirrors used only to decide whether an explicit restore attempt is useful.
    /// Authentication still reads and validates the real Keychain values.
    var hasStoredPolestarSession: Bool {
        UserDefaults.standard.bool(forKey: "has_polestar_session")
    }
    var hasStoredPolestarPassword: Bool {
        UserDefaults.standard.bool(forKey: "has_polestar_password")
    }
    var hasStoredPolestarEmail: Bool {
        UserDefaults.standard.bool(forKey: "has_polestar_email")
    }
    var hasStoredCommandSession: Bool {
        UserDefaults.standard.bool(forKey: "has_polestar_cmd_session")
    }
    var hasStoredVolvoSession: Bool {
        UserDefaults.standard.bool(forKey: "has_volvo_session")
    }
    var hasStoredVolvoAppCredentials: Bool {
        UserDefaults.standard.bool(forKey: "has_volvo_client_secret")
            && UserDefaults.standard.bool(forKey: "has_volvo_api_key")
    }

    func saveEmail(_ email: String) throws {
        try save(email, account: Self.emailAccount)
        UserDefaults.standard.set(!email.isEmpty, forKey: "has_polestar_email")
    }
    func readEmail() throws -> String? {
        let value = try read(account: Self.emailAccount)
        UserDefaults.standard.set(value?.isEmpty == false, forKey: "has_polestar_email")
        return value
    }
    func deleteEmail() throws {
        try delete(account: Self.emailAccount)
        UserDefaults.standard.set(false, forKey: "has_polestar_email")
    }

    func savePassword(_ password: String) throws {
        try save(password, account: Self.passwordAccount)
        UserDefaults.standard.set(!password.isEmpty, forKey: "has_polestar_password")
    }
    func readPassword() throws -> String? {
        let value = try read(account: Self.passwordAccount)
        UserDefaults.standard.set(value?.isEmpty == false, forKey: "has_polestar_password")
        return value
    }
    func deletePassword() throws {
        try delete(account: Self.passwordAccount)
        UserDefaults.standard.set(false, forKey: "has_polestar_password")
    }

    func saveSessionToken(_ token: String) throws {
        try save(token, account: Self.sessionAccount)
        UserDefaults.standard.set(!token.isEmpty, forKey: "has_polestar_session")
    }
    func readSessionToken() throws -> String? {
        let value = try read(account: Self.sessionAccount)
        UserDefaults.standard.set(value?.isEmpty == false, forKey: "has_polestar_session")
        return value
    }
    func deleteSessionToken() throws {
        try delete(account: Self.sessionAccount)
        UserDefaults.standard.set(false, forKey: "has_polestar_session")
    }

    /// Refresh token for the Polestar command client, kept separate from the primary session
    /// because the two are issued to different OAuth clients and expire independently.
    func saveCommandSessionToken(_ token: String) throws {
        try save(token, account: Self.commandSessionAccount)
        UserDefaults.standard.set(!token.isEmpty, forKey: "has_polestar_cmd_session")
    }
    func readCommandSessionToken() throws -> String? {
        let value = try read(account: Self.commandSessionAccount)
        UserDefaults.standard.set(value?.isEmpty == false, forKey: "has_polestar_cmd_session")
        return value
    }
    func deleteCommandSessionToken() throws {
        try delete(account: Self.commandSessionAccount)
        UserDefaults.standard.set(false, forKey: "has_polestar_cmd_session")
    }

    func saveVolvoSessionToken(_ token: String) throws {
        try mutateVolvoBundle { $0.sessionToken = token }
    }

    func readVolvoSessionToken() throws -> String? {
        try readVolvoBundle().sessionToken
    }

    func deleteVolvoSessionToken() throws {
        try mutateVolvoBundle { $0.sessionToken = nil }
    }

    func saveVolvoClientSecret(_ value: String) throws {
        try mutateVolvoBundle { $0.clientSecret = value }
    }

    func readVolvoClientSecret() throws -> String? {
        try readVolvoBundle().clientSecret
    }

    func deleteVolvoClientSecret() throws {
        try mutateVolvoBundle { $0.clientSecret = nil }
    }

    func saveVolvoApiKey(_ value: String) throws {
        try mutateVolvoBundle { $0.apiKey = value }
    }

    func readVolvoApiKey() throws -> String? {
        try readVolvoBundle().apiKey
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

    /// Read-modify-write of the Volvo credential bundle. The bundle is one Keychain item
    /// holding three secrets, so concurrent single-field writes (e.g. a sign-in flow saving
    /// the client secret while a token refresh persists the session token) would otherwise
    /// drop one of the fields — last writer wins with its stale copy of the other two.
    private func mutateVolvoBundle(_ mutate: (inout VolvoSecretBundle) -> Void) throws {
        volvoBundleLock.lock()
        defer { volvoBundleLock.unlock() }
        var bundle = try readVolvoBundle()
        mutate(&bundle)
        try saveVolvoBundle(bundle)
    }

    private func readVolvoBundle() throws -> VolvoSecretBundle {
        // Do not collapse a denied/corrupt bundle read into "no credentials": callers that
        // mutate this read-modify-write item must never overwrite an inaccessible bundle with
        // a partial value. Throwing also avoids three follow-on legacy queries/prompts.
        if let raw = try read(account: Self.volvoBundleAccount) {
            let bundle = try JSONDecoder().decode(VolvoSecretBundle.self, from: Data(raw.utf8))
            Self.updateVolvoPresenceFlags(bundle)
            return bundle
        }
        let legacySecret = try read(account: "volvo-client-secret")
        let legacyApiKey = try read(account: "volvo-vcc-api-key")
        let legacySession = try read(account: "volvo-refresh-token")
        let bundle = VolvoSecretBundle(clientSecret: legacySecret, apiKey: legacyApiKey,
                                       sessionToken: legacySession)
        if legacySecret != nil || legacyApiKey != nil || legacySession != nil {
            try? saveVolvoBundle(bundle)
        } else {
            Self.updateVolvoPresenceFlags(bundle)
        }
        return bundle
    }

    private func saveVolvoBundle(_ bundle: VolvoSecretBundle) throws {
        if bundle.clientSecret == nil && bundle.apiKey == nil && bundle.sessionToken == nil {
            try delete(account: Self.volvoBundleAccount)
            Self.updateVolvoPresenceFlags(bundle)
            return
        }
        let data = try JSONEncoder().encode(bundle)
        guard let str = String(data: data, encoding: .utf8) else { return }
        try save(str, account: Self.volvoBundleAccount)
        Self.updateVolvoPresenceFlags(bundle)
    }

    /// Non-secret presence bits let SwiftUI render account state without reading a protected
    /// Keychain item on every body evaluation. The actual values remain Keychain-only and are
    /// still read by the explicit sign-in/session paths that need them.
    private static func updateVolvoPresenceFlags(_ bundle: VolvoSecretBundle) {
        let defaults = UserDefaults.standard
        let hasSecret = bundle.clientSecret?.isEmpty == false
        let hasAPIKey = bundle.apiKey?.isEmpty == false
        defaults.set(hasSecret, forKey: "has_volvo_client_secret")
        defaults.set(hasAPIKey, forKey: "has_volvo_api_key")
        defaults.set(hasSecret && hasAPIKey && bundle.sessionToken?.isEmpty == false,
                     forKey: "has_volvo_session")
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
        operationLock.lock()
        defer { operationLock.unlock() }
        if isTestService {
            Self.testStore.set(cacheKey(account: account), value: value)
        } else {
            let status = write(value, account: account, useDataProtection: true)
            if status != errSecSuccess {
                guard Self.dataProtectionUnavailable(status) else { throw KeychainError.status(status) }
                let legacyStatus = write(value, account: account, useDataProtection: false)
                guard legacyStatus == errSecSuccess else { throw KeychainError.status(legacyStatus) }
            }
        }
        memoryCache.set(cacheKey(account: account), value: value)
    }

    private static func dataProtectionUnavailable(_ status: OSStatus) -> Bool {
        status == errSecMissingEntitlement || status == errSecNotAvailable
    }

    private func write(_ value: String, account: String, useDataProtection: Bool) -> OSStatus {
        let query = baseQuery(account: account, useDataProtection: useDataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = security.update(query, attributes: attributes)
        guard status == errSecItemNotFound else { return status }
        let addStatus = security.add(query.merging(attributes) { _, new in new })
        // Another process may have created the item between update and add.
        if addStatus == errSecDuplicateItem {
            return security.update(query, attributes: attributes)
        }
        return addStatus
    }

    private func read(account: String) throws -> String? {
        operationLock.lock()
        defer { operationLock.unlock() }
        if case .value(let cached) = memoryCache.get(cacheKey(account: account)) {
            return cached
        }
        if isTestService {
            return Self.testStore.get(cacheKey(account: account))
        }

        func query(_ dataProtection: Bool) -> [String: Any] {
            var result = baseQuery(account: account, useDataProtection: dataProtection)
            result[kSecReturnData as String] = true
            result[kSecMatchLimit as String] = kSecMatchLimitOne
            return result
        }
        func decode(_ data: Data?) throws -> String {
            guard let data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.status(errSecDecode)
            }
            return value
        }

        let (dpStatus, dpData) = security.copy(query(true))
        if dpStatus == errSecSuccess {
            let value = try decode(dpData)
            memoryCache.set(cacheKey(account: account), value: value)
            return value
        }
        guard dpStatus == errSecItemNotFound || Self.dataProtectionUnavailable(dpStatus) else {
            throw KeychainError.status(dpStatus)
        }

        let (legacyStatus, legacyData) = security.copy(query(false))
        if legacyStatus == errSecItemNotFound {
            memoryCache.set(cacheKey(account: account), value: nil)
            return nil
        }
        guard legacyStatus == errSecSuccess else { throw KeychainError.status(legacyStatus) }
        let value = try decode(legacyData)
        // Never use the fallback writer for migration: its success might only mean
        // that the legacy item was updated, leaving it as the sole durable copy.
        if dpStatus == errSecItemNotFound,
           write(value, account: account, useDataProtection: true) == errSecSuccess {
            _ = security.delete(baseQuery(account: account, useDataProtection: false))
        }
        memoryCache.set(cacheKey(account: account), value: value)
        return value
    }

    private func delete(account: String) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        if isTestService {
            Self.testStore.set(cacheKey(account: account), value: nil)
        } else {
            for dataProtection in [true, false] {
                let status = security.delete(baseQuery(account: account, useDataProtection: dataProtection))
                guard status == errSecSuccess || status == errSecItemNotFound
                    || (dataProtection && Self.dataProtectionUnavailable(status)) else {
                    throw KeychainError.status(status)
                }
            }
        }
        memoryCache.set(cacheKey(account: account), value: nil)
    }
}

enum Keychain {
    /// Presence checks only. They intentionally never touch Security.framework, so views may
    /// evaluate them freely without triggering a Keychain authorization prompt.
    static var hasStoredPolestarEmail: Bool {
        KeychainStore.app.hasStoredPolestarEmail
    }
    static var hasStoredVolvoAppCredentials: Bool {
        KeychainStore.app.hasStoredVolvoAppCredentials
    }
    static func savePassword(_ password: String) throws { try KeychainStore.app.savePassword(password) }
    static func readPassword() throws -> String? { try KeychainStore.app.readPassword() }
    static func deletePassword() throws { try KeychainStore.app.deletePassword() }
    static func readSessionToken() throws -> String? { try KeychainStore.app.readSessionToken() }

    static func readVolvoSessionToken() throws -> String? { try KeychainStore.app.readVolvoSessionToken() }
    static func saveVolvoClientSecret(_ value: String) throws { try KeychainStore.app.saveVolvoClientSecret(value) }
    static func readVolvoClientSecret() throws -> String? { try KeychainStore.app.readVolvoClientSecret() }
    static func saveVolvoApiKey(_ value: String) throws { try KeychainStore.app.saveVolvoApiKey(value) }
    static func readVolvoApiKey() throws -> String? { try KeychainStore.app.readVolvoApiKey() }
}
