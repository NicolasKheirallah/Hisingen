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
    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try Task.checkCancellation()
        guard !webAuthorization.isInProgress else { throw CancellationError() }
        let candidateCommandToken = freshCommandAccessToken()
        sessionEpoch &+= 1
        let epoch = sessionEpoch
        webAuthorization.invalidate()
        let flowGeneration = webAuthorization.generation
        let commandRefresh = commandRefreshToken ?? (try? keychain.readCommandSessionToken())
        let command = candidateCommand(candidateCommandToken, epoch: epoch, flowGeneration: flowGeneration)
        _ = redirectDelegate.takeCallback()
        let candidate = await makeLoginCandidate()
        try requireWebAuthorization(epoch: epoch, generation: flowGeneration)
        let snapshot = try await candidate.password(email: email, password: password, preferredVIN: preferredVIN, command: command)
        try requireWebAuthorization(epoch: epoch, generation: flowGeneration)
        await grpc.invalidateDiscoveredHost()
        try requireWebAuthorization(epoch: epoch, generation: flowGeneration)
        try commitCandidate(snapshot, commandRefresh: commandRefresh)
        let committedEpoch = sessionEpoch
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        try requireSession(committedEpoch)
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        try requireSession(committedEpoch)
        // Remote-command authorization (the command client) is a separate, explicit step the
        // user triggers from Settings – see `beginCommandAuthorization()`/
        // `completeCommandAuthorization(callbackURL:)` and `SignInCoordinator.beginPolestarCommandAuthorization()`.
        // It opens a real browser instead of reusing this sign-in's password, so it can't be
        // completed silently here.
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
        // A grant is already in flight, so the authorization exists; only the answer is pending.
        guard !commandAuthorization.isInProgress else { return .unavailable }
        let requestEpoch = sessionEpoch
        let commandEpoch = commandAuthorization.generation
        let stored: String?
        do {
            stored = try commandRefreshToken ?? keychain.readCommandSessionToken()
        } catch {
            // A locked or unreadable Keychain does not mean "never authorized": the token may be
            // there, so report storage trouble instead of sending the user back to Settings.
            logger.error("Polestar command token could not be read from Keychain: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            return .storageFailure
        }
        guard let refresh = stored, !refresh.isEmpty else { return .notAuthorized }
        // Cold start: discovery hasn't run yet (e.g. augmented telemetry-only launch).
        // A missing endpoint means "try again after discovery", not "never authorized".
        if tokenEndpoint == nil {
            do {
                try await discoverOIDCConfiguration()
            } catch {
                return .unavailable
            }
            guard tokenEndpoint != nil else { return .unavailable }
        }
        // Do not overwrite an in-memory rotated token with a stale Keychain value:
        // a concurrent clearCommandAuthorization + in-flight refresh may have already
        // persisted a rotation. Prefer live memory when present.
        if commandTokens.refreshToken == nil {
            commandTokens.refreshToken = refresh
        }
        do {
            switch try await commandTokens.refresh(
                .renewalWindow, now: now(),
                epochIsCurrent: { [self] in
                    guard await isSessionCurrent(requestEpoch) else { return false }
                    return await commandAuthorization.isCurrent(commandEpoch)
                },
                grant: { [self] in try await refreshCommandGrant(requestEpoch: requestEpoch, commandEpoch: commandEpoch) }
            ) {
            case .notNeeded, .refreshed:
                guard let token = commandAccessToken else { return .unavailable }
                if verifiedCommandToken?.token != token || verifiedCommandToken?.epoch != requestEpoch {
                    let account = try await verifyCommandAccount(accessToken: token)
                    try requireSession(requestEpoch)
                    guard commandAuthorization.isCurrent(commandEpoch), commandAccessToken == token else {
                        throw CancellationError()
                    }
                    verifiedCommandToken = (token, requestEpoch, account.sub)
                }
                return .authorized(token)
            case .deadGrant:
                guard isSessionCurrent(requestEpoch), commandAuthorization.isCurrent(commandEpoch) else { return .unavailable }
                // The refresh token itself is dead (invalid_grant / 401). Retrying it every
                // command just re-fails; drop it so the UI flips to "not authorized" and the
                // user is pointed at "Authorize Remote Commands" once.
                logger.warning("Polestar command-token refresh rejected; clearing stored authorization")
                clearCommandAuthorization()
                return .notAuthorized
            }
        } catch let error as PolestarError where error.isCommandAccountMismatch {
            if isSessionCurrent(requestEpoch), commandAuthorization.isCurrent(commandEpoch) { clearCommandAuthorization() }
            return .notAuthorized
        } catch is CancellationError {
            return .unavailable
        } catch is KeychainError {
            logger.error("Polestar command authorization could not be saved to Keychain")
            return .storageFailure
        } catch {
            // Transient: offline, 5xx, rate limit, decode. The authorization is probably
            // still good – keep the stored refresh token and let a later command retry.
            logger.warning("Polestar command-token refresh failed transiently: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
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
                                                diagnosticLog: diagnosticLog,
                                                deadGrantReason: .callbackRejected,
                                                malformedRotation: { [self] rotated in
            try await preserveCommandRotation(rotated, replacing: refresh, epoch: requestEpoch,
                                              generation: commandEpoch)
        })
        guard isSessionCurrent(requestEpoch), commandAuthorization.isCurrent(commandEpoch) else {
            throw CancellationError()
        }
        // Rotation already happened at the server, so the presented token is dead whatever happens
        // next. Keep the rotated token in memory and in the Keychain before verification: a transient
        // verification failure must not leave the rotated-out token behind for a restart to replay.
        // Only a definitive account mismatch is a dead grant to `commandTokens`; a failure to verify
        // because the consumer session is missing or stale is transient and keeps the grant.
        let rotated = token.refreshToken ?? refresh
        commandTokens.refreshToken = rotated
        // A locked Keychain surfaces as a storage failure instead of a session a restart would lose.
        try saveCommandToken(rotated)
        let account = try await verifyCommandAccount(accessToken: token.accessToken)
        try requireSession(requestEpoch)
        guard commandAuthorization.isCurrent(commandEpoch) else { throw CancellationError() }
        verifiedCommandToken = (token.accessToken, requestEpoch, account.sub)
        return TokenLifecycle.Grant(accessToken: token.accessToken,
                                    refreshToken: token.refreshToken,
                                    expiresIn: TimeInterval(token.expiresIn))
    }

    func preserveCommandRotation(_ rotated: String, replacing previous: String,
                                 epoch: Int, generation: UInt) throws {
        try requireSession(epoch)
        guard commandAuthorization.isCurrent(generation), commandRefreshToken == previous else {
            throw CancellationError()
        }
        commandRefreshToken = rotated
        try saveCommandToken(rotated)
    }

    /// Invalidates in-flight grants and memory state; restoration may still use the Keychain.
    func invalidateCommandAuthorization() {
        commandAuthorization.invalidate()
        verifiedCommandToken = nil
        commandTokens.reset()
    }

    func clearCommandAuthorization() {
        invalidateCommandAuthorization()
        do { try keychain.deleteCommandSessionToken() } catch {
            logger.error("Polestar command token could not be deleted from Keychain: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
        }
    }

    /// See `VehicleProviding.hasWarmSession`. A stored refresh token plus known vehicles and a
    /// discovered token endpoint is enough for `fetchVehicleState` to run; the access token is
    /// refreshed lazily inside that path. Manual-VIN fallback does not count – it means
    /// discovery returned empty.
    var hasWarmSession: Bool {
        refreshToken != nil && tokenEndpoint != nil && !cars.isEmpty && discoverySucceeded
    }

    /// Resolves the stored credential that resumes the consumer API. Token-free for
    /// callers: which keychain item means "session" in which connection mode is this
    /// adapter's knowledge, not the security module's.
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        guard let token = try keychain.readSessionToken(), !token.isEmpty else {
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
        // A restore that finds the grant this process is already using is the refresh-retry path,
        // not a launch: the stored credential has not changed and the access token it produced is
        // still the right one. Proving the grant again would rotate the refresh credential on
        // every retry, so the token material survives the reset here and only a cold restore (or
        // a session whose access token is already gone) pays for a grant.
        let isLiveGrant = accessToken != nil && refreshToken == token
        clearAccountState(keepRefreshToken: true, keepAccessToken: isLiveGrant)
        let epoch = sessionEpoch
        await grpc.invalidateDiscoveredHost()
        try requireSession(epoch)
        do {
            if let commandRefresh = try keychain.readCommandSessionToken(), !commandRefresh.isEmpty {
                commandRefreshToken = commandRefresh
            }
        } catch {
            // Not fatal to the web session: `commandClientAuthorization` reads the Keychain again when a
            // remote command needs it, and reports the failure then.
            logger.error("Polestar command token could not be read during restore: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
        }
        try await discoverOIDCConfiguration()
        try requireSession(epoch)
        refreshToken = token
        do {
            if isLiveGrant {
                try await refreshTokenIfNeeded()
            } else {
                try await refreshAccessToken(force: true)
            }
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
        keychain.invalidateMemoryCache()
        // A new account must not inherit the old account's VDMS stand-down.
        backoffs.unblock(PolestarAPI.discoveryBackoff)
        var storageError: Error?
        for delete in [keychain.deleteCommandSessionToken, keychain.deleteSessionToken, keychain.deletePassword, keychain.deleteEmail] {
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

    func requireWebAuthorization(epoch: Int, generation: UInt) throws {
        try requireSession(epoch)
        guard webAuthorization.isCurrent(generation) else { throw CancellationError() }
    }

    func requireSession(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard epoch == sessionEpoch else { throw CancellationError() }
    }

    /// Whether `epoch` still names the live session. Consulted by the token lifecycle after every
    /// suspension so a grant that lands after a reset cannot be applied to the session that
    /// replaced it.
    func isSessionCurrent(_ epoch: Int) -> Bool { epoch == sessionEpoch }

    struct AccountIdentity: Decodable, Sendable {
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

    @discardableResult
    func verifyCommandAccount(accessToken commandToken: String) async throws -> AccountIdentity {
        let epoch = sessionEpoch
        // There is nothing to compare against without a consumer session, and asking for a token
        // would report a *stale* session (`expiredSession`) for what is really "no session at all".
        if accessToken == nil, refreshToken == nil {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        try await refreshTokenIfNeeded()
        try requireSession(epoch)
        var endpoint = userinfoEndpoint
        if endpoint == nil {
            // Discovery may not have run yet on a cold start; retry once before
            // reporting a missing session.
            try? await discoverOIDCConfiguration()
            endpoint = userinfoEndpoint
        }
        guard let baseToken = accessToken, let endpoint else {
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
            let identity = try PolestarDecoding.decode(AccountIdentity.self, from: data,
                operation: "account verification", logger: logger)
            guard !identity.sub.isEmpty else { throw PolestarError.authenticationRequired(.callbackRejected) }
            return identity
        }
        let base = try await identity(token: baseToken)
        let command = try await identity(token: commandToken)
        try requireSession(epoch)
        guard base.matches(command) else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        return base
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, cars.contains(where: { $0.vin == preferred }) { return preferred }
        return cars.first?.vin
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        imagePreparationAttempts[vin] = nil
        ownerInfoPrepared = false
        ownerInfoRetryAt = nil
        try await prepareVehicle(vin: vin, features: features)
    }
}

private extension PolestarError {
    var isCommandAccountMismatch: Bool {
        if case .authenticationRequired(.callbackRejected) = self { return true }
        return false
    }
}
