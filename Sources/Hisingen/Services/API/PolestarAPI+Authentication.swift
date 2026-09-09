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
        // user triggers from Settings — see `beginCommandAuthorization()`/
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
    /// for one — once the command client's refresh token itself is gone or rejected, remote
    /// commands stay unavailable until the user re-authorizes through a real browser window
    /// (`SignInCoordinator.beginPolestarCommandAuthorization()`, surfaced as "Authorize Remote
    /// Commands" in Settings).
    ///
    /// The result lets the caller tell the user the truth: `.notAuthorized` is a
    /// dead end that a Settings visit fixes, `.unavailable` is a transient failure (offline,
    /// IdP 5xx) that a later retry recovers from on its own. A dead refresh token is cleared
    /// here so it is not re-tried on every subsequent command.
    ///
    /// Refreshes are single-flight: parallel commands used to each fire a `refresh_token`
    /// grant with the *same* stored token, and under a rotate-on-use identity provider one
    /// replay fails while both paths then persist different rotated tokens (last writer
    /// wins, orphaning the other).
    func commandClientAuthorization() async -> CommandClientAuthorization {
        guard !commandAuthorization.isInProgress else { return .notAuthorized }
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
        let diagnosticLog = diagnosticLog
        let requestEpoch = sessionEpoch
        let commandEpoch = commandAuthorization.generation
        let taskID = UUID()
        let task = Task { [logger] () -> CommandClientAuthorization in
            do {
                let token = try await Self.requestToken(request: request, session: currentSession,
                                                        invalidReason: .expiredSession,
                                                        diagnosticLog: diagnosticLog)
                guard self.sessionEpoch == requestEpoch, self.commandAuthorization.isCurrent(commandEpoch) else { return .unavailable }
                // Rotation already happened at the server, even if userinfo is unavailable.
                self.commandRefreshToken = token.refreshToken ?? refresh
                try await self.verifyCommandAccount(accessToken: token.accessToken)
                guard self.sessionEpoch == requestEpoch, self.commandAuthorization.isCurrent(commandEpoch) else {
                    return .unavailable
                }
                try self.applyCommandToken(token, fallbackRefresh: refresh)
                return .authorized(token.accessToken)
            } catch let error as PolestarError where error.requiresAuthentication {
                guard self.sessionEpoch == requestEpoch, self.commandAuthorization.isCurrent(commandEpoch) else { return .unavailable }
                // The refresh token itself is dead (invalid_grant / 401). Retrying it every
                // command just re-fails; drop it so the UI flips to "not authorized" and the
                // user is pointed at "Authorize Remote Commands" once.
                logger.warning("Polestar command-token refresh rejected; clearing stored authorization")
                self.clearCommandAuthorization()
                return .notAuthorized
            } catch is KeychainError {
                logger.error("Polestar command authorization could not be saved to Keychain")
                return .storageFailure
            } catch {
                // Transient: offline, 5xx, rate limit, decode. The authorization is probably
                // still good — keep the stored refresh token and let a later command retry.
                logger.warning("Polestar command-token refresh failed transiently: \(String(describing: error), privacy: .public)")
                return .unavailable
            }
        }
        commandRefreshTask = task
        commandRefreshTaskID = taskID
        defer {
            if commandRefreshTaskID == taskID {
                commandRefreshTask = nil
                commandRefreshTaskID = nil
            }
        }
        return await task.value
    }

    private func applyCommandToken(_ token: TokenResponseDTO, fallbackRefresh: String) throws {
        commandRefreshToken = token.refreshToken ?? fallbackRefresh
        commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        // Keep a rotated token in memory even when durable storage is temporarily locked.
        // Do not advertise a usable command session until its persistence succeeds.
        commandAccessToken = nil
        try saveCommandToken(token.refreshToken ?? fallbackRefresh)
        commandAccessToken = token.accessToken
    }

    /// Invalidates in-flight grants and memory state; restoration may still use the Keychain.
    func invalidateCommandAuthorization() {
        commandAuthorization.invalidate()
        commandRefreshTask?.cancel()
        commandRefreshTask = nil
        commandRefreshTaskID = nil
        commandAccessToken = nil
        commandRefreshToken = nil
        commandTokenExpiry = nil
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
