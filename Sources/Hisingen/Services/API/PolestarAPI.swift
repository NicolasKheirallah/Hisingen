import AppKit
import Foundation
import OSLog

struct VDMSDiscoveryDiagnostics: Equatable, Sendable {
    let blockedUntil: Date
    let reason: String
}

actor PolestarAPI {
    nonisolated let brand: VehicleBrand = .polestar
    let logger = AppLog.logger("polestar-api")

    private let apiBaseURL = PolestarConfig.apiBaseURL
    private let publicApiURL = PolestarConfig.publicApiURL
    private let appBackendURL = PolestarConfig.appBackendURL
    private var publicApiKey: String { BuiltinPolestarSecrets.imageApiKey }
    private let oidcProviderURL = PolestarConfig.oidcProviderURL

    // The OAuth clients, scope and their reasoning live in `PolestarConfig`.
    let oidcClientID = PolestarConfig.webClientID
    let oidcRedirectURL = PolestarConfig.webRedirectURL
    let oidcScope = PolestarConfig.webScope
    let commandClientID = PolestarConfig.commandClientID
    let commandRedirectURL = PolestarConfig.commandRedirectURL

    var commandAuthorization = PolestarAuthorizationFlow()
    var webAuthorization = PolestarAuthorizationFlow()
    var saveCommandToken: @Sendable (String) throws -> Void
    /// The command client's own token lifecycle: the same renewal-window, single-flight and
    /// dead-grant invariants as the session grant, configured for five-minute command tokens
    /// and a browser-granted refresh credential that rotates on use. The grant closure owns
    /// persistence directly, because a rotated token must be durable before the session is
    /// advertised, whether or not the lifecycle saw the rotation as a change.
    let commandTokens: TokenLifecycle
    let saveSessionToken: @Sendable (String) throws -> Void

    var commandAccessToken: String? {
        get { commandTokens.accessToken }
        set { commandTokens.accessToken = newValue }
    }
    var commandRefreshToken: String? {
        get { commandTokens.refreshToken }
        set { commandTokens.refreshToken = newValue }
    }
    var commandTokenExpiry: Date? {
        get { commandTokens.tokenExpiry }
        set { commandTokens.tokenExpiry = newValue }
    }

    var session: URLSession
    var redirectDelegate: OAuthRedirectDelegate
    let grpc: PolestarGRPC
    let diagnosticLog: APIDiagnosticLogStore
    let keychain: KeychainStore
    let imageCache: CarImageCache
    private var installedAlternateAccessTokenProvider = false

    /// Installs the app/command grant as discovery's retry audience. Idempotent, and the
    /// closure reads the command token lazily so it reflects whichever grant is current when
    /// discovery runs rather than the one that existed at construction.
    func installAlternateAccessTokenProviderIfNeeded() async {
        guard !installedAlternateAccessTokenProvider else { return }
        installedAlternateAccessTokenProvider = true
        await grpc.setAlternateAccessTokenProvider { [weak self] in
            await self?.freshCommandAccessToken()
        }
    }

    /// The command grant's access token, but only while it is still valid. Discovery falls back
    /// to this grant after the session grant is refused; presenting an expired one would replace
    /// an informative 406 with a 401 (which the ladder surfaces immediately rather than retries).
    func freshCommandAccessToken() -> String? {
        guard let expiry = commandTokenExpiry, expiry.timeIntervalSince(now()) > 0,
              let token = commandAccessToken, !token.isEmpty,
              verifiedCommandToken?.token == token, verifiedCommandToken?.epoch == sessionEpoch else { return nil }
        return token
    }

    /// The session token lifecycle: renewal margin, single-flight grant, rotate-on-use
    /// persistence, dead-grant classification. It stays private because it is confined to this
    /// actor – the passthroughs below are the only way in, and they exist because the telemetry
    /// and command extensions read the access token directly, and tests seed a near-expiry one.
    private let tokens: TokenLifecycle
    var accessToken: String? {
        get { tokens.accessToken }
        set { tokens.accessToken = newValue }
    }
    var refreshToken: String? {
        get { tokens.refreshToken }
        set { tokens.refreshToken = newValue }
    }
    var tokenExpiry: Date? {
        get { tokens.tokenExpiry }
        set { tokens.tokenExpiry = newValue }
    }
    var tokenLifetime: TimeInterval {
        get { tokens.tokenLifetime }
        set { tokens.tokenLifetime = newValue }
    }

    var tokenEndpoint: URL?
    var authorizationEndpoint: URL?
    var userinfoEndpoint: URL?
    var revocationEndpoint: URL?

    private(set) var cars: [CarSummary] = []
    var selectedVIN: String?
    /// True only after a real discovery response populated `cars`. A manual-VIN
    /// fallback (user-typed VIN when discovery returned empty) must not count as
    /// warm – otherwise the garage scanner treats a failed discovery as a live
    /// session and stops restoring.
    private(set) var discoverySucceeded = false
    var imagePreparationAttempts: [String: (angle: Int, retryAt: Date)] = [:]
    var ownerInfoPrepared = false
    var ownerInfoRetryAt: Date?

    /// Discovery metadata for one vehicle, keyed by VIN. Scoped per-VIN so concurrent
    /// selections cannot cross-contaminate telemetry fetches.
    struct CarIdentity: Sendable {
        var internalVehicleIdentifier: String?
        var modelName: String?
        var modelYear: String?
        var registrationNo: String?
        var pno34: String?
        var structureWeek: String?

        static let empty = CarIdentity()
    }
    private(set) var identities: [String: CarIdentity] = [:]
    func identity(for vin: String?) -> CarIdentity { vin.flatMap { identities[$0] } ?? .empty }
    /// Restores a previously saved discovery snapshot (sign-in rollback on failure/cancel
    /// must not destroy a working session). The only cross-file mutation of the
    /// `private(set)` discovery state; all other writes stay in this file.
    func restoreDiscovery(cars: [CarSummary], identities: [String: CarIdentity]) {
        self.cars = cars
        self.identities = identities
        discoverySucceeded = !cars.isEmpty
    }
    var ownerFirstName: String?
    var market: String?
    /// Durable provider stand-downs: Polestar's secondary discovery source and Volvo's optional
    /// endpoints share one owner, so an erase reaches them and a test can inject one. Internal so
    /// the preparation tests can seed a stand-down without a transport round trip.
    let backoffs: ProviderBackoffStore
    private var artwork = PolestarArtworkLoader()
    var carImages: [String: Data] { artwork.displayed }
    /// Probe-or-cache authority for backend capabilities: cache, TTLs, backoff, and
    /// command-time invalidation live in one module (see `PolestarCapabilityAuthority`).
    let capabilityAuthority: PolestarCapabilityAuthority
    var remoteCommandsInFlight = PolestarCommandOperations()
    var verifiedCommandToken: (token: String, epoch: Int, accountID: String)?
    private var candidateDiscoveryCommand: PolestarCandidateCommand?
    private var imageDownloadTasks: [String: Task<Void, Never>] = [:]
    private var imageDownloadTaskIDs: [String: UUID] = [:]
    /// Bumped whenever account state is cleared/reset. Multi-step operations capture it on
    /// entry and drop their results if a reset interleaved – the actor serializes individual
    /// writes but not whole logical transactions (e.g. a slow discovery from a superseded
    /// login could otherwise repopulate `cars` after sign-out cleared them).
    var sessionEpoch = 0
    let preferences: PreferencesStore
    let now: @Sendable () -> Date

    @MainActor
    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache(),
         diagnosticLog: APIDiagnosticLogStore = .shared, grpcSession: URLSession? = nil,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(keychain: keychain, imageCache: imageCache, preferences: .shared,
                  diagnosticLog: diagnosticLog, grpcSession: grpcSession, now: now)
    }

    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore, diagnosticLog: APIDiagnosticLogStore = .shared,
         backoffs: ProviderBackoffStore = ProviderBackoffStore(),
         grpcSession: URLSession? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         persistSessionToken: (@Sendable (String) throws -> Void)? = nil) {
        self.keychain = keychain
        self.now = now
        self.capabilityAuthority = PolestarCapabilityAuthority(now: now)
        self.backoffs = backoffs
        self.saveCommandToken = { try keychain.saveCommandSessionToken($0) }
        let sessionPersistence: @Sendable (String) throws -> Void = persistSessionToken ?? { try keychain.saveSessionToken($0) }
        self.saveSessionToken = sessionPersistence
        self.imageCache = imageCache
        self.preferences = preferences
        self.diagnosticLog = diagnosticLog
        self.grpc = PolestarGRPC(session: grpcSession, diagnosticLog: diagnosticLog)
        self.tokens = TokenLifecycle(
            policy: .init(renewalMargin: Self.tokenRenewalMargin(lifetime:)),
            providerName: "Polestar",
            logger: AppLog.logger("polestar-api"),
            persist: sessionPersistence,
            isDeadGrant: { error in
                if case PolestarError.authenticationRequired(.noStoredSession) = error { return true }
                return false
            }
        )
        // Polestar commonly issues five-minute command tokens, so the reuse margin must fit
        // inside a fresh 300 s grant; 30 s matches the web-client margin `tokenRenewalMargin`
        // computes for that lifetime.
        let persistCommandToken = saveCommandToken
        self.commandTokens = TokenLifecycle(
            policy: .init(renewalMargin: { _ in 30 }),
            providerName: "Polestar command client",
            logger: AppLog.logger("polestar-api"),
            persist: { try persistCommandToken($0) },
            // Only the command grant itself being refused may clear a command authorization:
            // `refreshCommandGrant` stamps that with `.callbackRejected` (the token endpoint
            // answering `invalid_grant`, or a verified account mismatch). Every other auth error
            // comes from verifying the *consumer* session, which is a transient problem for this
            // lifecycle – keeping the stored grant lets a fresh sign-in resume commands instead of
            // forcing the user through the browser again.
            isDeadGrant: { error in
                if case PolestarError.authenticationRequired(.callbackRejected) = error { return true }
                return false
            }
        )
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
    }

    /// Coalesces concurrent cold starts. The actor can re-enter while the network request is
    /// suspended, so the TTL check alone still allowed four identical well-known requests.
    private var oidcDiscoveryTask: Task<PolestarOIDCConfiguration, Error>?

    /// When the OIDC well-known document was last fetched. The endpoints it returns are
    /// effectively static, so re-fetching them on every `restoreSession`/brand switch (as a
    /// bounced brand did twice within three minutes in a support bundle) is wasted round trips.
    private var oidcDiscoveredAt: Date?
    private static let oidcDiscoveryTTL: TimeInterval = 6 * 60 * 60

    func discoverOIDCConfiguration(force: Bool = false) async throws {
        if !force, tokenEndpoint != nil, authorizationEndpoint != nil,
           let discoveredAt = oidcDiscoveredAt,
           now().timeIntervalSince(discoveredAt) < Self.oidcDiscoveryTTL {
            return
        }
        if let oidcDiscoveryTask {
            try applyOIDCDiscovery(await oidcDiscoveryTask.value)
            return
        }
        let task = Task { try await self.loadOIDCDiscovery() }
        oidcDiscoveryTask = task
        defer { oidcDiscoveryTask = nil }
        try applyOIDCDiscovery(await task.value)
    }

    private func loadOIDCDiscovery() async throws -> PolestarOIDCConfiguration {
        try await PolestarOIDCClient(providerURL: oidcProviderURL, session: session,
                                     diagnosticLog: diagnosticLog).discover()
    }

    private func applyOIDCDiscovery(_ configuration: PolestarOIDCConfiguration) throws {
        tokenEndpoint = configuration.tokenEndpoint
        authorizationEndpoint = configuration.authorizationEndpoint
        userinfoEndpoint = configuration.userinfoEndpoint
        revocationEndpoint = configuration.revocationEndpoint
        oidcDiscoveredAt = now()
    }

    func obtainAuthorizationCode(email: String, password: String,
                                         clientID: String? = nil, redirectURI: URL? = nil,
                                         scope: String? = nil) async throws
        -> (code: String, verifier: String) {
        guard let authorizationEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        let callbackURL = redirectURI ?? oidcRedirectURL
        let queryItems = Self.authorizationQueryItems(
            clientID: clientID ?? oidcClientID,
            redirectURI: callbackURL.absoluteString,
            scope: scope ?? oidcScope,
            state: state,
            challenge: Self.codeChallenge(for: verifier)
        )
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw PolestarError.incompatibleAPI(operation: "authorization endpoint")
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw PolestarError.incompatibleAPI(operation: "authorization request")
        }
        var request = URLRequest(url: url)
        request.setValue("Hisingen/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await perform(request)
        logger.info("Authorization page returned status \(response.statusCode, privacy: .public)")

        let authorizationCallback = redirectDelegate.takeCallback() ?? response.url
        if let code = try extractValidatedCode(from: authorizationCallback, expectedState: state,
                                              callbackURL: callbackURL) {
            return (code, verifier)
        }
        let html = String(decoding: data, as: UTF8.self)
        guard let resumePath = Self.extractResumePath(from: html) else {
            throw PolestarError.incompatibleAPI(operation: "Polestar sign-in form")
        }
        let code = try await performLogin(
            resumePath: resumePath,
            queryItems: queryItems,
            email: email,
            password: password,
            expectedState: state,
            callbackURL: callbackURL
        )
        return (code, verifier)
    }

    private func performLogin(resumePath: String, queryItems: [URLQueryItem],
                              email: String, password: String,
                              expectedState: String,
                              callbackURL: URL? = nil) async throws -> String {
        guard resumePath.hasPrefix("/"),
              var components = URLComponents(url: oidcProviderURL.appendingPathComponent(resumePath),
                                             resolvingAgainstBaseURL: false) else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        components.queryItems = (components.queryItems ?? []) + queryItems
        guard let loginURL = components.url else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }

        let (data, response) = try await postForm(
            to: loginURL,
            fields: ["pf.username": email, "pf.pass": password]
        )
        logger.info("Polestar sign-in returned status \(response.statusCode, privacy: .public)")
        let loginCallback = redirectDelegate.takeCallback() ?? response.url
        if let code = try extractValidatedCode(from: loginCallback, expectedState: expectedState,
                                              callbackURL: callbackURL) { return code }

        if let uid = Self.queryValue("uid", from: response.url) {
            let (_, confirmation) = try await postForm(
                to: loginURL,
                fields: ["pf.submit": "true", "subject": uid]
            )
            let confirmationCallback = redirectDelegate.takeCallback() ?? confirmation.url
            if let code = try extractValidatedCode(from: confirmationCallback, expectedState: expectedState,
                                                  callbackURL: callbackURL) {
                return code
            }
        }

        let html = String(decoding: data, as: UTF8.self)
        if PolestarSignInPage.rejectsCredentials(html) {
            throw PolestarError.authenticationRequired(.invalidCredentials)
        }
        throw PolestarError.authenticationRequired(.callbackRejected)
    }

    private func extractValidatedCode(from url: URL?, expectedState: String,
                                      callbackURL: URL? = nil) throws -> String? {
        guard let url else { return nil }
        let expected = callbackURL ?? oidcRedirectURL
        guard url.scheme == expected.scheme,
              url.host == expected.host,
              Self.normalizedPath(url) == Self.normalizedPath(expected) else { return nil }
        guard Self.queryValue("state", from: url) == expectedState else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        return Self.queryValue("code", from: url)
    }

    func candidateCommand(_ token: String?, epoch: Int, flowGeneration: UInt) -> PolestarCandidateCommand? {
        guard let token else { return nil }
        let commandGeneration = commandAuthorization.generation
        return PolestarCandidateCommand(token: token, isCurrent: { [self] in
            await candidateCommandIsCurrent(token, epoch: epoch, flowGeneration: flowGeneration,
                                            commandGeneration: commandGeneration)
        })
    }

    private func candidateCommandIsCurrent(_ token: String, epoch: Int, flowGeneration: UInt,
                                           commandGeneration: UInt) -> Bool {
        sessionEpoch == epoch && webAuthorization.isCurrent(flowGeneration) &&
            commandAuthorization.isCurrent(commandGeneration) && commandAccessToken == token &&
            verifiedCommandToken?.token == token && (commandTokenExpiry?.timeIntervalSince(now()) ?? 0) > 0
    }

    func setCandidateDiscoveryCommand(_ command: PolestarCandidateCommand) {
        candidateDiscoveryCommand = command
    }

    func makeLoginCandidate() async -> PolestarLoginCandidate {
        let candidate = PolestarAPI(keychain: KeychainStore(service: "io.kheirallah.hisingen.login.\(UUID())"),
            imageCache: imageCache, preferences: preferences, diagnosticLog: diagnosticLog, backoffs: backoffs,
            now: now, persistSessionToken: { _ in })
        await candidate.configureCandidate(configuration: session.configuration,
            tokenEndpoint: tokenEndpoint, authorizationEndpoint: authorizationEndpoint,
            userinfoEndpoint: userinfoEndpoint, revocationEndpoint: revocationEndpoint)
        return PolestarLoginCandidate(api: candidate)
    }

    func configureCandidate(configuration: URLSessionConfiguration,
                            tokenEndpoint: URL?, authorizationEndpoint: URL?,
                            userinfoEndpoint: URL?, revocationEndpoint: URL?) {
        self.session.invalidateAndCancel()
        self.session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
        self.tokenEndpoint = tokenEndpoint
        self.authorizationEndpoint = authorizationEndpoint
        self.userinfoEndpoint = userinfoEndpoint
        self.revocationEndpoint = revocationEndpoint
    }

    func installCandidateToken(_ token: TokenResponseDTO) {
        accessToken = token.accessToken
        refreshToken = token.refreshToken
        tokenLifetime = TimeInterval(token.expiresIn)
        tokenExpiry = now().addingTimeInterval(TimeInterval(token.expiresIn))
    }

    func candidateSnapshot() throws -> PolestarConsumerSession {
        guard let accessToken, let tokenExpiry else { throw PolestarError.authenticationRequired(.expiredSession) }
        return PolestarConsumerSession(accessToken: accessToken, refreshToken: refreshToken,
            tokenExpiry: tokenExpiry, tokenLifetime: tokenLifetime,
            cars: cars, identities: identities, selectedVIN: selectedVIN,
            discoverySucceeded: discoverySucceeded, tokenEndpoint: tokenEndpoint,
            authorizationEndpoint: authorizationEndpoint, userinfoEndpoint: userinfoEndpoint,
            revocationEndpoint: revocationEndpoint)
    }

    func commitCandidate(_ candidate: PolestarConsumerSession, commandRefresh: String?) throws {
        clearAccountState()
        tokenEndpoint = candidate.tokenEndpoint
        authorizationEndpoint = candidate.authorizationEndpoint
        userinfoEndpoint = candidate.userinfoEndpoint
        revocationEndpoint = candidate.revocationEndpoint
        try tokens.adopt(.init(accessToken: candidate.accessToken,
                               refreshToken: candidate.refreshToken,
                               expiresIn: candidate.tokenLifetime), now: now())
        tokenExpiry = candidate.tokenExpiry
        if candidate.refreshToken == nil { try? keychain.deleteSessionToken() }
        commandTokens.refreshToken = commandRefresh
        cars = candidate.cars
        identities = candidate.identities
        selectedVIN = candidate.selectedVIN
        discoverySucceeded = candidate.discoverySucceeded
    }

    /// Builds the web client's authorization URL for an in-app `WKWebView` when headless PingFederate
    /// login is rejected with an interactive challenge (CAPTCHA, 2FA, Terms acceptance, etc.).
    func beginWebAuthorization() async throws -> (authorizeURL: URL, redirectURI: URL) {
        try Task.checkCancellation()
        // Non-destructive: do not clear the warm session to open the window.
        // The prior session stays usable if the user closes the window
        // (callbackRejected) – clearing happened only on success in
        // completeWebAuthorization via exchangeCodeForToken + fetchCarInfo.
        let epoch = sessionEpoch
        if authorizationEndpoint == nil { try await discoverOIDCConfiguration() }
        try requireSession(epoch)
        guard let authorizationEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw PolestarError.incompatibleAPI(operation: "authorization endpoint")
        }
        components.queryItems = Self.authorizationQueryItems(
            clientID: oidcClientID,
            redirectURI: oidcRedirectURL.absoluteString,
            scope: oidcScope,
            state: state,
            challenge: Self.codeChallenge(for: verifier)
        )
        guard let url = components.url else {
            throw PolestarError.incompatibleAPI(operation: "authorization request")
        }
        webAuthorization.begin(verifier: verifier, state: state, now: now())
        return (url, oidcRedirectURL)
    }

    /// Completes web-client authorization from the `https://www.polestar.com/sign-in-callback` redirect
    /// captured by `PolestarWebSignInPresenter`.
    func completeWebAuthorization(callbackURL: URL, preferredVIN: String? = nil,
                                  features: FeatureSelection = .default) async throws {
        let epoch = sessionEpoch
        let completion = try webAuthorization.consume(
            callbackURL: callbackURL, redirectURL: oidcRedirectURL, now: now(), maximumAge: 600
        )
        defer { webAuthorization.finish(generation: completion.generation) }
        let commandRefresh = commandRefreshToken ?? (try? keychain.readCommandSessionToken())
        let command = candidateCommand(freshCommandAccessToken(), epoch: epoch, flowGeneration: completion.generation)
        let candidate = await makeLoginCandidate()
        try requireWebAuthorization(epoch: epoch, generation: completion.generation)
        let snapshot = try await candidate.exchange(code: completion.code, verifier: completion.verifier,
                                                     preferredVIN: preferredVIN, command: command)
        try requireWebAuthorization(epoch: epoch, generation: completion.generation)
        await grpc.invalidateDiscoveredHost()
        try requireWebAuthorization(epoch: epoch, generation: completion.generation)
        try commitCandidate(snapshot, commandRefresh: commandRefresh)
        let committedEpoch = sessionEpoch
        if features.contains(.vehicleImage), let activeVIN = selectedVIN { await fetchCarImage(vin: activeVIN) }
        try requireSession(committedEpoch)
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
        try requireSession(committedEpoch)
        logger.info("Polestar web-client token acquired via interactive web sign-in")
    }

    /// Builds the command client's authorization URL for a real browser to open – the
    /// `polestar-explore://` redirect is the command client's own registered custom scheme, so
    /// unlike the web client (whose redirect lands on `polestar.com`, a domain Hisingen doesn't
    /// control), the OS can route the final redirect straight back into the app. Used by
    /// `PolestarCommandSignInPresenter` instead of the scripted PingFederate form-fill used for
    /// the web client's own sign-in – Hisingen never sees the password for this flow.
    ///
    /// Any macOS app can also register `polestar-explore://`, so a hostile app that wins the
    /// LaunchServices registration could receive this callback. It is not exploitable: the
    /// authorization `code` is PKCE-bound to the command flow's verifier, which never leaves this
    /// process, and `completeCommandAuthorization` rejects any callback whose `state` does not
    /// match the pending state. This is the same exposure the official Polestar app carries.
    func beginCommandAuthorization() async throws -> URL {
        try Task.checkCancellation()
        invalidateCommandAuthorization()
        let epoch = sessionEpoch
        let commandEpoch = commandAuthorization.generation
        if authorizationEndpoint == nil { try await discoverOIDCConfiguration() }
        try requireSession(epoch)
        // `completeCommandAuthorization` verifies the minted grant against the consumer session
        // and every invocation is dispatched with it. Without one the browser round-trip can
        // only end in a discarded grant, so say so before a window opens.
        guard accessToken != nil || refreshToken != nil else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        // The grant this flow mints is only kept when `completeCommandAuthorization` can verify it
        // against the account session, and that verification refreshes the session first. Without a
        // refresh token the check cannot run, so the browser trip would end in a discarded grant
        // minutes later with nothing to show for it. Refuse up front with the accurate reason: the
        // account session needs a sign-in, not another authorization.
        guard refreshToken != nil else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        guard commandAuthorization.isCurrent(commandEpoch) else { throw CancellationError() }
        guard let authorizationEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        guard var components = URLComponents(url: authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw PolestarError.incompatibleAPI(operation: "authorization endpoint")
        }
        components.queryItems = Self.authorizationQueryItems(
            clientID: commandClientID,
            redirectURI: commandRedirectURL.absoluteString,
            scope: oidcScope,
            state: state,
            challenge: Self.codeChallenge(for: verifier)
        )
        guard let url = components.url else {
            throw PolestarError.incompatibleAPI(operation: "authorization request")
        }
        commandAuthorization.begin(verifier: verifier, state: state, now: now())
        return url
    }

    /// Completes command-client authorization from the `polestar-explore://` callback the OS
    /// handed back after the user signed in through their real browser.
    func completeCommandAuthorization(callbackURL: URL) async throws {
        let epoch = sessionEpoch
        let completion = try commandAuthorization.consume(
            callbackURL: callbackURL, redirectURL: commandRedirectURL, now: now(), maximumAge: 600
        )
        defer { commandAuthorization.finish(generation: completion.generation) }
        let token = try await exchangeCode(completion.code, verifier: completion.verifier,
                                           clientID: commandClientID, redirectURI: commandRedirectURL)
        try requireSession(epoch)
        guard commandAuthorization.isCurrent(completion.generation) else { throw CancellationError() }
        guard let durableRefresh = token.refreshToken, !durableRefresh.isEmpty else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        // Persist before verification: a transient userinfo failure must not discard
        // a freshly-minted grant and force a second browser trip.
        try saveCommandToken(durableRefresh)
        commandAccessToken = token.accessToken
        commandRefreshToken = durableRefresh
        commandTokenExpiry = now().addingTimeInterval(TimeInterval(token.expiresIn))
        let verifiedAccount: AccountIdentity
        do {
            verifiedAccount = try await verifyCommandAccount(accessToken: token.accessToken)
        } catch {
            // Definitive account mismatch discards the grant; transient verification
            // failures keep it for a later retry.
            if isSessionCurrent(epoch), commandAuthorization.isCurrent(completion.generation),
               let pErr = error as? PolestarError, case .authenticationRequired(.callbackRejected) = pErr {
                clearCommandAuthorization()
            }
            throw error
        }
        try requireSession(epoch)
        guard commandAuthorization.isCurrent(completion.generation) else { throw CancellationError() }
        verifiedCommandToken = (token.accessToken, epoch, verifiedAccount.sub)
        logger.info("Polestar command-client token acquired via browser sign-in")
    }

    func exchangeCode(_ code: String, verifier: String,
                              clientID: String, redirectURI: URL) async throws -> TokenResponseDTO {
        guard let tokenEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier
        ])
        return try await Self.requestToken(request: request, session: session,
                                           invalidReason: .callbackRejected,
                                           diagnosticLog: diagnosticLog)
    }

    func exchangeCodeForToken(_ code: String, verifier: String, generation: UInt? = nil) async throws {
        let epoch = sessionEpoch
        let generation = generation ?? webAuthorization.generation
        let token = try await exchangeCode(code, verifier: verifier,
                                           clientID: oidcClientID, redirectURI: oidcRedirectURL)
        try requireSession(epoch)
        // Starting a new web authorization leaves the warm session in place, so it no longer
        // bumps `sessionEpoch`. The flow's own generation is what tells this exchange that a
        // newer attempt replaced it, and a replaced exchange must not write tokens.
        guard webAuthorization.isCurrent(generation) else { throw CancellationError() }
        verifiedCommandToken = nil
        tokens.cancelInFlightGrant()
        try tokens.adopt(TokenLifecycle.Grant(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresIn: TimeInterval(token.expiresIn)), now: now())
    }

    func refreshTokenIfNeeded() async throws {
        try await refreshAccessToken(force: false)
    }

    /// `replacing` is the token the server just refused. The lifecycle keeps it: when the session
    /// no longer holds that token, another caller's grant already replaced it, which closes the
    /// late-arrival race where a fan-out of 401 responses could each force a separate refresh
    /// after the original single-flight grant completed.
    func refreshAccessToken(force: Bool, replacing rejectedAccessToken: String? = nil) async throws {
        let requestEpoch = sessionEpoch
        let reason: TokenLifecycle.Reason = force
            ? .serverRefused(rejectedToken: rejectedAccessToken)
            : .renewalWindow
        // Captured before the closure runs so the grant does not read state the lifecycle owns;
        // the missing-endpoint guard lives inside it, where a grant already in flight is awaited
        // rather than failed. The lifecycle decides whether a grant is needed at all.
        let endpoint = tokenEndpoint
        let refresh = refreshToken
        let clientID = oidcClientID
        let currentSession = session
        let diagnosticLog = diagnosticLog
        let outcome = try await tokens.refresh(
            reason, now: now(),
            epochIsCurrent: { await self.isSessionCurrent(requestEpoch) },
            grant: {
                guard let endpoint, let refresh else {
                    throw PolestarError.authenticationRequired(.expiredSession)
                }
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody([
                    "grant_type": "refresh_token",
                    "client_id": clientID,
                    "refresh_token": refresh
                ])
                let token = try await Self.requestToken(request: request, session: currentSession,
                                                        invalidReason: .expiredSession,
                                                        diagnosticLog: diagnosticLog,
                                                        deadGrantReason: .noStoredSession,
                                                        malformedRotation: { [self] rotated in
                    try await preserveConsumerRotation(rotated, replacing: refresh, epoch: requestEpoch)
                })
                return TokenLifecycle.Grant(accessToken: token.accessToken,
                                            refreshToken: token.refreshToken,
                                            expiresIn: TimeInterval(token.expiresIn))
            }
        )
        try requireSession(requestEpoch)
        if outcome == .deadGrant {
            await discardDeadRefreshToken()
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
    }

    /// The IdP rejected the refresh grant with `invalid_grant`/`expired_token`: the stored
    /// token was rotated out or revoked, and every replay is a failed login against it
    /// (lockout risk). Drop the persisted session copy – memory, Keychain, and the preferences
    /// cache – so nothing re-reads the dead token, mirroring `VolvoAPI.discardDeadRefreshToken`.
    /// The command grant is independent (separate OAuth client `lp8dyrd_10`) and is left
    /// intact: a dead web session does not imply a dead command grant. The command grant
    /// is cleared only by its own dead-grant path in `commandClientAuthorization`.
    /// In-flight authorization work is deliberately not cancelled: `commandClientAuthorization`
    /// still resolves its own outcome from current storage.
    func discardDeadRefreshToken() async {
        tokens.reset()
        // A failed delete leaves the dead token readable, so it is logged loudly rather than dropped.
        do { try keychain.deleteSessionToken() } catch {
            logger.error("Polestar dead session token could not be deleted from Keychain: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
        }
        // `PreferencesStore.hasResumableSession` memoises a per-brand answer. Without this the
        // garage scanner and account cards keep believing Polestar is resumable for the rest of
        // the process and replay the grant the IdP just refused.
        await MainActor.run { preferences.invalidateSessionCache() }
    }

    /// Refresh near expiry while avoiding a margin as large as a short-lived token. Ten per
    /// cent, clamped to 5...60 seconds, absorbs clock and transit skew without discarding most
    /// of a five-minute grant.
    static func tokenRenewalMargin(lifetime: TimeInterval) -> TimeInterval {
        guard lifetime > 0 else { return PolestarConfig.defaultRenewalMargin }
        let range = PolestarConfig.renewalMarginRange
        return min(range.upperBound, max(range.lowerBound, lifetime * PolestarConfig.renewalMarginFraction))
    }

    static func requestToken(request: URLRequest, session: URLSession,
                             invalidReason: AuthFailureReason,
                             diagnosticLog: APIDiagnosticLogStore,
                             deadGrantReason: AuthFailureReason? = nil,
                             malformedRotation: (@Sendable (String) async throws -> Void)? = nil) async throws -> TokenResponseDTO {
        let (data, response) = try await HTTPExchange.data(
            for: request, using: session, limit: 256_000,
            operation: "Polestar token request", provider: .polestar,
            diagnosticLog: diagnosticLog,
            semanticError: { data, _ in Self.oauthErrorCode(in: data) }
        )
        if response.statusCode == 400 {
            // `invalid_grant`/`expired_token` mean the presented grant (a refresh token
            // rotated out or revoked) is permanently dead; only this body distinguishes it
            // from the other 400 rejections.
            if let deadGrantReason, OAuthErrorBody.isDeadGrant(data) {
                throw PolestarError.authenticationRequired(deadGrantReason)
            }
            throw PolestarError.authenticationRequired(invalidReason)
        }
        if let failure = PolestarError.httpFailure(
            statusCode: response.statusCode,
            retryAfter: ServiceResponseClassifier.retryAfter(from: response),
            authenticationReason: invalidReason,
            forbiddenIsAuthentication: true,
            operation: "token request"
        ) {
            throw failure
        }
        let token: TokenResponseDTO
        do {
            token = try PolestarDecoding.decode(TokenResponseDTO.self, from: data,
                operation: "token response", logger: AppLog.logger("polestar-api"))
        } catch {
            try await preserveMalformedRotation(data, using: malformedRotation)
            throw error
        }
        guard !token.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              token.expiresIn > 0, token.expiresIn <= 31_536_000,
              token.tokenType == nil || token.tokenType?.lowercased() == "bearer" else {
            try await preserveMalformedRotation(data, using: malformedRotation)
            throw PolestarError.decoding(operation: "token response")
        }
        return token
    }

    private struct RotatedGrant: Decodable {
        let refreshToken: String?
        enum CodingKeys: String, CodingKey { case refreshToken = "refresh_token" }
    }

    private static func preserveMalformedRotation(_ data: Data,
        using persist: (@Sendable (String) async throws -> Void)?) async throws {
        guard let persist,
              let refresh = (try? JSONDecoder().decode(RotatedGrant.self, from: data))?.refreshToken,
              !refresh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try await persist(refresh)
    }

    func preserveConsumerRotation(_ rotated: String, replacing previous: String, epoch: Int) throws {
        try requireSession(epoch)
        guard refreshToken == previous else { throw CancellationError() }
        refreshToken = rotated
        do { try saveSessionToken(rotated) }
        catch { logger.error("Polestar rotated refresh token could not be persisted") }
    }

    /// The diagnostic-log form of the OAuth `error` code; see `OAuthErrorBody`.
    static func oauthErrorCode(in data: Data) -> String? {
        OAuthErrorBody.diagnosticCode(in: data)
    }


    /// A query that takes no variables.
    func graphQL<Payload: Decodable>(query: String, token: String, operation: String) async throws
        -> GraphQLResponse<Payload> {
        try await graphQL(query: query, variables: NoVariables?.none, token: token, operation: operation)
    }

    func graphQL<Payload: Decodable, Variables: Encodable>(
        query: String, variables: Variables?, token: String, operation: String
    ) async throws -> GraphQLResponse<Payload> {
        return try await makeGraphQLClient().query(query, variables: variables, token: token, operation: operation)
    }

    private func makeGraphQLClient() -> PolestarGraphQLClient {
        PolestarGraphQLClient(endpoint: apiBaseURL, session: session,
            diagnosticLog: diagnosticLog, appVersion: Self.appVersion,
            refresh: { [self] rejected in try await tokenAfterRefresh(replacing: rejected) })
    }

    /// Forces a refresh of the session grant and returns the access token it produced.
    /// `rejected` is the token the server just refused, so a refresh another caller already
    /// completed is reused instead of repeated.
    private func tokenAfterRefresh(replacing rejected: String) async throws -> String {
        try await refreshAccessToken(force: true, replacing: rejected)
        guard let refreshed = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        return refreshed
    }

    func fetchCarInfo(preferredVIN: String?, webGeneration: UInt? = nil) async throws {
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let requestEpoch = sessionEpoch
        let legacyCars = try await discoverLegacyCars(token: token)
        let accountCars = try await enrichWithVDMS(legacyCars)
        try Task.checkCancellation()
        guard requestEpoch == sessionEpoch else {
            logger.debug("Discarding superseded Polestar vehicle discovery")
            return
        }
        if let webGeneration, !webAuthorization.isCurrent(webGeneration) { throw CancellationError() }
        try adoptDiscoveredCars(accountCars, preferredVIN: preferredVIN)
    }

    /// The primary discovery source (`mystar-v2`). A failure is only degradable when it is
    /// specific to this data source. Auth, rate-limit, server, and transport failures must
    /// propagate – previously a swallowed 401 or 429 fell through to the manual-VIN branch and
    /// surfaced as `.notConfigured` ("Open Settings to sign in"), masking the real problem.
    private func discoverLegacyCars(token: String) async throws -> [ConsumerCarDTO] {
        do {
            return try await PolestarVehicleDiscovery(client: makeGraphQLClient()).primary(token: token)
        } catch {
            try Task.checkCancellation()
            if Self.isRequestLevelFailure(error) { throw error }
            logger.warning("Polestar vehicle discovery degraded (provider-specific): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            return []
        }
    }

    /// Adds the secondary source (`app-backend`, VDMS) to what the primary returned.
    ///
    /// VDMS validates against the *command* client's token (`lp8dyrd_10`) – the same split the
    /// invocation commands need – not the web-client session token, which it answers with
    /// "Could not validate the accessToken". Without command authorization there is nothing
    /// usable to send it, so the call is skipped rather than fired to fail.
    private func enrichWithVDMS(_ legacyCars: [ConsumerCarDTO]) async throws -> [ConsumerCarDTO] {
        let vdmsToken: String?
        if backoffs.blockedUntil(Self.discoveryBackoff) != nil {
            logger.info("Polestar VDMS enrichment remains in its persistent-failure backoff window")
            vdmsToken = nil
        } else if let command = candidateDiscoveryCommand, await command.isCurrent() {
            vdmsToken = command.token
        } else if case .authorized(let commandToken) = await commandClientAuthorization() {
            vdmsToken = commandToken
        } else {
            vdmsToken = nil
        }
        guard let vdmsToken else { return legacyCars }
        do {
            let vdmsCars = try await fetchAppBackendCars(token: vdmsToken)
            backoffs.unblock(Self.discoveryBackoff)
            return Self.mergeDiscoveryCars(primary: legacyCars, vdms: vdmsCars)
        } catch {
            try Task.checkCancellation()
            if Self.isRequestLevelFailure(error) {
                // The app-backend endpoint is a secondary discovery source. If the primary
                // query already produced cars, keep those instead of failing the session;
                // only fail when we would otherwise report an empty garage.
                if legacyCars.isEmpty { throw error }
                logger.info("Polestar VDMS discovery failed at request level; continuing with primary discovery results")
            } else {
                // A client-side rejection (426), an API-shape mismatch, or a token the
                // app-backend refuses to validate won't fix itself on the next discovery –
                // stand down for a day.
                if Self.vdmsFailureIsPersistent(error) {
                    backoffs.block(
                        Self.discoveryBackoff,
                        until: now().addingTimeInterval(PolestarConfig.discoveryBackoffInterval),
                        reason: Self.vdmsFailureCategory(error))
                }
                logger.info("Polestar VDMS discovery degraded (provider-specific): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            }
            return legacyCars
        }
    }

    /// Publishes the discovered garage, or falls back to a user-typed VIN when discovery found
    /// nothing.
    private func adoptDiscoveredCars(_ accountCars: [ConsumerCarDTO], preferredVIN: String?) throws {
        if accountCars.isEmpty {
            guard let manualVIN = preferredVIN?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  SettingsValidation.isValidVIN(manualVIN) else { throw PolestarError.notConfigured }
            cars = [CarSummary(vin: manualVIN, title: manualVIN)]
            // Manual fallback is not a successful discovery – see discoverySucceeded.
            discoverySucceeded = false
            // An empty identity records successful discovery without borrowing another car's metadata.
            identities[manualVIN] = .empty
            selectedVIN = manualVIN
            return
        }
        cars = accountCars.compactMap { car in
            guard let vin = car.vin else { return nil }
            let title = [car.modelName, car.modelYear?.value].compactMap { $0 }.joined(separator: " · ")
            return CarSummary(
                vin: vin,
                title: title.isEmpty ? vin : title,
                modelName: car.modelName,
                modelYear: car.modelYear?.value,
                registrationNo: car.registrationNo
            )
        }
        let selected = preferredVIN.flatMap { wanted in
            accountCars.first(where: { $0.vin == wanted })
        } ?? accountCars.first
        guard let vin = selected?.vin else { throw PolestarError.notConfigured }
        for car in accountCars { applyCarInfo(car) }
        selectedVIN = vin
        discoverySucceeded = true
    }

    static func mergeDiscoveryCars(primary: [ConsumerCarDTO], vdms: [ConsumerCarDTO]) -> [ConsumerCarDTO] {
        PolestarVehicleDiscovery.merge(primary: primary, vdms: vdms)
    }

    private func fetchAppBackendCars(token: String) async throws -> [ConsumerCarDTO] {
        let query = """
        query GetVDMSCars {
          vdms {
            getVehiclesInformation {
              vin internalVehicleIdentifier registrationNo modelYear
              content {
                model { name }
              }
            }
          }
        }
        """
        let body = AppBackendRequest(
            operationName: "GetVDMSCars",
            query: query,
            extensions: .init(clientLibrary: .init(
                name: PolestarAppIdentity.graphQLClientLibrary.name,
                version: PolestarAppIdentity.graphQLClientLibrary.version))
        )
        var request = URLRequest(url: appBackendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("multipart/mixed;deferSpec=20220824, application/graphql-response+json, application/json",
                         forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-PolestarId-Authorization")
        request.setValue("GetVDMSCars", forHTTPHeaderField: "X-APOLLO-OPERATION-NAME")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-APOLLO-REQUEST-UUID")
        request.setValue(Locale.current.region?.identifier ?? market ?? "SE", forHTTPHeaderField: "X-Polestar-Locale")
        // The app-backend rejects clients below its app-version floor; see `PolestarAppIdentity`.
        request.setValue(PolestarAppIdentity.version, forHTTPHeaderField: "X-Polestar-Force-Update-Version")
        request.setValue(PolestarAppIdentity.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await perform(request, operation: "VDMS vehicle discovery")
        try validateHTTP(response, operation: "VDMS vehicle discovery")
        let decoded = try PolestarDecoding.decode(GraphQLResponse<AppBackendCarsPayloadDTO>.self,
            from: data, operation: "VDMS vehicle discovery", logger: logger)
        if let errors = decoded.errors, !errors.isEmpty {
            throw PolestarError.graphQL(Self.mapErrors(errors), hasPartialData: decoded.data != nil)
        }
        return (decoded.data?.vdms?.getVehiclesInformation ?? []).map(\.consumerCar)
    }

    /// Whether a VDMS discovery failure warrants standing down for a day rather than
    /// re-probing on every discovery: a client-side rejection (426 Upgrade Required), an
    /// API-shape mismatch, or a GraphQL-level authentication rejection ("Could not validate
    /// the accessToken") – none of which the next attempt would recover from.
    static func vdmsFailureIsPersistent(_ error: Error) -> Bool {
        switch error as? PolestarError {
        case .client, .incompatibleAPI, .permissionDenied:
            return true
        case .graphQL(let errors, _):
            return errors.contains { entry in
                (entry.code?.localizedCaseInsensitiveContains("auth") ?? false)
                    || entry.message.localizedCaseInsensitiveContains("accesstoken")
            }
        default:
            return false
        }
    }

    /// Polestar's secondary discovery source, which stands down per install rather than per
    /// vehicle: a client-version or schema rejection is not account-specific.
    static let discoveryBackoff = ProviderBackoffStore.Subject("polestar.vdms-discovery")

    static func vdmsDiscoveryDiagnostics(
        backoffs: ProviderBackoffStore = ProviderBackoffStore(),
        now: Date = Date()
    ) -> VDMSDiscoveryDiagnostics? {
        guard let blockedUntil = backoffs.blockedUntil(Self.discoveryBackoff, now: now) else { return nil }
        return VDMSDiscoveryDiagnostics(
            blockedUntil: blockedUntil,
            reason: backoffs.reason(for: Self.discoveryBackoff, fallback: "persistentFailure")
        )
    }

    private static func vdmsFailureCategory(_ error: Error) -> String {
        switch error as? PolestarError {
        case .client(let statusCode): return "client-\(statusCode)"
        case .incompatibleAPI: return "incompatibleAPI"
        case .permissionDenied: return "permissionDenied"
        case .graphQL: return "graphQLAuthentication"
        default: return "persistentFailure"
        }
    }

    func applyCarInfo(vin: String) async throws {
        guard accessToken != nil else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        // All discovered identities are retained by VIN, so preparing a sibling needs no discovery.
        if identities[vin] != nil, cars.contains(where: { $0.vin == vin }) {
            return
        }
        try await fetchCarInfo(preferredVIN: vin)
        // No selection-equality post-check here, by design: identity reads are per-VIN now,
        // so a concurrent caller re-pointing `selectedVIN` after our discovery cannot
        // corrupt this car's telemetry. The only genuine failure is the VIN having left
        // the discovered garage entirely.
        guard cars.contains(where: { $0.vin == vin }) else { throw PolestarError.notConfigured }
    }

    private func applyCarInfo(_ car: ConsumerCarDTO) {
        guard let vin = car.vin else { return }
        identities[vin] = CarIdentity(
            internalVehicleIdentifier: car.internalVehicleIdentifier,
            modelName: car.modelName,
            modelYear: car.modelYear?.value,
            registrationNo: car.registrationNo,
            pno34: car.pno34,
            structureWeek: car.structureWeek?.value)
    }

    func fetchOwnerInfo() async {
        let epoch = sessionEpoch
        guard let token = accessToken, let userinfoEndpoint else { return }
        var request = URLRequest(url: userinfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = await optionalBody(for: request, limit: 256_000, operation: "user information"),
              let info = optionalDecode(UserInfoDTO.self, from: data, operation: "user information")
        else { return }
        guard epoch == sessionEpoch, !Task.isCancelled else { return }
        ownerFirstName = info.givenName ?? info.firstName
        market = info.market?.isEmpty == false ? info.market : nil
    }
    func fetchCarImage(vin: String) async {
        let epoch = sessionEpoch
        let requestID = artwork.begin(vin: vin)
        let requestedAngle = await MainActor.run { preferences.carRenderAngle.rawValue }
        guard epoch == sessionEpoch, !Task.isCancelled else { return }
        guard artwork.select(vin: vin, angle: requestedAngle, request: requestID,
                             cached: imageCache.image(for: vin, angle: requestedAngle)) else { return }
        guard let identity = identities[vin], let pno34 = identity.pno34,
              let structureWeek = identity.structureWeek, let modelYear = identity.modelYear else { return }
        let request: URLRequest
        do {
            request = try CarImagesRequest(pno34: pno34, structureWeek: structureWeek, modelYear: modelYear)
                .urlRequest(endpoint: publicApiURL, apiKey: publicApiKey)
        } catch {
            logger.debug("Vehicle image request could not be built: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            return
        }
        guard let (data, _) = await optionalBody(for: request, limit: Self.maxImageMetadataBytes,
                                                 operation: "vehicle image metadata"),
              let images = optionalDecode(GraphQLResponse<CarImagesPayloadDTO>.self, from: data,
                                          operation: "vehicle image metadata")?.data?.getCarImages
        else { return }
        guard epoch == sessionEpoch, !Task.isCancelled else { return }
        let pool = images.pool
        let pick = pool.first { $0.angle == requestedAngle }

        if artwork.needsImage(vin: vin, angle: requestedAngle), let url = pick?.httpsURL {
            if let (bytes, imageResponse) = await optionalBody(
                   for: URLRequest(url: url), limit: Self.maxImageBytes, operation: "vehicle image"),
               imageResponse.mimeType?.hasPrefix("image/") == true {
                guard epoch == sessionEpoch, !Task.isCancelled,
                      artwork.adopt(bytes, vin: vin, angle: requestedAngle, request: requestID) else { return }
                let angle = pick?.angle ?? requestedAngle
                imageCache.save(bytes, for: vin, angle: angle)
                // The angle-less slot is what the hero card, fleet card and refresh coordinator
                // read, so the picked render is stored there too.
                imageCache.save(bytes, for: vin)
            }
        }

        guard epoch == sessionEpoch, !Task.isCancelled else { return }
        for other in pool.prefix(4) {
            guard let otherAngle = other.angle,
                  let otherUrl = other.httpsURL,
                  imageCache.image(for: vin, angle: otherAngle) == nil else { continue }
            enqueueImageDownload(
                key: "\(vin)-angle-\(otherAngle)",
                request: URLRequest(url: otherUrl),
                operation: "vehicle angle image"
            ) { data in
                self.imageCache.save(data, for: vin, angle: otherAngle)
            }
        }
    }

    /// A 200 response for an optional fetch (owner name, artwork), or nil after recording why
    /// there is none. These degrade to "nothing" instead of failing the session, but the reason
    /// is logged at debug level so a missing render or name can be diagnosed. Cancellation is
    /// expected when the session or selected vehicle changes and stays silent.
    private func optionalBody(for request: URLRequest, limit: Int,
                              operation: String) async -> (Data, HTTPURLResponse)? {
        do {
            let (data, response) = try await HTTPExchange.data(
                for: request, using: session, limit: limit, operation: operation,
                provider: .polestar, diagnosticLog: diagnosticLog)
            guard response.statusCode == 200 else {
                logger.debug("Optional \(operation, privacy: .public) returned HTTP \(response.statusCode, privacy: .public)")
                return nil
            }
            return (data, response)
        } catch is CancellationError {
            return nil
        } catch {
            logger.debug("Optional \(operation, privacy: .public) failed: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            return nil
        }
    }

    private func optionalDecode<Value: Decodable>(_ type: Value.Type, from data: Data,
                                                  operation: String) -> Value? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            PolestarDecoding.log(error, operation: operation, logger: logger)
            return nil
        }
    }

    /// Largest image or image-metadata body accepted; `HTTPExchange` fails the request beyond it.
    private static let maxImageBytes = 5_000_000
    private static let maxImageMetadataBytes = 1_000_000

    private func enqueueImageDownload(
        key: String,
        request: URLRequest,
        operation: String,
        save: @escaping @Sendable (Data) -> Void
    ) {
        guard imageDownloadTasks[key] == nil, imageDownloadTasks.count < 4 else { return }
        let epoch = sessionEpoch
        let taskID = UUID()
        let task = Task { [weak self, session, diagnosticLog] in
            do {
                let (data, response) = try await HTTPExchange.data(
                    for: request, using: session, limit: Self.maxImageBytes, operation: operation,
                    provider: .polestar, diagnosticLog: diagnosticLog
                )
                if response.statusCode == 200, response.mimeType?.hasPrefix("image/") == true,
                   !Task.isCancelled {
                    await self?.saveImageDownload(data, epoch: epoch, key: key, taskID: taskID, save: save)
                }
            } catch is CancellationError {
                // Cancellation is expected when the session or selected vehicle changes.
            } catch {
                self?.logger.debug("Background image download failed for \(operation, privacy: .public): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            }
            await self?.finishImageDownload(key, taskID: taskID)
        }
        imageDownloadTasks[key] = task
        imageDownloadTaskIDs[key] = taskID
    }

    private func saveImageDownload(_ data: Data, epoch: Int, key: String, taskID: UUID,
                                   save: @Sendable (Data) -> Void) {
        guard epoch == sessionEpoch, imageDownloadTaskIDs[key] == taskID else { return }
        save(data)
    }

    private func finishImageDownload(_ key: String, taskID: UUID) {
        guard imageDownloadTaskIDs[key] == taskID else { return }
        imageDownloadTasks[key] = nil
        imageDownloadTaskIDs[key] = nil
    }

    func cancelImageDownloads() {
        imageDownloadTasks.values.forEach { $0.cancel() }
        imageDownloadTasks.removeAll()
        imageDownloadTaskIDs.removeAll()
    }


    func clearAccountState(keepRefreshToken: Bool = false, keepAccessToken: Bool = false) {
        sessionEpoch &+= 1
        cancelImageDownloads()
        webAuthorization.invalidate()
        invalidateCommandAuthorization()
        tokens.reset(keepingRefreshToken: keepRefreshToken, keepingAccessToken: keepAccessToken)
        cars = []
        discoverySucceeded = false
        identities = [:]
        imagePreparationAttempts = [:]
        ownerInfoPrepared = false
        ownerInfoRetryAt = nil
        artwork.reset()
        candidateDiscoveryCommand = nil
        selectedVIN = nil
        ownerFirstName = nil
        market = nil
        capabilityAuthority.reset()
        remoteCommandsInFlight.reset()
    }

    static func makeSession(delegate: URLSessionDelegate) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        FormURLEncoding.body(fields)
    }

    private static func authorizationQueryItems(clientID: String, redirectURI: String,
                                                scope: String, state: String,
                                                challenge: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
    }

    /// See `OAuthCallback.normalizedPath` – kept as a forwarding shim for the redirect
    /// delegate and existing call sites.
    static func normalizedPath(_ url: URL) -> String {
        OAuthCallback.normalizedPath(url)
    }

    static func queryValue(_ name: String, from url: URL?) -> String? {
        OAuthCallback.queryValue(name, from: url)
    }

    /// Wraps `PKCE.randomURLSafeString()` only to translate its `URLError` into the
    /// Polestar error domain the rest of this actor throws.
    private static func randomURLSafeString() throws -> String {
        do { return try PKCE.randomURLSafeString() }
        catch { throw PolestarError.invalidResponse(operation: "secure random generator") }
    }

    private static func codeChallenge(for verifier: String) -> String {
        PKCE.codeChallenge(for: verifier)
    }

    /// Forwards to `PolestarSignInPage`; kept so existing callers and tests keep their entry point.
    static func extractResumePath(from html: String) -> String? {
        PolestarSignInPage.resumePath(in: html)
    }

    static func isPlausibleResumePath(_ value: String) -> Bool {
        PolestarSignInPage.isPlausibleResumePath(value)
    }


    static func mapErrors(_ errors: [GraphQLErrorDTO]) -> [GraphQLServiceError] {
        errors.map { GraphQLServiceError(message: $0.message, path: $0.path, code: $0.code) }
    }

    /// Compact `code: message @ path` rendering used for diagnostics. GraphQL errors carry no
    /// credentials, only the field that was rejected and why.
    static func errorSummary(_ errors: [GraphQLErrorDTO]) -> String {
        errors.prefix(5).map { error in
            let code = error.code.map { "\($0): " } ?? ""
            let path = !error.path.isEmpty ? " @ \(error.path.joined(separator: "."))" : ""
            return "\(code)\(error.message)\(path)"
        }.joined(separator: " | ")
    }

    static func containsAuthenticationError(_ errors: [GraphQLErrorDTO]) -> Bool {
        errors.contains { error in
            // A field-scoped error rejects one field, not the session – GraphQL reuses the same
            // "not authorized" wording for both. Treating a newly restricted field as a dead
            // session tears down a working login and, with the refresh loop backing off on
            // authentication failures, hides every other card behind a stale cache.
            guard error.path.isEmpty else { return false }
            let code = error.code?.uppercased()
            if code == "UNAUTHENTICATED" || code == "UNAUTHORIZED"
                || code == "UNAUTHORIZED_EXCEPTION" || code == "401" { return true }
            let message = error.message.lowercased()
            return message.contains("not authenticated") || message.contains("unauthenticated")
                || message.contains("not authorized") || message.contains("invalid token")
                || message.contains("token has expired")
        }
    }

    static func isGlobalFailure(_ error: Error) -> Bool {
        PolestarReadFailurePolicy.abortRefresh(error)
    }

    /// Errors that mean the request itself failed – authentication, rate limiting, server
    /// outage, or transport breakdown. Callers that degrade provider-specific gaps to "no
    /// data" must still surface these: swallowing an expired session or a rate-limit window
    /// here is what made outages masquerade as "Open Settings to sign in".
    static func isRequestLevelFailure(_ error: Error) -> Bool {
        if PolestarReadFailurePolicy.abortRefresh(error) { return true }
        if case PolestarError.invalidResponse = error { return true }
        return false
    }
}

extension PolestarAPI: VehicleLiveStreaming {
    func liveVehicleUpdates(
        vin: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        return try await grpc.liveUpdates(vin: vin, accessToken: token, purpose: purpose)
    }

    func refreshLiveStreamAuthorization() async throws {
        guard let rejectedToken = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        try await refreshAccessToken(force: true, replacing: rejectedToken)
    }
}

final class OAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Both OAuth clients redirect through this one session, and the command client's callback
    /// is a custom scheme `URLSession` cannot load – so every callback the app might see has to
    /// be recognised here, or the redirect is followed into a failure and the code is lost.
    private let callbackURLs: [URL]
    private let lock = NSLock()
    private var callback: URL?

    init(callbackURLs: [URL]) {
        self.callbackURLs = callbackURLs
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        if let target = request.url, callbackURLs.contains(where: { candidate in
            target.scheme == candidate.scheme && target.host == candidate.host
                && PolestarAPI.normalizedPath(target) == PolestarAPI.normalizedPath(candidate)
        }) {
            lock.withLock { callback = target }
            completionHandler(nil)
        } else {
            completionHandler(request)
        }
    }

    func takeCallback() -> URL? {
        lock.withLock {
            defer { callback = nil }
            return callback
        }
    }
}
