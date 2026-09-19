import Foundation

/// Credential precedence and provider configuration for every session restoration path.
/// Which stored credential resumes which adapter, and whether a stored password is a valid
/// fallback, are answered by the adapter through `VehicleProviding`; this module owns the
/// password-replay decision and the ordering of the two fallbacks.
@MainActor
final class SessionManager {
    enum Intent { case resume, credentialsChanged }

    private let readPassword: () throws -> String?
    private let clearPassword: () -> Void
    private let configure: (any VehicleProviding, PreferencesStore) async throws -> Void

    init(readPassword: @escaping () throws -> String? = { try Keychain.readPassword() },
         clearPassword: @escaping () -> Void = { try? Keychain.deletePassword() },
         configure: @escaping (any VehicleProviding, PreferencesStore) async throws -> Void = { api, _ in
             try await api.prepareSession()
         }) {
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
        try await configure(api, preferences)
        try Task.checkCancellation()

        func passwordCredentials() async throws -> (email: String, password: String)? {
            guard brand == .polestar,
                  await api.acceptsStoredPasswordSignIn,
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

        if intent == .credentialsChanged, let credentials = try await passwordCredentials() {
            try await signInWithStoredPassword(credentials)
            try Task.checkCancellation()
        } else {
            do {
                try await api.restoreSession(preferredVIN: vin, features: features)
            } catch {
                try Task.checkCancellation()
                guard ServiceErrorPolicy.decision(error, provider: brand).error.requiresAuthentication,
                      let credentials = try await passwordCredentials() else { throw error }
                try await signInWithStoredPassword(credentials)
                try Task.checkCancellation()
            }
        }
        try Task.checkCancellation()
        return await api.cars
    }
}
