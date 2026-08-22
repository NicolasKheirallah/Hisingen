import Foundation

/// Single home for per-brand credential resolution and provider session restore.
///
/// `AppDelegate` previously assembled the same Keychain reads + builtin-secret fallbacks in
/// four places (launch resume, connection test, garage scan, settings change), and the copies
/// had already diverged subtly. Every path that needs "restore this brand's session" goes
/// through here so the rules exist exactly once:
///
/// - Polestar prefers the stored refresh token; the password is only used when no token
///   exists (it is deleted after a successful session, by design).
/// - Volvo requires client ID + secret + VCC API key *and* a session token; user-entered
///   values take precedence over the built-in developer credentials.
@MainActor
final class SessionManager {
    struct VolvoCredentials {
        let clientID: String
        let clientSecret: String
        let apiKey: String
        let sessionToken: String
    }

    /// Polestar refresh token and/or password. `token` is nil when absent; `password` is only
    /// populated when there is no token to restore from.
    func polestarCredentials() -> (token: String?, password: String?) {
        let storedToken = ((try? Keychain.readSessionToken()) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
        let password = storedToken == nil ? (((try? Keychain.readPassword()) ?? nil).flatMap { $0.isEmpty ? nil : $0 }) : nil
        return (storedToken, password)
    }

    func volvoCredentials(preferences: PreferencesStore) -> VolvoCredentials? {
        let clientID = !preferences.volvoClientID.isEmpty ? preferences.volvoClientID : BuiltinVolvoSecrets.clientID
        let clientSecret = ((try? Keychain.readVolvoClientSecret()) ?? nil)
            ?? (BuiltinVolvoSecrets.clientSecret.isEmpty ? nil : BuiltinVolvoSecrets.clientSecret)
        let apiKey = ((try? Keychain.readVolvoApiKey()) ?? nil)
            ?? (BuiltinVolvoSecrets.vccApiKey.isEmpty ? nil : BuiltinVolvoSecrets.vccApiKey)
        guard let sessionToken = ((try? Keychain.readVolvoSessionToken()) ?? nil), !sessionToken.isEmpty,
              let clientSecret, !clientSecret.isEmpty,
              let apiKey, !apiKey.isEmpty, !clientID.isEmpty else { return nil }
        return VolvoCredentials(clientID: clientID, clientSecret: clientSecret, apiKey: apiKey, sessionToken: sessionToken)
    }

    @discardableResult
    func restorePolestarSession(api: PolestarAPI, preferences: PreferencesStore) async throws -> [CarSummary] {
        let preferredVIN = preferences.vin(for: .polestar)
        let vin = preferredVIN.isEmpty ? nil : preferredVIN
        let (token, password) = polestarCredentials()
        if let token {
            try await api.restoreSession(token: token, preferredVIN: vin, features: preferences.features)
        } else if let password, !preferences.email.isEmpty {
            try await api.authenticate(email: preferences.email, password: password,
                                       preferredVIN: vin, features: preferences.features)
        } else {
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .noStoredSession)
        }
        return await api.cars
    }

    @discardableResult
    func restoreVolvoSession(api: VolvoAPI, preferences: PreferencesStore) async throws -> [CarSummary] {
        guard let credentials = volvoCredentials(preferences: preferences) else {
            throw VehicleServiceError.authenticationRequired(provider: .volvo, reason: .noStoredSession)
        }
        await api.configure(clientID: credentials.clientID,
                            clientSecret: credentials.clientSecret,
                            vccApiKey: credentials.apiKey)
        let preferredVIN = preferences.vin(for: .volvo)
        try await api.restoreSession(
            token: credentials.sessionToken,
            preferredVIN: preferredVIN.isEmpty ? nil : preferredVIN,
            features: preferences.features
        )
        return await api.cars
    }
}
