import Foundation

extension VolvoAPI {
    /// `tier` selects how wide a scope set to request. The caller cascades `.full` →
    /// `.full` without `location:read` → `.standard` → `.core` when Volvo answers
    /// `invalid_scope` ("exceeds that which the client is permitted to request"), which it
    /// does for the whole authorization if any single requested scope is not approved for
    /// the application. `dropsLocation` is that middle step: the one scope accounts most
    /// often lack, retried once before the coarser tiers give up all remote controls.
    func beginSignIn(tier: ScopeTier = .full, dropsLocation: Bool = false) async throws -> URL {
        guard isConfigured, let clientID else { throw VolvoError.appNotConfigured }
        // A browser authorization begins a new token generation. Cancel an older refresh so
        // its rotated token cannot land after the authorization-code grant and overwrite it.
        sessionEpoch &+= 1
        cancelInFlightTokenGrant()
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        authorizationFlow.begin(verifier: verifier, state: state)
        let provider = identityProvider
        guard var components = URLComponents(url: provider.authorizeURL,
                                             resolvingAgainstBaseURL: false) else {
            throw VolvoError.incompatibleAPI(operation: "authorization request")
        }
        let restrictedScopesWanted = await MainActor.run { preferences.volvoRestrictedScopesEnabled }
        let scopes: [String]
        switch tier {
        case .full:
            scopes = Self.readScopes + provider.additionalReadScopes
                + Self.restrictedScopeList(wanted: restrictedScopesWanted,
                                           dropsLocation: dropsLocation)
        case .standard:
            scopes = Self.readScopes + provider.additionalReadScopes
        case .core:
            scopes = Self.coreReadScopes
        }
        // The inspector compares this request with the token response's grant, so the ask is
        // recorded before the browser round trip. A cancelled sign-in leaves it in place: it
        // still describes what Hisingen asked Volvo for.
        await MainActor.run {
            preferences.recordVolvoScopeRequest(scopes, tier: tier.rawValue)
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
        let appCallbackURI = URL(string: "hisingen://oauth/volvo/callback")!
        let callbackRedirectURI = callbackURL.scheme == appCallbackURI.scheme ? appCallbackURI : redirectURI
        let completion = try authorizationFlow.consume(callbackURL: callbackURL, redirectURL: callbackRedirectURI)
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

    /// Resolves the stored credential that resumes this adapter. Token-free for callers:
    /// which keychain item means "session" is this adapter's knowledge, not the security
    /// module's.
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        guard let token = try keychain.readVolvoSessionToken(), !token.isEmpty else {
            throw VolvoError.authenticationRequired(.noStoredSession)
        }
        try await restoreSession(token: token, preferredVIN: preferredVIN, features: features)
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else { throw VolvoError.authenticationRequired(.noStoredSession) }
        guard isConfigured else { throw VolvoError.appNotConfigured }
        // A refresh token belongs to the sign-in system and client that issued it. One from the
        // original system is useless against the new one, and replaying it only adds failed
        // logins to Volvo's per-client lockout, so drop it and ask for a fresh sign-in. A session
        // saved before this was recorded came from the original system.
        let issuer = await MainActor.run { preferences.volvoSessionIdentity }
        if issuer != identityProvider {
            await discardDeadRefreshToken()
            throw VolvoError.authenticationRequired(.signInSystemChanged)
        }
        // Live-grant shortcut (mirrors Polestar): re-restoring the active session
        // must not rotate the refresh token on every retry. Only a cold restore
        // or a session whose access token is gone pays for a grant.
        let isLiveGrant = accessToken != nil && refreshToken == token
        refreshToken = token
        if !isLiveGrant {
            do {
                try await refreshAccessToken(force: true)
            } catch let error as VolvoError where error.requiresAuthentication {
                refreshToken = nil
                throw error
            }
        }
        try await discoverVehicles(preferredVIN: preferredVIN)
        logger.info("Stored Volvo session restored")
    }

    func resetSession() async {
        sessionEpoch &+= 1
        resetTokenLifecycle()
        authorizationFlow.invalidate()
        cars = []
        selectedVIN = nil
        vehicleDetailsCache = [:]
        capabilityCache = [:]
        optionalTelemetryCache = [:]
        carImageData = [:]
        interiorImageData = [:]
        // The recorded grant set belongs to the session that earned it; a reset without a
        // new grant must not leave per-scope answers describing a session that is gone.
        await MainActor.run { preferences.volvoGrantedScopes = [] }
        // Preserve persisted permission/market back-offs across a session reset. Re-signing
        // does not make an unapproved provider scope available and must not trigger a probe storm.
        remoteCommandsInFlight = []
        await MainActor.run { preferences.clearVolvoScopeGrant() }
        // Rebuilt from the old configuration rather than makeSession(), so a reset keeps the
        // transport the session was given. Sign-out's revocation runs on the replacement.
        let configuration = session.configuration
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }

    func signOut() async throws {
        // Read before resetSession clears the token. The local deletes run first, so the session
        // is off disk whatever the revocation does.
        let revocation = revocationRequest()
        await resetSession()
        // Best-effort atomic deletes: attempt all three, report the first failure
        // without cascading destruction. Previously a session-token delete failure
        // still deleted secrets + API key, permanently discarding developer secrets
        // on a transient ACL denial.
        var firstError: Error?
        do { try keychain.deleteVolvoSessionToken() } catch { firstError = firstError ?? error }
        do { try keychain.deleteVolvoClientSecret() } catch { firstError = firstError ?? error }
        do { try keychain.deleteVolvoApiKey() } catch { firstError = firstError ?? error }
        if let revocation { scheduleRevocation(revocation) }
        if let firstError { throw firstError }
    }

    /// The revocation POST for the live refresh token. Nil when there is nothing to revoke: no
    /// token in memory, or a sign-in system with no documented revocation endpoint. The keychain
    /// is not read here, because a read can prompt for Keychain access during sign-out.
    private func revocationRequest() -> URLRequest? {
        guard let url = identityProvider.revocationURL,
              let clientID, let clientSecret,
              let token = refreshToken, !token.isEmpty else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        Self.applyBasicAuth(&request, clientID: clientID, clientSecret: clientSecret)
        request.httpBody = Self.formBody(["token": token, "token_type_hint": "refresh_token"])
        return request
    }

    /// Sends the revocation without waiting for it, so sign-out never waits on the network. The
    /// outcome only reaches the debug log: the local state is already gone either way.
    private func scheduleRevocation(_ request: URLRequest) {
        Task {
            do {
                let (_, response) = try await perform(request, operation: "Volvo token revocation",
                                                      scope: .account)
                if !(200..<300).contains(response.statusCode) {
                    logger.debug("Volvo token revocation returned HTTP \(response.statusCode, privacy: .public)")
                }
            } catch {
                logger.debug("Volvo token revocation failed: \(String(describing: error), privacy: .private)")
            }
        }
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
