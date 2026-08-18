import Foundation

enum BuiltinVolvoSecrets {
    static var isConfigured: Bool {
        GeneratedVolvoSecrets.isConfigured &&
        !clientID.isEmpty &&
        !clientSecret.isEmpty &&
        !vccApiKey.isEmpty
    }

    static var clientID: String {
        GeneratedVolvoSecrets.clientID
    }

    static var clientSecret: String {
        GeneratedVolvoSecrets.clientSecret
    }

    static var vccApiKey: String {
        GeneratedVolvoSecrets.vccApiKey
    }
}
