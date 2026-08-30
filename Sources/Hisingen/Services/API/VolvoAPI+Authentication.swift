import Foundation

extension VolvoAPI {
    /// `forceReadOnlyScopes` never asks for the approval-gated `restrictedScopes` even when the
    /// preference wants them — used to retry after Volvo rejects the request with
    /// `invalid_scope` because the developer application is not approved for lock / unlock /
    /// engine / honk-flash / location.
    func beginSignIn(forceReadOnlyScopes: Bool = false) async throws -> URL {
        guard isConfigured, let clientID else { throw VolvoError.appNotConfigured }
        // A browser authorization begins a new token generation. Cancel an older refresh so
        // its rotated token cannot land after the authorization-code grant and overwrite it.
        sessionEpoch &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        pendingVerifier = verifier
        pendingState = state
        var components = URLComponents(url: identityURL(path: authorizationPath), resolvingAgainstBaseURL: false)!
        let restrictedScopesWanted = await MainActor.run { preferences.volvoRestrictedScopesEnabled }
        let includeRestrictedScopes = !forceReadOnlyScopes && restrictedScopesWanted
        let scopes = Self.readScopes + (includeRestrictedScopes ? Self.restrictedScopes : [])
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
        guard let url = components.url else { throw VolvoError.incompatibleAPI(operation: "authorization request") }
        return url
    }

    func completeSignIn(callbackURL: URL, preferredVIN: String?, features: FeatureSelection) async throws {
        guard let verifier = pendingVerifier, let expectedState = pendingState else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        pendingVerifier = nil
        pendingState = nil
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let desc = components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? error
            // Keep the raw OAuth code recoverable so the caller can retry `invalid_scope`
            // read-only, while still carrying the human description for anything else.
            throw VolvoError.permissionDenied(operation: error == "invalid_scope" ? "invalid_scope" : desc)
        }
        guard components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        try await exchangeCodeForToken(code, verifier: verifier)
        try await discoverVehicles(preferredVIN: preferredVIN)
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        throw VolvoError.authenticationRequired(.callbackRejected)
    }

    /// See `VehicleProviding.hasWarmSession`. Client credentials, a stored refresh token, and
    /// known vehicles are enough for `fetchVehicleState`; `refreshTokenIfNeeded` inside that
    /// path renews an expired access token without a full re-restore.
    var hasWarmSession: Bool {
        isConfigured && refreshToken != nil && !cars.isEmpty
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else { throw VolvoError.authenticationRequired(.noStoredSession) }
        guard isConfigured else { throw VolvoError.appNotConfigured }
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as VolvoError where error.requiresAuthentication {
            refreshToken = nil
            throw error
        }
        try await discoverVehicles(preferredVIN: preferredVIN)
        logger.info("Stored Volvo session restored")
    }

    func resetSession() async {
        sessionEpoch &+= 1
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        lastTokenGrantAt = nil
        tokenLifetime = 0
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        pendingVerifier = nil
        pendingState = nil
        cars = []
        selectedVIN = nil
        vehicleDetailsCache = [:]
        capabilityCache = [:]
        optionalTelemetryCache = [:]
        // Preserve persisted permission/market back-offs across a session reset. Re-signing
        // does not make an unapproved provider scope available and must not trigger a probe storm.
        remoteCommandsInFlight = []
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    func signOut() async throws {
        await resetSession()
        do {
            try keychain.deleteVolvoSessionToken()
        } catch {
            try? keychain.deleteVolvoClientSecret()
            try? keychain.deleteVolvoApiKey()
            throw error
        }
        try keychain.deleteVolvoClientSecret()
        try keychain.deleteVolvoApiKey()
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, !preferred.isEmpty { return preferred }
        if let selectedVIN, !selectedVIN.isEmpty { return selectedVIN }
        return cars.first?.vin
    }

    func selectCar(vin: String, features: FeatureSelection) async throws {
        selectedVIN = vin
    }
}
