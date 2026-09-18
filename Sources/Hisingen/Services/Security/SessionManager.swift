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
        if brand == .volvo {
            return try Keychain.readVolvoSessionToken()
        }
        if PreferencesStore.shared.polestarConnectionMode == .dataPortal {
            if let secret = try Keychain.readPolestarDataPortalClientSecret() {
                return secret
            }
            return try Keychain.readPolestarDataPortalToken()
        }
        if PreferencesStore.shared.polestarConnectionMode == .augmented {
            if let token = try Keychain.readSessionToken(), !token.isEmpty {
                return token
            }
            if let secret = try Keychain.readPolestarDataPortalClientSecret() {
                return secret
            }
            return try Keychain.readPolestarDataPortalToken()
        }
        return try Keychain.readSessionToken()
    }, readPassword: @escaping () throws -> String? = { try Keychain.readPassword() },
         clearPassword: @escaping () -> Void = { try? Keychain.deletePassword() },
         configure: @escaping (any VehicleProviding, PreferencesStore) async throws -> Void = { api, _ in
             try await api.prepareSession()
         }) {
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
                  (preferences.polestarConnectionMode == .polestarID || preferences.polestarConnectionMode == .augmented),
                  let password = try readPassword(), !password.isEmpty else { return nil }
            let email = preferences.email
            return email.isEmpty ? nil : (email, password)
        }

        // Signing in with the stored password is the one path where a credential can be
        // permanently wrong. Clear it when the IdP says so, otherwise the presence bits keep
        // reporting the account as resumable and every launch replays a failed login against
        // PingFederate's per-client attempt budget.
        func signInWithStoredPassword(_ credentials: (email: String, password: String)) async throws {
            do {
                try await api.authenticate(email: credentials.email, password: credentials.password,
                                           preferredVIN: vin, features: features)
            } catch {
                if ServiceErrorPolicy.decision(error, provider: brand).error.isRejectedCredential {
                    clearPassword()
                }
                throw error
            }
            clearPassword()
        }

        if intent == .credentialsChanged, let credentials = try passwordCredentials() {
            try await signInWithStoredPassword(credentials)
            try Task.checkCancellation()
        } else {
            do {
                guard let token = try readToken(brand), !token.isEmpty else { throw missingSession }
                try await api.restoreSession(token: token, preferredVIN: vin, features: features)
            } catch {
                try Task.checkCancellation()
                guard ServiceErrorPolicy.decision(error, provider: brand).error.requiresAuthentication,
                      let credentials = try passwordCredentials() else { throw error }
                try await signInWithStoredPassword(credentials)
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return await api.cars
    }
}
