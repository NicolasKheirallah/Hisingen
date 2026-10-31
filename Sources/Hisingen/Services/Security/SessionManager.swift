import Foundation

private let sessionLogger = AppLog.logger("session")

/// Credential precedence and provider configuration for every session restoration path.
/// Which stored credential resumes which adapter, and whether a stored password is a valid
/// fallback, are answered by the adapter through `VehicleProviding`; this module owns the
/// password-replay decision and the ordering of the two fallbacks.
@MainActor
final class SessionManager {
    enum Intent { case resume, credentialsChanged }

    /// Sendable so the read can run detached from the main actor: a stored password lives
    /// behind the same Keychain ACL consent as every secret, and that read must not run on
    /// the main thread during launch (a pending prompt there cannot be answered).
    private let readPassword: @Sendable () throws -> String?
    /// Deletes the stored password. Throws when the Keychain refuses, so the caller can suppress
    /// auto-restore instead of replaying a password that could not be removed.
    private let clearPassword: () throws -> Void
    private let configure: (any VehicleProviding, PreferencesStore) async throws -> Void

    init(readPassword: @escaping @Sendable () throws -> String? = { try Keychain.readPassword() },
         clearPassword: @escaping () throws -> Void = {
             try Keychain.deletePassword()
             KeychainStore.app.invalidateMemoryCache()
         },
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
        // An explicit sign-out must survive relaunch: built-in developer credentials
        // plus a lingering server-side grant would otherwise re-discover the vehicle
        // and look like "auto login". Only an explicit save / sign-in clears it.
        if intent == .resume, preferences.hasExplicitSignOut(for: brand) {
            throw VehicleServiceError.authenticationRequired(provider: brand, reason: .noStoredSession)
        }
        let storedVIN = preferences.vin(for: brand)
        let vin = preferredVIN ?? (storedVIN.isEmpty ? nil : storedVIN)
        let features = preferences.features
        try await configure(api, preferences)
        try Task.checkCancellation()

        func passwordCredentials() async throws -> (email: String, password: String)? {
            guard brand == .polestar,
                  await api.acceptsStoredPasswordSignIn else { return nil }
            let readStoredPassword = readPassword
            let stored = try await Task.detached(priority: .userInitiated) {
                try readStoredPassword()
            }.value
            guard let password = stored, !password.isEmpty else { return nil }
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
                    do {
                        try clearPassword()
                    } catch {
                        // Deletion failed (e.g. interactionRequired): suppress auto-restore
                        // until the user explicitly reconnects, otherwise the rejected
                        // password replays every launch.
                        preferences.setExplicitSignOut(for: brand)
                        sessionLogger.error("Rejected password could not be deleted; suppressing auto-restore: \(String(describing: error), privacy: .public)")
                    }
                }
                throw error
            }
            do {
                try clearPassword()
            } catch {
                sessionLogger.error("Could not clear the stored Polestar password after success: \(String(describing: error), privacy: .public)")
            }
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
