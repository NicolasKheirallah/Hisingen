

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

struct KeychainStore: Sendable {
    static let app = KeychainStore(service: "io.kheirallah.hisingen")

    let service: String


    private static let passwordAccount = "polestar-password"
    private static let sessionAccount = "polestar-refresh-token"

    private static let volvoSessionAccount = "volvo-refresh-token"
    private static let volvoClientSecretAccount = "volvo-client-secret"
    private static let volvoApiKeyAccount = "volvo-vcc-api-key"


    private static let passwordDraftAccount = "polestar-password-draft"
    private static let volvoClientSecretDraftAccount = "volvo-client-secret-draft"
    private static let volvoApiKeyDraftAccount = "volvo-vcc-api-key-draft"


    func savePassword(_ password: String) throws { try save(password, account: Self.passwordAccount) }
    func readPassword() throws -> String? { try read(account: Self.passwordAccount) }
    func deletePassword() throws { try delete(account: Self.passwordAccount) }


    func saveSessionToken(_ token: String) throws { try save(token, account: Self.sessionAccount) }
    func readSessionToken() throws -> String? { try read(account: Self.sessionAccount) }
    func deleteSessionToken() throws { try delete(account: Self.sessionAccount) }


    func saveVolvoSessionToken(_ token: String) throws { try save(token, account: Self.volvoSessionAccount) }
    func readVolvoSessionToken() throws -> String? { try read(account: Self.volvoSessionAccount) }
    func deleteVolvoSessionToken() throws { try delete(account: Self.volvoSessionAccount) }

    func saveVolvoClientSecret(_ value: String) throws { try save(value, account: Self.volvoClientSecretAccount) }
    func readVolvoClientSecret() throws -> String? { try read(account: Self.volvoClientSecretAccount) }
    func deleteVolvoClientSecret() throws { try delete(account: Self.volvoClientSecretAccount) }

    func saveVolvoApiKey(_ value: String) throws { try save(value, account: Self.volvoApiKeyAccount) }
    func readVolvoApiKey() throws -> String? { try read(account: Self.volvoApiKeyAccount) }
    func deleteVolvoApiKey() throws { try delete(account: Self.volvoApiKeyAccount) }


    func savePasswordDraft(_ value: String) throws { try save(value, account: Self.passwordDraftAccount) }
    func readPasswordDraft() throws -> String? { try read(account: Self.passwordDraftAccount) }
    func deletePasswordDraft() throws { try delete(account: Self.passwordDraftAccount) }

    func saveVolvoClientSecretDraft(_ value: String) throws { try save(value, account: Self.volvoClientSecretDraftAccount) }
    func readVolvoClientSecretDraft() throws -> String? { try read(account: Self.volvoClientSecretDraftAccount) }
    func deleteVolvoClientSecretDraft() throws { try delete(account: Self.volvoClientSecretDraftAccount) }

    func saveVolvoApiKeyDraft(_ value: String) throws { try save(value, account: Self.volvoApiKeyDraftAccount) }
    func readVolvoApiKeyDraft() throws -> String? { try read(account: Self.volvoApiKeyDraftAccount) }
    func deleteVolvoApiKeyDraft() throws { try delete(account: Self.volvoApiKeyDraftAccount) }


    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    private func save(_ value: String, account: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            attributes as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {


            throw KeychainError.status(updateStatus)
        }

        var add = baseQuery(account: account)
        attributes.forEach { add[$0.key] = $0.value }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
    }


    private func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.status(status)
        }
        return String(data: data, encoding: .utf8)
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
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


