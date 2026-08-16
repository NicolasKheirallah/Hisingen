

import Foundation
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
    static let shared = InMemorySecretCache()
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

private struct VolvoSecretBundle: Codable {
    var clientSecret: String?
    var apiKey: String?
    var sessionToken: String?
}

struct KeychainStore: Sendable {
    static let app = KeychainStore(service: "io.kheirallah.hisingen")

    let service: String

    private static let passwordAccount = "polestar-password"
    private static let sessionAccount = "polestar-refresh-token"
    private static let volvoBundleAccount = "volvo-credentials-bundle"
    private static let commandSessionAccount = "polestar-command-refresh-token"

    func savePassword(_ password: String) throws {
        UserDefaults.standard.set(!password.isEmpty, forKey: "has_polestar_password")
        try save(password, account: Self.passwordAccount)
    }
    func readPassword() throws -> String? { try read(account: Self.passwordAccount) }
    func deletePassword() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_password")
        try delete(account: Self.passwordAccount)
    }

    func saveSessionToken(_ token: String) throws {
        UserDefaults.standard.set(!token.isEmpty, forKey: "has_polestar_session")
        try save(token, account: Self.sessionAccount)
    }
    func readSessionToken() throws -> String? { try read(account: Self.sessionAccount) }
    func deleteSessionToken() throws {
        UserDefaults.standard.set(false, forKey: "has_polestar_session")
        try delete(account: Self.sessionAccount)
    }

    /// Refresh token for the Polestar command client, kept separate from the primary session
    /// because the two are issued to different OAuth clients and expire independently.
    func saveCommandSessionToken(_ token: String) throws {
        try save(token, account: Self.commandSessionAccount)
    }
    func readCommandSessionToken() throws -> String? { try read(account: Self.commandSessionAccount) }
    func deleteCommandSessionToken() throws { try delete(account: Self.commandSessionAccount) }

    func saveVolvoSessionToken(_ token: String) throws {
        var bundle = readVolvoBundle()
        bundle.sessionToken = token
        try saveVolvoBundle(bundle)
    }

    func readVolvoSessionToken() throws -> String? {
        readVolvoBundle().sessionToken
    }

    func deleteVolvoSessionToken() throws {
        var bundle = readVolvoBundle()
        bundle.sessionToken = nil
        try saveVolvoBundle(bundle)
    }

    func saveVolvoClientSecret(_ value: String) throws {
        var bundle = readVolvoBundle()
        bundle.clientSecret = value
        try saveVolvoBundle(bundle)
    }

    func readVolvoClientSecret() throws -> String? {
        readVolvoBundle().clientSecret
    }

    func deleteVolvoClientSecret() throws {
        var bundle = readVolvoBundle()
        bundle.clientSecret = nil
        try saveVolvoBundle(bundle)
    }

    func saveVolvoApiKey(_ value: String) throws {
        var bundle = readVolvoBundle()
        bundle.apiKey = value
        try saveVolvoBundle(bundle)
    }

    func readVolvoApiKey() throws -> String? {
        readVolvoBundle().apiKey
    }

    func deleteVolvoApiKey() throws {
        var bundle = readVolvoBundle()
        bundle.apiKey = nil
        try saveVolvoBundle(bundle)
    }

    private static let passwordDraftAccount = "polestar-password-draft"
    private static let volvoClientSecretDraftAccount = "volvo-client-secret-draft"
    private static let volvoApiKeyDraftAccount = "volvo-vcc-api-key-draft"

    func savePasswordDraft(_ value: String) throws {
        try save(value, account: Self.passwordDraftAccount)
    }

    func readPasswordDraft() throws -> String? {
        try read(account: Self.passwordDraftAccount)
    }

    func deletePasswordDraft() throws {
        try delete(account: Self.passwordDraftAccount)
    }

    func saveVolvoClientSecretDraft(_ value: String) throws {
        try save(value, account: Self.volvoClientSecretDraftAccount)
    }

    func readVolvoClientSecretDraft() throws -> String? {
        try read(account: Self.volvoClientSecretDraftAccount)
    }

    func deleteVolvoClientSecretDraft() throws {
        try delete(account: Self.volvoClientSecretDraftAccount)
    }

    func saveVolvoApiKeyDraft(_ value: String) throws {
        try save(value, account: Self.volvoApiKeyDraftAccount)
    }

    func readVolvoApiKeyDraft() throws -> String? {
        try read(account: Self.volvoApiKeyDraftAccount)
    }

    func deleteVolvoApiKeyDraft() throws {
        try delete(account: Self.volvoApiKeyDraftAccount)
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

    private func createTrustedAccess(label: String) -> SecAccess? {
        var trustedApp: SecTrustedApplication?
        let status = SecTrustedApplicationCreateFromPath(nil, &trustedApp)
        guard status == errSecSuccess, let trustedApp else { return nil }
        var access: SecAccess?
        let accessStatus = SecAccessCreate(label as CFString, [trustedApp] as CFArray, &access)
        guard accessStatus == errSecSuccess else { return nil }
        return access
    }

    private func save(_ value: String, account: String) throws {
        InMemorySecretCache.shared.set(cacheKey(account: account), value: value)
        var attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        if let access = createTrustedAccess(label: "Hisingen (\(account))") {
            attributes[kSecAttrAccess as String] = access
        }

        // Try standard query with trusted access
        let query = baseQuery(account: account, useDataProtection: false)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.status(updateStatus)
        }

        var add = query
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }

    private func read(account: String) throws -> String? {
        if let cached = InMemorySecretCache.shared.get(cacheKey(account: account)) {
            return cached
        }
        var query = baseQuery(account: account, useDataProtection: false)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        let result = String(data: data, encoding: .utf8)
        InMemorySecretCache.shared.set(cacheKey(account: account), value: result)
        return result
    }

    private func delete(account: String) throws {
        InMemorySecretCache.shared.set(cacheKey(account: account), value: nil)
        let status = SecItemDelete(baseQuery(account: account, useDataProtection: false) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }
}

enum Keychain {
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


