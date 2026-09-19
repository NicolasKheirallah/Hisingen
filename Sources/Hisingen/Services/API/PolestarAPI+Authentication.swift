import Foundation

/// Outcome of resolving a Polestar command-client (`lp8dyrd_10`) access token for a remote
/// command. Distinguishes the two failure modes so callers can say the right thing:
/// `.notAuthorized` needs a Settings visit, `.unavailable` just needs another try later.
enum CommandClientAuthorization: Sendable, Equatable {
    /// A usable command-client access token.
    case authorized(String)
    /// No stored command-client session – the user has not run "Authorize Remote Commands",
    /// or the stored refresh token was rejected and cleared. Retrying will not help.
    case notAuthorized
    /// A command-client refresh token exists but could not be exchanged right now (offline,
    /// IdP 5xx, rate limit). The authorization is probably still valid.
    case unavailable
    case storageFailure
}

extension PolestarAPI {
    func validAccessToken() async throws -> String? {
        try await refreshTokenIfNeeded()
        return accessToken
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try Task.checkCancellation()
        guard !webAuthorization.isInProgress else { throw CancellationError() }
        clearAccountState()
        try keychain.deleteCommandSessionToken()
        let epoch = sessionEpoch
        _ = redirectDelegate.takeCallback()
        try await discoverOIDCConfiguration()
        try requireSession(epoch)
        let authorization = try await obtainAuthorizationCode(email: email, password: password)
        try requireSession(epoch)
        try await exchangeCodeForToken(authorization.code, verifier: authorization.verifier)
        // Remote-command authorization (the command client) is a separate, explicit step the
        // user triggers from Settings – see `beginCommandAuthorization()`/
        // `completeCommandAuthorization(callbackURL:)` and `SignInCoordinator.beginPolestarCommandAuthorization()`.
        // It opens a real browser instead of reusing this sign-in's password, so it can't be
        // completed silently here.
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        try requireSession(epoch)
    }

    /// Resolves the command-client access token, refreshing silently from the stored refresh
    /// token when needed. This **never** falls back to replaying a stored password or prompting
    /// for one – once the command client's refresh token itself is gone or rejected, remote
    /// commands stay unavailable until the user re-authorizes through a real browser window
    /// (`SignInCoordinator.beginPolestarCommandAuthorization()`, surfaced as "Authorize Remote
    /// Commands" in Settings).
    ///
    /// The result lets the caller tell the user the truth: `.notAuthorized` is a
    /// dead end that a Settings visit fixes, `.unavailable` is a transient failure (offline,
    /// IdP 5xx) that a later retry recovers from on its own. A dead refresh token is cleared
    /// here so it is not re-tried on every subsequent command.
    ///
    /// Single-flight, the renewal window, rotate-on-use persistence, and dead-grant
    /// classification live in `commandTokens` (a `TokenLifecycle`), the same invariants the
    /// session grant already owns; the wire part is `refreshCommandGrant`.
    func commandClientAuthorization() async -> CommandClientAuthorization {
        guard !commandAuthorization.isInProgress else { return .notAuthorized }
        let requestEpoch = sessionEpoch
        let commandEpoch = commandAuthorization.generation
        let stored = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        guard let refresh = stored, !refresh.isEmpty, tokenEndpoint != nil else { return .notAuthorized }
        commandTokens.refreshToken = refresh
        do {
            switch try await commandTokens.refresh(
                .renewalWindow,
                epochIsCurrent: { [self] in
                    guard await isSessionCurrent(requestEpoch) else { return false }
                    return await commandAuthorization.isCurrent(commandEpoch)
                },
                grant: { [self] in try await refreshCommandGrant(requestEpoch: requestEpoch, commandEpoch: commandEpoch) }
            ) {
            case .notNeeded:
                if let token = commandAccessToken { return .authorized(token) }
                return .notAuthorized
            case .refreshed:
                if let token = commandAccessToken { return .authorized(token) }
                return .unavailable
            case .deadGrant:
                // The refresh token itself is dead (invalid_grant / 401). Retrying it every
                // command just re-fails; drop it so the UI flips to "not authorized" and the
                // user is pointed at "Authorize Remote Commands" once.
                logger.warning("Polestar command-token refresh rejected; clearing stored authorization")
                clearCommandAuthorization()
                return .notAuthorized
            }
        } catch is CancellationError {
            return .unavailable
        } catch is KeychainError {
            logger.error("Polestar command authorization could not be saved to Keychain")
            return .storageFailure
        } catch {
            // Transient: offline, 5xx, rate limit, decode. The authorization is probably
            // still good – keep the stored refresh token and let a later command retry.
            logger.warning("Polestar command-token refresh failed transiently: \(String(describing: error), privacy: .public)")
            return .unavailable
        }
    }

    /// The wire half of the command-client grant: exchange the stored refresh token, then
    /// verify the returned token still names the same account as the web session. Lifecycle
    /// state (persistence, dead-grant classification) stays with `commandTokens`.
    private func refreshCommandGrant(requestEpoch: Int, commandEpoch: UInt) async throws -> TokenLifecycle.Grant {
        guard let endpoint = tokenEndpoint else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        guard let refresh = commandTokens.refreshToken, !refresh.isEmpty else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token", "client_id": commandClientID, "refresh_token": refresh
        ])
        let token = try await Self.requestToken(request: request, session: session,
                                                invalidReason: .expiredSession,
                                                diagnosticLog: diagnosticLog)
        guard isSessionCurrent(requestEpoch), commandAuthorization.isCurrent(commandEpoch) else {
            throw CancellationError()
        }
        // Rotation already happened at the server, even if account verification is unavailable:
        // keep the rotated token in memory now so a transient verification failure cannot make
        // the next retry present the token the server just invalidated. Persistence still waits
        // for adoption after verification.
        commandTokens.refreshToken = token.refreshToken ?? refresh
        try await verifyCommandAccount(accessToken: token.accessToken)
        // Persistence is the grant's own last step, not adoption's: a locked Keychain must
        // surface as a storage failure instead of a session a restart would lose, and the
        // lifecycle would otherwise skip persisting a token it already sees as current.
        try saveCommandToken(commandTokens.refreshToken ?? refresh)
        return TokenLifecycle.Grant(accessToken: token.accessToken,
                                    refreshToken: token.refreshToken,
                                    expiresIn: TimeInterval(token.expiresIn))
    }

    /// Invalidates in-flight grants and memory state; restoration may still use the Keychain.
    func invalidateCommandAuthorization() {
        commandAuthorization.invalidate()
        commandTokens.reset()
    }

    func clearCommandAuthorization() {
        invalidateCommandAuthorization()
        try? keychain.deleteCommandSessionToken()
    }

    /// See `VehicleProviding.hasWarmSession`. A stored refresh token plus known vehicles and a
    /// discovered token endpoint is enough for `fetchVehicleState` to run; the access token is
    /// refreshed lazily inside that path.
    var hasWarmSession: Bool {
        refreshToken != nil && tokenEndpoint != nil && !cars.isEmpty
    }

    /// Resolves the stored credential that resumes the consumer API. Token-free for
    /// callers: which keychain item means "session" in which connection mode is this
    /// adapter's knowledge, not the security module's.
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        guard let token = try Keychain.readSessionToken(), !token.isEmpty else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        try await restoreSession(token: token, preferredVIN: preferredVIN, features: features)
    }

    /// Stored email + password sign-in applies to the consumer-API modes; an M2M-only
    /// connection has no password to fall back to.
    var acceptsStoredPasswordSignIn: Bool {
        get async {
            let mode = await MainActor.run { preferences.polestarConnectionMode }
            return mode == .polestarID || mode == .augmented
        }
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try Task.checkCancellation()
        guard !webAuthorization.isInProgress else { throw CancellationError() }
        guard !token.isEmpty else { throw PolestarError.authenticationRequired(.noStoredSession) }
        clearAccountState(keepRefreshToken: true)
        let epoch = sessionEpoch
        if let commandRefresh = (try? keychain.readCommandSessionToken()) ?? nil, !commandRefresh.isEmpty {
            commandRefreshToken = commandRefresh
        }
        try await discoverOIDCConfiguration()
        try requireSession(epoch)
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as PolestarError where error.requiresAuthentication {
            try requireSession(epoch)
            refreshToken = nil
            throw error
        }
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        try requireSession(epoch)
        logger.info("Stored Polestar session restored")
    }

    private func resetLocalSession() {
        clearAccountState()
        session.invalidateAndCancel()
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
    }

    func resetSession() async {
        resetLocalSession()
        await grpc.invalidateDiscoveredHost()
    }

    func signOut() async throws {
        let tokens = [
            (commandClientID, commandRefreshToken ?? (try? keychain.readCommandSessionToken())),
            (oidcClientID, refreshToken ?? (try? keychain.readSessionToken()))
        ]
        let endpoint = revocationEndpoint
        let revocationConfiguration = session.configuration
        resetLocalSession()
        var storageError: Error?
        for delete in [keychain.deleteCommandSessionToken, keychain.deleteSessionToken, keychain.deletePassword] {
            do { try delete() } catch { storageError = storageError ?? error }
        }
        // Local state is gone before the first suspension. Revocation owns a separate
        // transport and never touches a session that starts while the server responds.
        await grpc.invalidateDiscoveredHost()
        if let endpoint {
            let revocationSession = URLSession(configuration: revocationConfiguration)
            defer { revocationSession.invalidateAndCancel() }
            for (clientID, token) in tokens {
                guard let token else { continue }
                var request = URLRequest(url: endpoint)
                request.timeoutInterval = 10
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody([
                    "client_id": clientID, "token": token, "token_type_hint": "refresh_token"
                ])
                _ = try? await HTTPExchange.data(
                    for: request, using: revocationSession, limit: 64_000,
                    operation: "session revocation", provider: .polestar,
                    diagnosticLog: diagnosticLog)
            }
        }
        if let storageError { throw storageError }
    }

    func cancelAuthorization(state: String?) {
        guard let state else { return }
        if webAuthorization.pendingState == state { clearAccountState() }
        if commandAuthorization.pendingState == state { invalidateCommandAuthorization() }
    }

    func requireSession(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == sessionEpoch else { throw CancellationError() }
    }

    /// Whether `epoch` still names the live session. Consulted by the token lifecycle after every
    /// suspension so a grant that lands after a reset cannot be applied to the session that
    /// replaced it.
    func isSessionCurrent(_ epoch: Int) -> Bool { epoch == sessionEpoch }

    struct AccountIdentity: Decodable {
        let sub: String
        let email: String?
        let emailVerified: Bool?

        enum CodingKeys: String, CodingKey {
            case sub, email
            case emailVerified = "email_verified"
        }

        func matches(_ other: Self) -> Bool {
            if !sub.isEmpty, sub == other.sub { return true }
            // Pairwise subjects may differ between the web and mobile clients.
            return emailVerified == true && other.emailVerified == true
                && email?.isEmpty == false && email == other.email
        }
    }

    func verifyCommandAccount(accessToken commandToken: String) async throws {
        let epoch = sessionEpoch
        try await refreshTokenIfNeeded()
        try requireSession(epoch)
        guard let baseToken = accessToken, let endpoint = userinfoEndpoint else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        func identity(token: String) async throws -> AccountIdentity {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await HTTPExchange.data(
                for: request, using: session, limit: 64_000,
                operation: "account verification", provider: .polestar,
                diagnosticLog: diagnosticLog)
            try validateHTTP(response, operation: "account verification")
            let identity = try JSONDecoder().decode(AccountIdentity.self, from: data)
            guard !identity.sub.isEmpty else { throw PolestarError.authenticationRequired(.callbackRejected) }
            return identity
        }
        let base = try await identity(token: baseToken)
        let command = try await identity(token: commandToken)
        try requireSession(epoch)
        guard base.matches(command) else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, cars.contains(where: { $0.vin == preferred }) { return preferred }
        return cars.first?.vin
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        imagePreparationAttempts[vin] = nil
        ownerInfoPrepared = false
        try await prepareVehicle(vin: vin, features: features)
    }
}
