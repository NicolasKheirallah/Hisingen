import Foundation

/// Outcome of resolving a Polestar command-client (`lp8dyrd_10`) access token for a remote
/// command. Distinguishes the two failure modes so callers can say the right thing:
/// `.notAuthorized` needs a Settings visit, `.unavailable` just needs another try later.
enum CommandClientAuthorization: Sendable, Equatable {
    /// A usable command-client access token.
    case authorized(String)
    /// No stored command-client session — the user has not run "Authorize Remote Commands",
    /// or the stored refresh token was rejected and cleared. Retrying will not help.
    case notAuthorized
    /// A command-client refresh token exists but could not be exchanged right now (offline,
    /// IdP 5xx, rate limit). The authorization is probably still valid.
    case unavailable
}

extension PolestarAPI {
    func validAccessToken() async throws -> String? {
        try await refreshTokenIfNeeded()
        return accessToken
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        clearAccountState()
        _ = redirectDelegate.takeCallback()
        try await discoverOIDCConfiguration()
        let authorization = try await obtainAuthorizationCode(email: email, password: password)
        try await exchangeCodeForToken(authorization.code, verifier: authorization.verifier)
        // Remote-command authorization (the command client) is a separate, explicit step the
        // user triggers from Settings — see `beginCommandAuthorization()`/
        // `completeCommandAuthorization(callbackURL:)` and `SignInCoordinator.beginPolestarCommandAuthorization()`.
        // It opens a real browser instead of reusing this sign-in's password, so it can't be
        // completed silently here.
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
    }

    /// Resolves the command-client access token, refreshing silently from the stored refresh
    /// token when needed. This **never** falls back to replaying a stored password or prompting
    /// for one — once the command client's refresh token itself is gone or rejected, remote
    /// commands stay unavailable until the user re-authorizes through a real browser window
    /// (`SignInCoordinator.beginPolestarCommandAuthorization()`, surfaced as "Authorize Remote
    /// Commands" in Settings).
    ///
    /// The three-way result lets the caller tell the user the truth: `.notAuthorized` is a
    /// dead end that a Settings visit fixes, `.unavailable` is a transient failure (offline,
    /// IdP 5xx) that a later retry recovers from on its own. A dead refresh token is cleared
    /// here so it is not re-tried on every subsequent command.
    ///
    /// Refreshes are single-flight: parallel commands used to each fire a `refresh_token`
    /// grant with the *same* stored token, and under a rotate-on-use identity provider one
    /// replay fails while both paths then persist different rotated tokens (last writer
    /// wins, orphaning the other).
    func commandClientAuthorization() async -> CommandClientAuthorization {
        if let expiry = commandTokenExpiry, expiry.timeIntervalSinceNow > 300,
           let token = commandAccessToken { return .authorized(token) }
        if let existing = commandRefreshTask {
            return await existing.value
        }
        let stored = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        guard let refresh = stored, !refresh.isEmpty, let tokenEndpoint else { return .notAuthorized }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token", "client_id": commandClientID, "refresh_token": refresh
        ])
        let currentSession = session
        let task = Task { [logger] () -> CommandClientAuthorization in
            do {
                let token = try await Self.requestToken(request: request, session: currentSession,
                                                        invalidReason: .expiredSession)
                self.applyCommandToken(token, fallbackRefresh: refresh)
                return .authorized(token.accessToken)
            } catch let error as PolestarError where error.requiresAuthentication {
                // The refresh token itself is dead (invalid_grant / 401). Retrying it every
                // command just re-fails; drop it so the UI flips to "not authorized" and the
                // user is pointed at "Authorize Remote Commands" once.
                logger.warning("Polestar command-token refresh rejected; clearing stored authorization")
                self.clearCommandAuthorization()
                return .notAuthorized
            } catch {
                // Transient: offline, 5xx, rate limit, decode. The authorization is probably
                // still good — keep the stored refresh token and let a later command retry.
                logger.warning("Polestar command-token refresh failed transiently: \(String(describing: error), privacy: .public)")
                return .unavailable
            }
        }
        commandRefreshTask = task
        defer { commandRefreshTask = nil }
        return await task.value
    }

    private func applyCommandToken(_ token: TokenResponseDTO, fallbackRefresh: String) {
        commandAccessToken = token.accessToken
        commandRefreshToken = token.refreshToken ?? fallbackRefresh
        commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        if let refreshed = token.refreshToken { try? keychain.saveCommandSessionToken(refreshed) }
    }

    /// Drops every trace of the command-client session — in memory and in the Keychain — so
    /// `PreferencesStore.hasPolestarCommandAuthorization` and the Settings card reflect that
    /// remote commands need re-authorizing. Used when the refresh token is rejected.
    func clearCommandAuthorization() {
        commandAccessToken = nil
        commandRefreshToken = nil
        commandTokenExpiry = nil
        try? keychain.deleteCommandSessionToken()
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else { throw PolestarError.authenticationRequired(.noStoredSession) }
        clearAccountState(keepRefreshToken: true)
        if let commandRefresh = (try? keychain.readCommandSessionToken()) ?? nil, !commandRefresh.isEmpty {
            commandRefreshToken = commandRefresh
        }
        try await discoverOIDCConfiguration()
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as PolestarError where error.requiresAuthentication {
            refreshToken = nil
            throw error
        }
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        logger.info("Stored Polestar session restored")
    }

    func resetSession() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        commandAccessToken = nil
        commandRefreshToken = nil
        commandTokenExpiry = nil
        // A stale pending PKCE pair surviving sign-out would let a later callback matching
        // the old state complete a flow the user never restarted.
        commandPendingVerifier = nil
        commandPendingState = nil
        commandPendingSince = nil
        refreshTask?.cancel()
        refreshTask = nil
        cancelImageDownloads()
        clearAccountState()
        session.invalidateAndCancel()
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
        await grpc.invalidateDiscoveredHost()
    }

    func signOut() async throws {
        let commandToRevoke = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        if let commandToRevoke, let endpoint = revocationEndpoint {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                "client_id": commandClientID, "token": commandToRevoke, "token_type_hint": "refresh_token"
            ])
            _ = try? await perform(request, limit: 64_000, operation: "command session revocation")
        }
        try? keychain.deleteCommandSessionToken()
        if let tokenToRevoke = refreshToken, let endpoint = revocationEndpoint {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody([
                    "client_id": oidcClientID, "token": tokenToRevoke, "token_type_hint": "refresh_token"
                ])
                let (_, response) = try await perform(request, limit: 64_000, operation: "session revocation")
                try validateHTTP(response, operation: "session revocation")
            } catch {
                logger.warning("Polestar session revocation failed; clearing local credentials")
            }
        }
        await resetSession()
        do {
            try keychain.deleteSessionToken()
        } catch {
            try? keychain.deletePassword()
            throw error
        }
        try keychain.deletePassword()
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, cars.contains(where: { $0.vin == preferred }) { return preferred }
        return cars.first?.vin
    }

    func selectCar(vin: String, features: FeatureSelection) async throws {
        guard cars.contains(where: { $0.vin == vin }) else { throw PolestarError.notConfigured }
        try await applyCarInfo(vin: vin)
        if features.contains(.vehicleImage) { await fetchCarImage(vin: vin) }
        if features.contains(.ownerGreeting), ownerFirstName == nil { await fetchOwnerInfo() }
    }
}
