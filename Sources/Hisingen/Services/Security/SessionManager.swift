import Foundation

/// Credential precedence and provider configuration for every session restoration path.
@MainActor
final class SessionManager {
    enum Intent { case resume, credentialsChanged }

    private let readToken: (VehicleBrand) throws -> String?
    private let readPassword: () throws -> String?
    private let clearPassword: () -> Void
    private let configure: (any VehicleProviding, PreferencesStore) async throws -> Void

    init(readToken: @escaping (VehicleBrand) throws -> String? = { brand in
        brand == .volvo ? try Keychain.readVolvoSessionToken() : try Keychain.readSessionToken()
    }, readPassword: @escaping () throws -> String? = { try Keychain.readPassword() },
         clearPassword: @escaping () -> Void = { try? Keychain.deletePassword() },
         configure: @escaping (any VehicleProviding, PreferencesStore) async throws -> Void = SessionManager.configureProvider) {
        self.readToken = readToken
        self.readPassword = readPassword
        self.clearPassword = clearPassword
        self.configure = configure
    }

    @discardableResult
    func restore(api: any VehicleProviding, preferences: PreferencesStore,
                 preferredVIN: String? = nil, intent: Intent = .resume) async throws -> [CarSummary] {
        let brand = api.brand
        let storedVIN = preferences.vin(for: brand)
        let vin = preferredVIN ?? (storedVIN.isEmpty ? nil : storedVIN)
        let features = preferences.features
        let missingSession = VehicleServiceError.authenticationRequired(provider: brand, reason: .noStoredSession)
        try await configure(api, preferences)
        try Task.checkCancellation()

        func passwordCredentials() throws -> (email: String, password: String)? {
            guard brand == .polestar,
                  let password = try readPassword(), !password.isEmpty else { return nil }
            let email = preferences.email
            return email.isEmpty ? nil : (email, password)
        }

        if intent == .credentialsChanged, let credentials = try passwordCredentials() {
            try await api.authenticate(email: credentials.email, password: credentials.password, preferredVIN: vin, features: features)
            try Task.checkCancellation()
            clearPassword()
        } else {
            do {
                guard let token = try readToken(brand), !token.isEmpty else { throw missingSession }
                try await api.restoreSession(token: token, preferredVIN: vin, features: features)
            } catch {
                try Task.checkCancellation()
                guard ServiceErrorPolicy.decision(error, provider: brand).error.requiresAuthentication,
                      let credentials = try passwordCredentials() else { throw error }
                try await api.authenticate(email: credentials.email, password: credentials.password, preferredVIN: vin, features: features)
                try Task.checkCancellation()
                clearPassword()
            }
        }
        try Task.checkCancellation()
        return await api.cars
    }

    private static func configureProvider(_ api: any VehicleProviding, preferences: PreferencesStore) async throws {
        guard let volvo = api as? VolvoAPI else { return }
        let clientID = preferences.volvoClientID.isEmpty ? BuiltinVolvoSecrets.clientID : preferences.volvoClientID
        let secret = (try Keychain.readVolvoClientSecret()) ?? BuiltinVolvoSecrets.clientSecret
        let apiKey = (try Keychain.readVolvoApiKey()) ?? BuiltinVolvoSecrets.vccApiKey
        guard !clientID.isEmpty, !secret.isEmpty, !apiKey.isEmpty else {
            throw VehicleServiceError.authenticationRequired(provider: .volvo, reason: .noStoredSession)
        }
        await volvo.configure(clientID: clientID, clientSecret: secret, vccApiKey: apiKey)
    }
}
