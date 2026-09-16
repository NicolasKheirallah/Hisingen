import Foundation
import OSLog


actor VolvoAPI {
    private enum TokenRequestFailure: Error {
        case deadRefreshToken
    }
    nonisolated let brand: VehicleBrand = .volvo
    let logger = AppLog.logger("volvo-api")


    private let identityHost = URL(string: "https://volvoid.eu.volvocars.com")!
    let authorizationPath = "/as/authorization.oauth2"
    private let tokenPath = "/as/token.oauth2"
    private let apiBaseURL = URL(string: "https://api.volvocars.com")!


    let redirectURI = URL(string: "https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html")!


    /// Pure telemetry reads plus what vehicle discovery needs. Every published Volvo
    /// application is granted these automatically, so this is the guaranteed-safe floor a
    /// scope cascade falls back to.
    static let coreReadScopes = [
        "openid",
        "conve:battery_charge_level", "conve:brake_status", "conve:diagnostics_engine_status",
        "conve:diagnostics_workshop", "conve:doors_status", "conve:engine_status",
        "conve:fuel_status", "conve:lock_status", "conve:odometer_status",
        "conve:trip_statistics", "conve:tyre_status", "conve:vehicle_relation",
        "conve:warnings", "conve:windows_status", "energy:capability:read", "energy:state:read"
    ]

    /// Command-adjacent scopes: listing/checking commands and remote climate. Standard for a
    /// published app, but a re-approval lapse on the application makes the identity provider
    /// reject the whole authorization with `invalid_scope`, so the cascade can drop these
    /// while keeping telemetry.
    static let commandReadScopes = [
        "conve:commands", "conve:command_accessibility", "conve:climatization_start_stop"
    ]

    static let readScopes = coreReadScopes + commandReadScopes

    /// Volvo gates these behind per-application approval. Settings exposes an explicit opt-in;
    /// only then does the next OAuth sign-in request them, so an unapproved application does
    /// not break an otherwise valid read-only authorization.
    static let restrictedScopes = [
        "conve:lock", "conve:unlock", "conve:engine_start_stop", "conve:honk_flash",
        "location:read"
    ]

    /// Ordered widest → narrowest for the `invalid_scope` fallback cascade.
    enum ScopeTier: Int, CaseIterable {
        case full       // readScopes + restrictedScopes (when the preference wants them)
        case standard   // readScopes only – telemetry + remote climate, no lock/unlock/locate
        case core       // coreReadScopes only – telemetry, no remote controls at all
    }


    var clientID: String?
    var clientSecret: String?
    var vccApiKey: String?


    var session: URLSession
    /// The session token lifecycle: renewal margin, the grant cooldown that collapses the
    /// telemetry fan-out into one grant, single-flight, rotate-on-use persistence, and
    /// dead-grant classification. It stays private because it is confined to this actor:
    /// `accessToken` stays readable because the telemetry extensions read it directly, and
    /// `refreshToken` stays writable because `restoreSession` seeds it from the Keychain before
    /// forcing a grant.
    private let tokens: TokenLifecycle
    var accessToken: String? { tokens.accessToken }
    var refreshToken: String? {
        get { tokens.refreshToken }
        set { tokens.refreshToken = newValue }
    }
    /// PKCE sign-in flow state. The flow validates the redirect callback against the pending
    /// values before consuming them, so a stray or forged callback cannot kill the genuine
    /// sign-in; `invalid_scope` stays retryable at a narrower scope tier.
    var authorizationFlow = AuthorizationFlow<VolvoError>(
        rejected: .authenticationRequired(.callbackRejected),
        oauthError: { code, description in
            VolvoError.permissionDenied(
                operation: code == "invalid_scope" ? "invalid_scope" : (description ?? code))
        }
    )
    let keychain: KeychainStore
    let imageCache: CarImageCache
    let preferences: PreferencesStore

    var cars: [CarSummary] = []
    var selectedVIN: String?
    /// Bumped by `resetSession()`; long-running discovery captures it on entry and discards
    /// results if a reset interleaved (same rationale as the Polestar epoch guard).
    var sessionEpoch = 0
    var vehicleDetailsCache: [String: VolvoVehicleDetailsDTO] = [:]
    var capabilityCache: [String: (value: VolvoEnergyCapabilitiesDTO, expiresAt: Date)] = [:]
    var optionalTelemetryCache: [String: CapabilityCacheEntry] = [:]
    /// Where the durable per-endpoint stand-downs live: one owner for both providers, so an
    /// erase reaches them and a test can inject one over an in-memory database.
    let backoffs: ProviderBackoffStore
    var remoteCommandsInFlight: Set<String> = []
    var carImageData: [String: Data] = [:]
    var interiorImageData: [String: Data] = [:]

    /// Volvo caps the invocation/command endpoints at 10 requests/minute per Volvo ID + client.
    /// `dispatchCommand` spaces its POSTs at least this far apart so a burst of taps waits
    /// locally instead of drawing an HTTP 429, which Volvo can escalate to a longer lockout.
    static let minCommandInterval: TimeInterval = 6
    var nextCommandDispatchAt: Date?

    @MainActor
    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache()) {
        self.init(keychain: keychain, imageCache: imageCache, preferences: .shared)
    }

    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore, backoffs: ProviderBackoffStore = ProviderBackoffStore()) {
        self.keychain = keychain
        self.imageCache = imageCache
        self.preferences = preferences
        self.backoffs = backoffs
        self.tokens = TokenLifecycle(
            policy: .init(renewalMargin: Self.tokenRenewalMargin(lifetime:),
                          minimumRegrantInterval: 10),
            providerName: "Volvo",
            logger: AppLog.logger("volvo-api"),
            persist: { try keychain.saveVolvoSessionToken($0) },
            isDeadGrant: { error in
                if case TokenRequestFailure.deadRefreshToken = error { return true }
                return false
            }
        )
        session = Self.makeSession()
    }


    /// Volvo's client credentials are not part of the shared interface, so assembling them is
    /// this adapter's own business: a caller restores a session the same way for either brand.
    func prepareSession() async throws {
        // `PreferencesStore` is MainActor-backed; this adapter is not.
        let configuredClientID = await MainActor.run { preferences.volvoClientID }
        let clientID = configuredClientID.isEmpty ? BuiltinVolvoSecrets.clientID : configuredClientID
        let secret = (try Keychain.readVolvoClientSecret()) ?? BuiltinVolvoSecrets.clientSecret
        let apiKey = (try Keychain.readVolvoApiKey()) ?? BuiltinVolvoSecrets.vccApiKey
        guard !clientID.isEmpty, !secret.isEmpty, !apiKey.isEmpty else {
            throw VehicleServiceError.authenticationRequired(provider: .volvo, reason: .noStoredSession)
        }
        configure(clientID: clientID, clientSecret: secret, vccApiKey: apiKey)
    }

    func configure(clientID: String, clientSecret: String, vccApiKey: String) {
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        self.vccApiKey = vccApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !(clientID?.isEmpty ?? true) && !(clientSecret?.isEmpty ?? true) && !(vccApiKey?.isEmpty ?? true)
    }
















    func dispatchCommand(_ command: RemoteCommand, vin: String, accessToken: String) async throws -> RemoteCommandResult {
        let commandName: String
        var bodyData = "{}".data(using: .utf8)
        switch command {
        case .lock: commandName = "lock"
        case .lockReducedGuard: commandName = "lock-reduced-guard"
        case .unlock: commandName = "unlock"
        case .startClimate: commandName = "climatization-start"
        case .stopClimate: commandName = "climatization-stop"
        case .startEngine(let runtimeMinutes):
            commandName = "engine-start"
            bodyData = "{\"runtimeMinutes\": \(max(1, min(15, runtimeMinutes)))}".data(using: .utf8)
        case .stopEngine:
            commandName = "engine-stop"
        // The command list reports this as `HONK_AND_FLASH` but its `href` – and therefore the
        // real invocation path – is `honk-flash` (verified live against a production vehicle).
        case .honkAndFlash: commandName = "honk-flash"
        case .flashLights: commandName = "flash"
        case .honkHorn: commandName = "honk"
        default:
            throw RemoteCommandError.unsupported
        }
        guard let vccApiKey else { throw VolvoError.appNotConfigured }

        try await throttleCommandDispatch()

        var request = URLRequest(url: try apiURL(
            path: "/connected-vehicle/v2/vehicles/\(vin)/commands/\(commandName)"
        ))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        let (data, response) = try await perform(request, operation: "command: \(commandName)")
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: commandName) {
            if let detail = try? JSONDecoder.volvo.decode(VolvoCommandErrorDTO.self, from: data),
               let text = detail.text {
                // Only a genuine 403 becomes permissionDenied. Letting the body's detail text
                // replace the typed failure reclassified a 401 (needs re-authentication) and
                // a 429 (rate limit, Retry-After) as account-permission problems.
                if case .permissionDenied = failure {
                    throw VolvoError.permissionDenied(operation: "\(commandName) (\(text))")
                }
                logger.error("""
                    Volvo command \(commandName, privacy: .public) failed \
                    (HTTP \(response.statusCode, privacy: .public)): \(text, privacy: .public)
                    """)
            }
            throw failure
        }
        guard let envelope = try? JSONDecoder.volvo.decode(
            VolvoEnvelope<VolvoCommandResponseDTO>.self, from: data
        ), let payload = envelope.data else {
            throw VolvoError.decoding(operation: "command: \(commandName)")
        }
        if let failureReason = payload.failureReason {
            throw RemoteCommandError.rejected(payload.text.map { "\(failureReason) (\($0))" } ?? failureReason)
        }
        if payload.readyToUnlock == true {
            let message = payload.readyToUnlockUntil.map {
                L10n.format("Vehicle is ready to unlock for %d seconds. Open a door or the trunk to complete unlocking.", $0)
            } ?? L10n.text("Vehicle is ready to unlock. Open a door or the trunk to complete unlocking.")
            return RemoteCommandResult(
                outcome: .delivered,
                message: message
            )
        }
        if let outcome = payload.outcome {
            return RemoteCommandResult(outcome: outcome, message: payload.text)
        }
        // Connected Vehicle API v2 commands are synchronous and Volvo removed the old sent-
        // command status endpoints. Never poll /commands/{id}; it is not part of v2.
        return RemoteCommandResult(outcome: .accepted, message: payload.text)
    }

    /// Serialises command POSTs to at most one per `minCommandInterval`. Concurrent callers
    /// chain: each reserves the next slot and sleeps until it, so a rapid lock→unlock still
    /// stays inside Volvo's 10 requests/minute command-endpoint quota.
    private func throttleCommandDispatch() async throws {
        let now = Date()
        let earliest = max(now, nextCommandDispatchAt ?? .distantPast)
        nextCommandDispatchAt = earliest.addingTimeInterval(Self.minCommandInterval)
        let wait = earliest.timeIntervalSince(now)
        guard wait > 0 else { return }
        logger.info("Delaying Volvo command \(String(format: "%.1f", wait), privacy: .public)s to respect the 10/min command limit")
        try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
    }

    /// The path embeds server-supplied data (the VIN), so a malformed value must fail the
    /// request instead of trapping at a force-unwrap.
    private func apiURL(path: String) throws -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: clean, relativeTo: apiBaseURL) else {
            throw VolvoError.invalidResponse(operation: path)
        }
        return url.absoluteURL
    }

    func identityURL(path: String) throws -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: clean, relativeTo: identityHost) else {
            throw VolvoError.invalidResponse(operation: path)
        }
        return url.absoluteURL
    }

    func discoverVehicles(preferredVIN: String?) async throws {
        let requestEpoch = sessionEpoch
        let savedVIN: String? = if let preferredVIN, !preferredVIN.isEmpty {
            preferredVIN
        } else {
            await MainActor.run { preferences.vin(for: .volvo) }
        }
        do {
            let list: [VolvoVehicleSummaryDTO] = try await getList("/connected-vehicle/v2/vehicles")
            var summaries: [CarSummary] = []
            for entry in list {
                let details = try? await vehicleDetails(vin: entry.vin)
                let model = details?.descriptions?.model
                let year = details?.modelYear.map(String.init)
                let title = [model, year]
                    .compactMap { $0 }.joined(separator: " · ")
                summaries.append(CarSummary(
                    vin: entry.vin,
                    title: title.isEmpty ? entry.vin : title,
                    modelName: model,
                    modelYear: year,
                    registrationNo: nil
                ))
            }
            if summaries.isEmpty, let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                summaries.append(CarSummary(vin: vin, title: nickname.isEmpty ? "Volvo" : nickname))
            }
            guard sessionEpoch == requestEpoch else { return }
            cars = summaries
            let selected = (savedVIN != nil) ? (cars.first(where: { $0.vin == savedVIN }) ?? cars.first) : cars.first
            selectedVIN = selected?.vin
        } catch {
            // Only provider-specific gaps may degrade to the saved-VIN fallback list.
            // Swallowing an auth failure or an outage here fabricated a one-car garage
            // titled "Volvo" and hid the real problem behind plausible-looking data.
            // Error descriptions can embed request paths (which contain VINs), so they are
            // logged private rather than public.
            logger.warning("Volvo vehicle discovery degraded to stored VIN: \(String(describing: error), privacy: .private)")
            if Self.isRequestLevelFailure(error) { throw error }
            if let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                guard sessionEpoch == requestEpoch else { return }
                cars = [CarSummary(vin: vin, title: nickname.isEmpty ? "Volvo" : nickname)]
                selectedVIN = vin
            } else {
                cars = []
                selectedVIN = nil
            }
        }
    }

    func vehicleDetails(vin: String) async throws -> VolvoVehicleDetailsDTO {
        if let cached = vehicleDetailsCache[vin] { return cached }
        let details: VolvoVehicleDetailsDTO = try await get("/connected-vehicle/v2/vehicles/\(vin)")
        vehicleDetailsCache[vin] = details
        return details
    }

    func exchangeCodeForToken(_ code: String, verifier: String) async throws {
        let epoch = sessionEpoch
        guard let clientID, let clientSecret else { throw VolvoError.appNotConfigured }
        var request = URLRequest(url: try identityURL(path: tokenPath))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        Self.applyBasicAuth(&request, clientID: clientID, clientSecret: clientSecret)
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier
        ])
        let token = try await requestToken(request)
        // A sign-out or restarted sign-in during the exchange must not repopulate the tokens
        // it just cleared (same guard as the Polestar grant paths).
        guard epoch == sessionEpoch else { throw CancellationError() }
        try tokens.adopt(TokenLifecycle.Grant(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresIn: TimeInterval(token.expiresIn)))
    }

    /// The most recent successful grant is the freshest token obtainable, so a caller arriving
    /// within a few seconds of one reuses it instead of starting another – this collapses the
    /// ~20-endpoint telemetry fan-out (and a wave of requests that all `401` at once) from
    /// several `refresh_token` grants down to one. The lifecycle enforces it as the policy's
    /// minimum regrant interval.
    static func tokenRenewalMargin(lifetime: TimeInterval) -> TimeInterval {
        // Scale to a short-lived token instead of a flat five minutes that would treat it as
        // perpetually stale, while never discarding most of a long-lived one.
        lifetime > 0 ? min(300, lifetime / 2) : 300
    }

    /// Whether `epoch` still names the live session. Consulted after every suspension so a grant
    /// that lands after a reset cannot be applied to the session that replaced it.
    func isSessionCurrent(_ epoch: Int) -> Bool { epoch == sessionEpoch }

    /// Cancels an in-flight grant without touching the session: a new authorization is about to
    /// replace it, and its rotated token must not land afterwards.
    func cancelInFlightTokenGrant() { tokens.cancelInFlightGrant() }

    /// Clears the in-memory session and any in-flight grant. The persisted token is untouched –
    /// only `signOut` and a dead grant delete that.
    func resetTokenLifecycle() { tokens.reset() }

    func refreshTokenIfNeeded() async throws {
        try await refreshAccessToken(force: false)
    }

    func refreshAccessToken(force: Bool) async throws {
        let requestEpoch = sessionEpoch
        // Volvo's request path does not carry the refused token back, so a forced call cannot be
        // matched against the session's; the lifecycle's grant cooldown is what bounds a burst.
        let reason: TokenLifecycle.Reason = force
            ? .serverRefused(rejectedToken: nil)
            : .renewalWindow
        // Captured before the closure runs so the grant does not read state the lifecycle owns;
        // the configuration guard lives inside it, where a grant already in flight is awaited
        // rather than failed. The lifecycle decides whether a grant is needed at all.
        let configuration = (clientID: clientID, secret: clientSecret, refresh: refreshToken)
        let outcome = try await tokens.refresh(
            reason,
            epochIsCurrent: { await self.isSessionCurrent(requestEpoch) },
            grant: {
                guard let clientID = configuration.clientID,
                      let clientSecret = configuration.secret,
                      let refreshToken = configuration.refresh, !refreshToken.isEmpty else {
                    throw VolvoError.authenticationRequired(.noStoredSession)
                }
                let path = self.tokenPath
                let url = try await self.identityURL(path: path)
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                Self.applyBasicAuth(&request, clientID: clientID, clientSecret: clientSecret)
                request.httpBody = Self.formBody([
                    "grant_type": "refresh_token", "refresh_token": refreshToken
                ])
                let token = try await self.requestToken(request)
                return TokenLifecycle.Grant(accessToken: token.accessToken,
                                            refreshToken: token.refreshToken,
                                            expiresIn: TimeInterval(token.expiresIn))
            }
        )
        if outcome == .deadGrant {
            await discardDeadRefreshToken()
            throw VolvoError.authenticationRequired(.invalidCredentials)
        }
    }

    /// Wipes the stored Volvo session – memory and Keychain – after the identity provider has
    /// declared the refresh token permanently dead (`invalid_grant` / `expired_token`). Without
    /// this, `hasResumableSession` stays `true` and the resume / garage-scan loop replays the
    /// dead token every few minutes; each replay is a failed login that counts toward Volvo's
    /// per-client lockout. Deliberately *not* triggered by a bare 401, `invalid_client`, or a
    /// network error – those can be transient or misconfiguration, and destroying a still-valid
    /// credential there is the failure mode `MultiCarFleetSwitchingTests` guards against.
    private func discardDeadRefreshToken() async {
        tokens.reset()
        try? keychain.deleteVolvoSessionToken()
        await MainActor.run { preferences.invalidateSessionCache() }
    }

    private func requestToken(_ request: URLRequest) async throws -> VolvoTokenResponseDTO {
        let isRefreshGrant = (request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? "")
            .contains("grant_type=refresh_token")
        let (data, response) = try await perform(request, operation: "Volvo token request",
                                                 semanticError: { data, _ in Self.oauthErrorCode(in: data) })
        if response.statusCode == 400 || response.statusCode == 401 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let err = json["error"] as? String ?? "auth_error"
                let desc = json["error_description"] as? String ?? ""
                logger.error("Volvo token request rejected: \(err, privacy: .public) - \(desc, privacy: .private)")
                // A 400 is not always bad credentials: `invalid_client` means the app's own
                // credentials are wrong, while anything else at 401 genuinely is a session
                // problem. Previously every 4xx here reported "invalid credentials", sending
                // users to re-enter a password that was never the issue.
                switch err {
                case "invalid_client", "unauthorized_client":
                    throw VolvoError.appNotConfigured
                case "invalid_grant", "expired_token":
                    if isRefreshGrant { throw TokenRequestFailure.deadRefreshToken }
                    throw VolvoError.authenticationRequired(.invalidCredentials)
                default:
                    throw response.statusCode == 401
                        ? VolvoError.authenticationRequired(.invalidCredentials)
                        : VolvoError.server(statusCode: response.statusCode)
                }
            }
            throw response.statusCode == 401
                ? VolvoError.authenticationRequired(.invalidCredentials)
                : VolvoError.server(statusCode: response.statusCode)
        }
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: "token request") {
            throw failure
        }
        guard let decoded = try? JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: data),
              decoded.expiresIn > 0 else {
            throw VolvoError.decoding(operation: "token response")
        }
        return decoded
    }

    private func authenticatedGET(_ path: String) async throws -> (Data, HTTPURLResponse) {
        try await refreshTokenIfNeeded()
        guard var token = accessToken, let vccApiKey else {
            throw VolvoError.authenticationRequired(.expiredSession)
        }
        for attempt in 0...1 {
            var request = URLRequest(url: try apiURL(path: path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
            request.setValue("Hisingen/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await perform(request, operation: path)
            if response.statusCode == 401 {
                let bodyString = String(data: data, encoding: .utf8) ?? ""
                if bodyString.localizedCaseInsensitiveContains("VCC-API-KEY") || bodyString.localizedCaseInsensitiveContains("API-KEY") {
                    throw VolvoError.appNotConfigured
                }
                if attempt == 0 {
                    try await refreshAccessToken(force: true)
                    guard let refreshed = accessToken else {
                        throw VolvoError.authenticationRequired(.expiredSession)
                    }
                    token = refreshed
                    continue
                }
            }
            return (data, response)
        }
        throw VolvoError.authenticationRequired(.expiredSession)
    }

    func get<T: Decodable & Sendable>(_ path: String) async throws -> T {
        let (data, response) = try await authenticatedGET(path)
        if response.statusCode == 403 {
            // Only per-vehicle telemetry GETs route through this helper, and for those a 403
            // is empirically a market/model gate rather than a token problem: the same token
            // keeps working on sibling endpoints. Vehicle discovery and command dispatch do
            // not use this path, so their 403s stay `.permissionDenied` – the asymmetry is
            // deliberate. This is tuned from observed behaviour, not Volvo documentation.
            if path.hasPrefix("/location/") {
                throw VolvoError.regionRestricted(service: path)
            }
            throw VolvoError.permissionDenied(operation: path)
        }
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: path) { throw failure }
        let envelope = try? JSONDecoder.volvo.decode(VolvoEnvelope<T>.self, from: data)
        if let value = envelope?.data { return value }
        guard let direct = try? JSONDecoder.volvo.decode(T.self, from: data) else {
            // Keep the underlying decode error in the (private) log: `DecodingError` names
            // the exact missing/mismatched key, which is the difference between a five-minute
            // diagnosis and a guessing game when Volvo changes a payload shape.
            logger.error("Volvo response for \(DiagnosticRedaction.redact(path), privacy: .public) matched neither envelope nor direct decoding")
            throw VolvoError.decoding(operation: path)
        }
        return direct
    }

    func getList<T: Decodable & Sendable>(_ path: String) async throws -> [T] {
        let (data, response) = try await authenticatedGET(path)
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: path) { throw failure }
        if let envelope = try? JSONDecoder.volvo.decode(VolvoEnvelope<[T]>.self, from: data), let list = envelope.data {
            return list
        }
        guard let direct = try? JSONDecoder.volvo.decode([T].self, from: data) else {
            throw VolvoError.decoding(operation: path)
        }
        return direct
    }


    /// One optional telemetry endpoint for one vehicle. Volvo's market-restricted and not-exposed
    /// responses are per vehicle, so the vehicle travels with the subject; the identifier is
    /// Volvo's own, which is what keeps the shared store free of brand knowledge.
    static func endpointBackoffSubject(_ key: String, vin: String) -> ProviderBackoffStore.Subject {
        ProviderBackoffStore.Subject("volvo.endpoint.\(key)", vin: vin)
    }

    func optional<Value: Sendable>(
        enabled: Bool, key: String, vin: String, operation: @Sendable () async throws -> Value
    ) async throws -> Value? {
        guard enabled else { return nil }
        let backoffKey = "\(vin)|\(key)"
        let subject = Self.endpointBackoffSubject(key, vin: vin)
        if let until = backoffs.blockedUntil(subject), until > Date() { return nil }
        if let cached = optionalTelemetryCache[backoffKey], cached.expiresAt > Date(),
           let value = cached.value as? Value { return value }
        do {
            let value = try await operation()
            let ttl = Self.optionalTelemetryTTL(for: key)
            if ttl > 0 {
                optionalTelemetryCache[backoffKey] = CapabilityCacheEntry(
                    value: value, expiresAt: Date().addingTimeInterval(ttl))
            }
            backoffs.unblock(subject)
            return value
        } catch {
            if Self.isGlobalFailure(error) { throw error }
            let isRestricted: Bool
            switch error as? VolvoError {
            case .regionRestricted, .permissionDenied: isRestricted = true
            // A 404 is stable: the resource is simply not exposed for this vehicle/market
            // (e.g. `/environment` on a model without the sensor). Back off long and persist
            // it so it is not re-probed every few minutes for the life of the install.
            case .client(let statusCode) where statusCode == 404: isRestricted = true
            default: isRestricted = false
            }
            // Both durations are durable now that the owner is one store: the 5-minute ones
            // expire long before a relaunch can read them back, so the split the defaults
            // dictionary kept – restricted entries persisted, transient ones process-local – was
            // a distinction the retention rule already made for it.
            let duration: TimeInterval = isRestricted ? 3600 : (5 * 60)
            backoffs.block(subject, until: Date().addingTimeInterval(duration), reason: nil)
            if isRestricted {
                logger.info("Optional Volvo endpoint restricted: \(key, privacy: .public)")
            } else {
                logger.warning("Optional Volvo endpoint unavailable: \(key, privacy: .public) – \(String(describing: error), privacy: .public)")
            }
            return nil
        }
    }

    /// Provider timestamps show that these categories change on very different timescales.
    /// Poll fast operational state normally while avoiding hourly re-downloads of multi-day
    /// diagnostics and static capability lists.
    static func optionalTelemetryTTL(for key: String) -> TimeInterval {
        switch key {
        case "commands":
            return 60 * 60
        case "odometer", "statistics", "fuel", "location", "brakes":
            return 15 * 60
        case "tyres", "diagnostics", "engine-diagnostics", "warnings",
             "command-accessibility":
            return 5 * 60
        default:
            return 0
        }
    }


    private static func isGlobalFailure(_ error: Error) -> Bool {
        guard let error = error as? VolvoError else { return false }
        switch error {
        case .authenticationRequired, .appNotConfigured, .rateLimited: return true
        default: return false
        }
    }

    /// Request-level failures that must propagate instead of degrading to fallback data –
    /// auth problems, rate limiting, server outages, transport breakdowns.
    static func isRequestLevelFailure(_ error: Error) -> Bool {
        switch error as? VolvoError {
        case .authenticationRequired, .appNotConfigured, .rateLimited, .server,
             .network, .invalidResponse, .responseTooLarge:
            return true
        default:
            return false
        }
    }


    private static func applyBasicAuth(_ request: inout URLRequest, clientID: String, clientSecret: String) {
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }
}

extension JSONDecoder {
    static let volvo: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
