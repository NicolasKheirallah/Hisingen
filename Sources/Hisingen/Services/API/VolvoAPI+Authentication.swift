import Foundation

extension VolvoAPI {
    /// `tier` selects how wide a scope set to request. The caller cascades `.full` → `.standard`
    /// → `.core` when Volvo answers `invalid_scope` ("exceeds that which the client is permitted
    /// to request"), which it does for the whole authorization if any single requested scope is
    /// not approved for the application.
    func beginSignIn(tier: ScopeTier = .full) async throws -> URL {
        guard isConfigured, let clientID else { throw VolvoError.appNotConfigured }
        // A browser authorization begins a new token generation. Cancel an older refresh so
        // its rotated token cannot land after the authorization-code grant and overwrite it.
        sessionEpoch &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        refreshTaskID = nil
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        authorizationFlow.begin(verifier: verifier, state: state)
        guard var components = URLComponents(url: try identityURL(path: authorizationPath),
                                             resolvingAgainstBaseURL: false) else {
            throw VolvoError.incompatibleAPI(operation: "authorization request")
        }
        let restrictedScopesWanted = await MainActor.run { preferences.volvoRestrictedScopesEnabled }
        let scopes: [String]
        switch tier {
        case .full:
            scopes = Self.readScopes + (restrictedScopesWanted ? Self.restrictedScopes : [])
        case .standard:
            scopes = Self.readScopes
        case .core:
            scopes = Self.coreReadScopes
        }
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

    func completeSignIn(callbackURL: URL, preferredVIN: String?) async throws {
        // The flow validates scheme, host, path, and state against the pending values and only
        // then consumes them, so a stray or forged callback cannot break the genuine sign-in.
        let completion = try authorizationFlow.consume(callbackURL: callbackURL, redirectURL: redirectURI)
        try await exchangeCodeForToken(completion.code, verifier: completion.verifier)
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
        authorizationFlow.invalidate()
        cars = []
        selectedVIN = nil
        vehicleDetailsCache = [:]
        capabilityCache = [:]
        optionalTelemetryCache = [:]
        carImageData = [:]
        interiorImageData = [:]
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

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        try await refreshTokenIfNeeded()
        guard cars.contains(where: { $0.vin == vin }) else { throw VolvoError.notConfigured }
        // Fetch already loads details by VIN; dropping the entry makes this an explicit reload.
        vehicleDetailsCache[vin] = nil
    }
}
