import Foundation

/// Credential precedence and provider configuration for every session restoration path.
@MainActor
final class SessionManager {
    enum Intent { case resume, credentialsChanged }

    private let readToken: (VehicleBrand) -> String?
    private let readPassword: () -> String?
    private let clearPassword: () -> Void
    private let configure: (any VehicleProviding, PreferencesStore) async throws -> Void

    init(readToken: @escaping (VehicleBrand) -> String? = { brand in
        brand == .volvo ? try? Keychain.readVolvoSessionToken() : try? Keychain.readSessionToken()
    }, readPassword: @escaping () -> String? = { try? Keychain.readPassword() },
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
        let email = preferences.email
        let features = preferences.features
        let token = readToken(brand).flatMap { $0.isEmpty ? nil : $0 }
        let password = brand == .polestar ? readPassword().flatMap { $0.isEmpty ? nil : $0 } : nil
        let missingSession = VehicleServiceError.authenticationRequired(provider: brand, reason: .noStoredSession)
        guard token != nil || (password != nil && !email.isEmpty) else { throw missingSession }
        try await configure(api, preferences)
        try Task.checkCancellation()

        if intent == .credentialsChanged, let password, !email.isEmpty {
            try await api.authenticate(email: email, password: password, preferredVIN: vin, features: features)
            try Task.checkCancellation()
            clearPassword()
        } else {
            do {
                guard let token else { throw missingSession }
                try await api.restoreSession(token: token, preferredVIN: vin, features: features)
            } catch {
                try Task.checkCancellation()
                guard ServiceErrorPolicy.decision(error, provider: brand).error.requiresAuthentication,
                      let password, !email.isEmpty else { throw error }
                try await api.authenticate(email: email, password: password, preferredVIN: vin, features: features)
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
        let secret = (try? Keychain.readVolvoClientSecret()) ?? BuiltinVolvoSecrets.clientSecret
        let apiKey = (try? Keychain.readVolvoApiKey()) ?? BuiltinVolvoSecrets.vccApiKey
        guard !clientID.isEmpty, !secret.isEmpty, !apiKey.isEmpty else {
            throw VehicleServiceError.authenticationRequired(provider: .volvo, reason: .noStoredSession)
        }
        await volvo.configure(clientID: clientID, clientSecret: secret, vccApiKey: apiKey)
    }
}
