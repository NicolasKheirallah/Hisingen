import AppKit
import Foundation
import OSLog

struct OptionalCapability<Value: Sendable>: Sendable {
    let value: Value?
    let unavailable: Bool
}

struct CapabilityCacheEntry {
    let value: (any Sendable)?
    let expiresAt: Date
}

actor PolestarAPI {
    nonisolated let brand: VehicleBrand = .polestar
    let logger = AppLog.logger("polestar-api")

    private let apiBaseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!
    private let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
    private let appBackendURL = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!


    private var publicApiKey: String { BuiltinPolestarSecrets.imageApiKey }
    private let oidcProviderURL = URL(string: "https://polestarid.eu.polestar.com")!

    // The polestar.com web client. The mobile-app client (`lp8dyrd_10`,
    // `polestar-explore://explore.polestar.com`) authenticates fine but its token is rejected
    // by `pc-api.polestar.com/mystar-v2` with `UnauthorizedException`, so vehicle discovery
    // returns nothing and the app has no car to talk about — verified live against a real
    // account. The `getConsumerCarsV2` query only accepts this client.
    let oidcClientID = "l3oopkc_10"
    let oidcRedirectURL = URL(string: "https://www.polestar.com/sign-in-callback")!
    // `customer:attributes:write` is what the C3 `ota_mobcache.SchedulerService` write RPCs
    // require. This client grants it on request — adding it does not disturb discovery.
    let oidcScope = "openid profile email customer:attributes customer:attributes:write"

    // Remote commands are gated on a *client-id allowlist*, separate from scope. C3 spells the
    // rule out when it refuses: `Client id l3oopkc_10 is not a required client id: [… lp8dyrd_10 …]`.
    // The web client above can list vehicles but cannot invoke; this one can invoke but is
    // rejected by `mystar-v2` for reads. Neither is sufficient alone, so the app holds a token
    // from each and picks per call. Verified live: `Lock` via C3 with this client returns
    // `outcome = accepted`.
    let commandClientID = "lp8dyrd_10"
    let commandRedirectURL = URL(string: "polestar-explore://explore.polestar.com")!

    var commandAccessToken: String?
    var commandRefreshToken: String?
    var commandTokenExpiry: Date?
    var commandPendingVerifier: String?
    var commandPendingState: String?
    /// Single-flight guard for the command client's refresh grant (see `validCommandToken`).
    var commandRefreshTask: Task<String?, Never>?

    var session: URLSession
    var redirectDelegate: OAuthRedirectDelegate
    let grpc = PolestarGRPC()
    let keychain: KeychainStore
    let imageCache: CarImageCache

    var accessToken: String?
    var refreshToken: String?
    var tokenExpiry: Date?
    var refreshTask: Task<TokenResponseDTO, Error>?

    var tokenEndpoint: URL?
    var authorizationEndpoint: URL?
    var userinfoEndpoint: URL?
    var revocationEndpoint: URL?

    private(set) var cars: [CarSummary] = []
    var selectedVIN: String?
    var internalVehicleIdentifier: String?
    var modelName: String?
    var modelYear: String?
    var registrationNo: String?
    var pno34: String?
    var structureWeek: String?
    var exteriorColorName: String?
    var upholsteryName: String?
    var wheelsName: String?
    var packageNames: [String] = []
    var ownerFirstName: String?
    var market: String?
    var carImageData: Data?
    var targetCache: [String: (value: Int?, fetchedAt: Date)] = [:]
    var capabilityBackoff: [String: [String: Date]] = [:]
    var capabilityCache: [String: CapabilityCacheEntry] = [:]
    var remoteCommandsInFlight: Set<String> = []
    private var imageDownloadTasks: [String: Task<Void, Never>] = [:]
    /// Bumped whenever account state is cleared/reset. Multi-step operations capture it on
    /// entry and drop their results if a reset interleaved — the actor serializes individual
    /// writes but not whole logical transactions (e.g. a slow discovery from a superseded
    /// login could otherwise repopulate `cars` after sign-out cleared them).
    private var sessionEpoch = 0
    let preferences: PreferencesStore

    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache(), preferences: PreferencesStore = PreferencesStore()) {
        self.keychain = keychain
        self.imageCache = imageCache
        self.preferences = preferences
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
    }

    private struct OIDCDiscovery: Decodable {
        let issuer: String
        let tokenEndpoint: String
        let authorizationEndpoint: String
        let userinfoEndpoint: String?
        let revocationEndpoint: String?

        private enum CodingKeys: String, CodingKey {
            case issuer
            case tokenEndpoint = "token_endpoint"
            case authorizationEndpoint = "authorization_endpoint"
            case userinfoEndpoint = "userinfo_endpoint"
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    func discoverOIDCConfiguration() async throws {
        let url = oidcProviderURL.appendingPathComponent(".well-known/openid-configuration")
        let (data, response) = try await perform(URLRequest(url: url))
        try validateHTTP(response)
        guard let discovery = try? JSONDecoder().decode(OIDCDiscovery.self, from: data),
              let issuer = URL(string: discovery.issuer),
              issuer.scheme == oidcProviderURL.scheme,
              issuer.host == oidcProviderURL.host,
              issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                == oidcProviderURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let token = Self.validPolestarURL(discovery.tokenEndpoint),
              let authorization = Self.validPolestarURL(discovery.authorizationEndpoint) else {
            throw PolestarError.incompatibleAPI(operation: "OIDC discovery")
        }
        tokenEndpoint = token
        authorizationEndpoint = authorization
        userinfoEndpoint = discovery.userinfoEndpoint.flatMap(Self.validPolestarURL)
        revocationEndpoint = discovery.revocationEndpoint.flatMap(Self.validPolestarURL)
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
        let queryItems = Self.authorizationQueryItems(
            clientID: clientID ?? oidcClientID,
            redirectURI: (redirectURI ?? oidcRedirectURL).absoluteString,
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
                                              callbackURL: redirectURI ?? oidcRedirectURL) {
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
            callbackURL: redirectURI ?? oidcRedirectURL
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
        if html.contains("ERR001") {
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

    /// Builds the command client's authorization URL for a real browser to open — the
    /// `polestar-explore://` redirect is the command client's own registered custom scheme, so
    /// unlike the web client (whose redirect lands on `polestar.com`, a domain Hisingen doesn't
    /// control), the OS can route the final redirect straight back into the app. Used by
    /// `PolestarCommandSignInPresenter` instead of the scripted PingFederate form-fill used for
    /// the web client's own sign-in — Hisingen never sees the password for this flow.
    func beginCommandAuthorization() async throws -> URL {
        if authorizationEndpoint == nil { try await discoverOIDCConfiguration() }
        guard let authorizationEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        let verifier = try Self.randomURLSafeString()
        let state = try Self.randomURLSafeString()
        commandPendingVerifier = verifier
        commandPendingState = state
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
        return url
    }

    /// Completes command-client authorization from the `polestar-explore://` callback the OS
    /// handed back after the user signed in through their real browser.
    func completeCommandAuthorization(callbackURL: URL) async throws {
        guard let verifier = commandPendingVerifier, let expectedState = commandPendingState else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        commandPendingVerifier = nil
        commandPendingState = nil
        guard callbackURL.scheme == commandRedirectURL.scheme,
              callbackURL.host == commandRedirectURL.host else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        if let error = Self.queryValue("error", from: callbackURL) {
            throw PolestarError.permissionDenied(operation: error)
        }
        guard Self.queryValue("state", from: callbackURL) == expectedState,
              let code = Self.queryValue("code", from: callbackURL) else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        let token = try await exchangeCode(code, verifier: verifier,
                                           clientID: commandClientID, redirectURI: commandRedirectURL)
        commandAccessToken = token.accessToken
        commandRefreshToken = token.refreshToken
        commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
        if let refresh = token.refreshToken { try? keychain.saveCommandSessionToken(refresh) }
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
                                           invalidReason: .callbackRejected)
    }

    func exchangeCodeForToken(_ code: String, verifier: String) async throws {
        let token = try await exchangeCode(code, verifier: verifier,
                                           clientID: oidcClientID, redirectURI: oidcRedirectURL)
        try apply(token)
    }

    func refreshTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        if expiry.timeIntervalSinceNow < 300 { try await refreshAccessToken(force: false) }
    }

    func refreshAccessToken(force: Bool) async throws {
        if !force, let expiry = tokenExpiry, expiry.timeIntervalSinceNow >= 300 { return }
        if let refreshTask {
            try apply(try await refreshTask.value)
            return
        }
        guard let tokenEndpoint, let refreshToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "refresh_token",
            "client_id": oidcClientID,
            "refresh_token": refreshToken
        ])
        let tokenRequest = request
        let currentSession = session
        let task = Task {
            try await Self.requestToken(request: tokenRequest, session: currentSession,
                                        invalidReason: .expiredSession)
        }
        refreshTask = task
        defer { refreshTask = nil }
        try apply(try await task.value)
    }

    private func apply(_ token: TokenResponseDTO) throws {
        let previousRefreshToken = refreshToken
        let renewableToken = token.refreshToken ?? refreshToken
        if let renewableToken, renewableToken != previousRefreshToken {
            try keychain.saveSessionToken(renewableToken)
        }
        accessToken = token.accessToken
        refreshToken = renewableToken
        tokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
    }

    static func requestToken(request: URLRequest, session: URLSession,
                                     invalidReason: AuthFailureReason) async throws -> TokenResponseDTO {
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: 256_000, operation: "token response", provider: .polestar
            )
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "token response")
            }
            if http.statusCode == 400 {
                throw PolestarError.authenticationRequired(invalidReason)
            }
            if let failure = PolestarError.httpFailure(
                statusCode: http.statusCode,
                retryAfter: retryAfter(from: http),
                authenticationReason: invalidReason,
                forbiddenIsAuthentication: true,
                operation: "token request"
            ) {
                throw failure
            }
            guard let token = try? JSONDecoder().decode(TokenResponseDTO.self, from: data),
                  token.expiresIn > 0 else {
                throw PolestarError.decoding(operation: "token response")
            }
            return token
        } catch let error as URLError {
            throw PolestarError.network(error)
        }
    }


    func graphQL<Payload: Decodable>(query: String, variables: [String: Any]?,
                                             token: String, operation: String) async throws
        -> GraphQLResponse<Payload> {
        var body: [String: Any] = ["query": query]
        if let variables { body["variables"] = variables }
        var request = URLRequest(url: apiBaseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("Hisingen/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var bearerToken = token
        for attempt in 0...1 {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await perform(request, operation: operation)
            if response.statusCode == 401 || response.statusCode == 403 {
                if attempt == 0 {
                    try await refreshAccessToken(force: true)
                    guard let newToken = accessToken else {
                        throw PolestarError.authenticationRequired(.expiredSession)
                    }
                    bearerToken = newToken
                    continue
                }
                logger.error("""
                    Polestar \(operation, privacy: .public) rejected after token refresh \
                    (HTTP \(response.statusCode, privacy: .public))
                    """)
                if response.statusCode == 401 {
                    throw PolestarError.authenticationRequired(.expiredSession)
                }
                throw PolestarError.permissionDenied(operation: operation)
            }
            try validateHTTP(response, operation: operation)
            guard let decoded = try? JSONDecoder().decode(GraphQLResponse<Payload>.self, from: data) else {
                throw PolestarError.decoding(operation: operation)
            }
            if decoded.data == nil, let errors = decoded.errors,
               Self.containsAuthenticationError(errors) {
                if attempt == 0 {
                    try await refreshAccessToken(force: true)
                    guard let newToken = accessToken else {
                        throw PolestarError.authenticationRequired(.expiredSession)
                    }
                    bearerToken = newToken
                    continue
                }
                // Server-supplied GraphQL messages are scrubbed before public logging —
                // they have been known to echo account details on auth failures.
                let authSummary = DiagnosticRedaction.redact(Self.errorSummary(errors))
                logger.error("""
                    Polestar \(operation, privacy: .public) returned an authentication error after \
                    token refresh: \(authSummary, privacy: .public)
                    """)
                throw PolestarError.authenticationRequired(.expiredSession)
            }
            if decoded.data == nil, let errors = decoded.errors, !errors.isEmpty {
                let summary = DiagnosticRedaction.redact(Self.errorSummary(errors))
                logger.error("""
                    Polestar \(operation, privacy: .public) failed: \
                    \(summary, privacy: .public)
                    """)
                throw PolestarError.graphQL(Self.mapErrors(errors), hasPartialData: false)
            }
            return decoded
        }
        throw PolestarError.authenticationRequired(.expiredSession)
    }

    func fetchCarInfo(preferredVIN: String?) async throws {
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let requestEpoch = sessionEpoch
        let query = """
        query GetConsumerCarsV2 {
          getConsumerCarsV2 { vin internalVehicleIdentifier modelName modelYear registrationNo pno34 structureWeek }
        }
        """
        var accountCars: [ConsumerCarDTO] = []
        var legacyCars: [ConsumerCarDTO] = []
        // A failure here is only degradable when it is specific to this data source. Auth,
        // rate-limit, server, and transport failures must propagate — previously a swallowed
        // 401 or 429 fell through to the manual-VIN branch and surfaced as
        // `.notConfigured` ("Open Settings to sign in"), masking the real problem.
        do {
            let response: GraphQLResponse<ConsumerCarsPayloadDTO> = try await graphQL(
                query: query, variables: nil, token: token, operation: "vehicle discovery"
            )
            legacyCars = response.data?.getConsumerCarsV2 ?? []
        } catch {
            if Self.isRequestLevelFailure(error) { throw error }
            logger.warning("Polestar vehicle discovery degraded (provider-specific): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            legacyCars = []
        }
        do {
            let vdmsCars = try await fetchAppBackendCars(token: accessToken ?? token)
            accountCars = vdmsCars.map { vdmsCar in
                if let matching = legacyCars.first(where: { $0.vin == vdmsCar.vin }) {
                    return ConsumerCarDTO(
                        vin: vdmsCar.vin,
                        internalVehicleIdentifier: vdmsCar.internalVehicleIdentifier ?? matching.internalVehicleIdentifier,
                        modelName: vdmsCar.modelName ?? matching.modelName,
                        modelYear: vdmsCar.modelYear ?? matching.modelYear,
                        registrationNo: vdmsCar.registrationNo ?? matching.registrationNo,
                        pno34: matching.pno34,
                        structureWeek: matching.structureWeek,
                        exteriorColorName: vdmsCar.exteriorColorName,
                        upholsteryName: vdmsCar.upholsteryName,
                        wheelsName: vdmsCar.wheelsName,
                        packageNames: vdmsCar.packageNames
                    )
                }
                return vdmsCar
            }
        } catch {
            if Self.isRequestLevelFailure(error) {
                // The app-backend endpoint is a secondary discovery source. If the primary
                // query already produced cars, keep those instead of failing the session;
                // only fail when we would otherwise report an empty garage.
                if legacyCars.isEmpty { throw error }
                logger.warning("Polestar VDMS discovery failed at request level; continuing with primary discovery results")
            } else {
                logger.warning("Polestar VDMS discovery degraded (provider-specific): \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)")
            }
            accountCars = legacyCars
        }
        guard requestEpoch == sessionEpoch else {
            logger.debug("Discarding superseded Polestar vehicle discovery")
            return
        }
        if accountCars.isEmpty {
            guard let manualVIN = preferredVIN?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  Self.isValidVIN(manualVIN) else { throw PolestarError.notConfigured }
            cars = [CarSummary(vin: manualVIN, title: manualVIN)]
            if selectedVIN != manualVIN { carImageData = nil }
            selectedVIN = manualVIN
            modelName = nil
            modelYear = nil
            registrationNo = nil
            pno34 = nil
            structureWeek = nil
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
        try applyCarInfo(vin: vin, from: accountCars)
    }

    private func fetchAppBackendCars(token: String) async throws -> [ConsumerCarDTO] {
        let query = """
        query GetVDMSCars {
          vdms {
            getVehiclesInformation {
              vin internalVehicleIdentifier registrationNo modelYear
              content {
                model { name }
                exterior { name }
                interior { name }
                wheels { name }
              }
            }
          }
        }
        """
        let body: [String: Any] = [
            "operationName": "GetVDMSCars",
            "variables": [:],
            "query": query,
            "extensions": ["clientLibrary": ["name": "apollo-kotlin", "version": "4.4.1"]]
        ]
        var request = URLRequest(url: appBackendURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("multipart/mixed;deferSpec=20220824, application/graphql-response+json, application/json",
                         forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "X-PolestarId-Authorization")
        request.setValue("GetVDMSCars", forHTTPHeaderField: "X-APOLLO-OPERATION-NAME")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "X-APOLLO-REQUEST-UUID")
        request.setValue(Locale.current.region?.identifier ?? market ?? "SE", forHTTPHeaderField: "X-Polestar-Locale")
        request.setValue("5.5.0", forHTTPHeaderField: "X-Polestar-Force-Update-Version")
        request.setValue("PolestarApp/5.5.0b1102 Android/14", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await perform(request, operation: "VDMS vehicle discovery")
        try validateHTTP(response, operation: "VDMS vehicle discovery")
        guard let decoded = try? JSONDecoder().decode(
            GraphQLResponse<AppBackendCarsPayloadDTO>.self, from: data
        ) else {
            throw PolestarError.decoding(operation: "VDMS vehicle discovery")
        }
        if let errors = decoded.errors, !errors.isEmpty {
            throw PolestarError.graphQL(Self.mapErrors(errors), hasPartialData: decoded.data != nil)
        }
        return (decoded.data?.vdms?.getVehiclesInformation ?? []).map(\.consumerCar)
    }

    func applyCarInfo(vin: String) async throws {
        guard accessToken != nil else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let requestEpoch = sessionEpoch
        try await fetchCarInfo(preferredVIN: vin)
        guard requestEpoch == sessionEpoch else { return }
        guard selectedVIN == vin else { throw PolestarError.notConfigured }
    }

    private func applyCarInfo(vin: String, from accountCars: [ConsumerCarDTO]) throws {
        guard let car = accountCars.first(where: { $0.vin == vin }) else {
            throw PolestarError.notConfigured
        }
        if selectedVIN != vin { carImageData = nil }
        selectedVIN = vin
        internalVehicleIdentifier = car.internalVehicleIdentifier
        modelName = car.modelName
        modelYear = car.modelYear?.value
        registrationNo = car.registrationNo
        pno34 = car.pno34
        structureWeek = car.structureWeek?.value
        exteriorColorName = car.exteriorColorName
        upholsteryName = car.upholsteryName
        wheelsName = car.wheelsName
        packageNames = car.packageNames
    }

    func fetchOwnerInfo() async {
        guard let token = accessToken, let userinfoEndpoint else { return }
        var request = URLRequest(url: userinfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await HTTPBodyReader.data(
                  for: request, using: session, limit: 256_000, operation: "user information", provider: .polestar),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let info = try? JSONDecoder().decode(UserInfoDTO.self, from: data) else { return }
        ownerFirstName = info.givenName ?? info.firstName
        market = info.market?.isEmpty == false ? info.market : nil
    }

    func fetchCarImage() async {
        let requestedAngle = await MainActor.run { preferences.carRenderAngle.rawValue }
        if let vin = selectedVIN, let cached = imageCache.image(for: vin, angle: requestedAngle) {
            carImageData = cached
        }
        guard let pno34, let structureWeek, let modelYear else { return }
        let query = """
        query GetCarImages($pno34: String!, $structureWeek: String!, $modelYear: String!, $locale: String) {
          getCarImages(pno34: $pno34, structureWeek: $structureWeek, modelYear: $modelYear, locale: $locale) {
            transparent { url angle }
            opaque { url angle }
          }
        }
        """
        let body: [String: Any] = ["query": query, "variables": [
            "pno34": pno34, "structureWeek": structureWeek,
            "modelYear": modelYear, "locale": "en-GB"
        ]]
        var request = URLRequest(url: publicApiURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(publicApiKey, forHTTPHeaderField: "x-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await HTTPBodyReader.data(
                  for: request, using: session, limit: 1_000_000, operation: "vehicle image metadata", provider: .polestar),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = json["data"] as? [String: Any],
              let images = payload["getCarImages"] as? [String: Any] else { return }
        let transparent = images["transparent"] as? [[String: Any]] ?? []
        let opaque = images["opaque"] as? [[String: Any]] ?? []
        let pool = transparent.isEmpty ? opaque : transparent
        let pick = pool.first(where: { ($0["angle"] as? Int) == requestedAngle })
            ?? pool.first(where: { ($0["angle"] as? Int) == 1 })
            ?? pool.first(where: { ($0["angle"] as? Int) == 0 }) ?? pool.first

        if carImageData == nil, let string = pick?["url"] as? String, let url = URL(string: string),
           url.scheme == "https" {
            if let (bytes, imageResponse) = try? await HTTPBodyReader.data(
                      for: URLRequest(url: url), using: session, limit: 5_000_000, operation: "vehicle image", provider: .polestar),
                  let http = imageResponse as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.mimeType?.hasPrefix("image/") == true,
                  bytes.count <= 5_000_000 {
                carImageData = bytes
                if let vin = selectedVIN {
                    let angle = (pick?["angle"] as? Int) ?? requestedAngle
                    imageCache.save(bytes, for: vin, angle: angle)
                    imageCache.save(bytes, for: vin)
                }
            }
        }

        if let vin = selectedVIN {
            for other in pool {
                guard let otherAngle = other["angle"] as? Int,
                      let otherUrlStr = other["url"] as? String,
                      let otherUrl = URL(string: otherUrlStr),
                      otherUrl.scheme == "https",
                      imageCache.image(for: vin, angle: otherAngle) == nil else { continue }
                enqueueImageDownload(
                    key: "\(vin)-angle-\(otherAngle)",
                    request: URLRequest(url: otherUrl),
                    operation: "vehicle angle image"
                ) { data in
                    self.imageCache.save(data, for: vin, angle: otherAngle)
                }
            }

            if let interiorPool = images["interior"] as? [[String: Any]],
               let interiorPick = interiorPool.first,
               let interiorUrlStr = interiorPick["url"] as? String,
               let interiorUrl = URL(string: interiorUrlStr),
               interiorUrl.scheme == "https",
                imageCache.interiorImage(for: vin) == nil {
                enqueueImageDownload(
                    key: "\(vin)-interior",
                    request: URLRequest(url: interiorUrl),
                    operation: "vehicle interior image"
                ) { data in
                    self.imageCache.saveInterior(data, for: vin)
                }
            }
        }
    }

    private func enqueueImageDownload(
        key: String,
        request: URLRequest,
        operation: String,
        save: @escaping @Sendable (Data) -> Void
    ) {
        guard imageDownloadTasks[key] == nil else { return }
        let task = Task { [weak self, session] in
            do {
                let (data, response) = try await HTTPBodyReader.data(
                    for: request, using: session, limit: 5_000_000, operation: operation, provider: .polestar
                )
                if (response as? HTTPURLResponse)?.statusCode == 200,
                   data.count <= 5_000_000 {
                    save(data)
                }
            } catch is CancellationError {
                // Cancellation is expected when the session or selected vehicle changes.
            } catch {
                self?.logger.debug("Background image download failed for \(operation, privacy: .public): \(error, privacy: .public)")
            }
            await self?.finishImageDownload(key)
        }
        imageDownloadTasks[key] = task
    }

    private func finishImageDownload(_ key: String) {
        imageDownloadTasks[key] = nil
    }

    func cancelImageDownloads() {
        imageDownloadTasks.values.forEach { $0.cancel() }
        imageDownloadTasks.removeAll()
    }


    func clearAccountState(keepRefreshToken: Bool = false) {
        sessionEpoch &+= 1
        accessToken = nil
        tokenExpiry = nil
        if !keepRefreshToken { refreshToken = nil }
        cars = []
        selectedVIN = nil
        internalVehicleIdentifier = nil
        modelName = nil
        modelYear = nil
        registrationNo = nil
        pno34 = nil
        structureWeek = nil
        exteriorColorName = nil
        upholsteryName = nil
        wheelsName = nil
        packageNames = []
        ownerFirstName = nil
        market = nil
        carImageData = nil
        targetCache = [:]
        capabilityBackoff = [:]
        capabilityCache = [:]
        remoteCommandsInFlight = []
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

    private static func validPolestarURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host,
              host == "polestar.com" || host.hasSuffix(".polestar.com") else { return nil }
        return url
    }

    static func isValidVIN(_ value: String) -> Bool {
        value.count == 17 && value.allSatisfy { character in
            character.isASCII && (character.isNumber || (character.isUppercase && !"IOQ".contains(character)))
        }
    }

    static func formBody(_ fields: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = fields.sorted(by: { $0.key < $1.key })
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.percentEncodedQuery.map { Data($0.utf8) }
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

    /// The app-scheme callback (`polestar-explore://explore.polestar.com`) carries no path,
    /// which URL reports as "" here and "/" in some redirect forms — treat those as equal.
    static func normalizedPath(_ url: URL) -> String {
        url.path == "/" ? "" : url.path
    }

    private static func queryValue(_ name: String, from url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
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

    static func extractResumePath(from html: String) -> String? {
        let patterns = [
            #"(?:url|action):\s*"([^"]+)""#,
            #"(?:resumePath|pf\.resumePath)\s*[:=]\s*['"]([^'"]+)['"]"#,
            #"action="([^"]+)""#,
            #"action:\s*'([^']+)'"#,
            #"url:\s*'([^']+)'"#,
            #"/as/[a-zA-Z0-9\-_./]+"#
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(html.startIndex..., in: html)
            guard let match = regex.firstMatch(in: html, range: range) else { continue }
            let group = match.numberOfRanges > 1 ? 1 : 0
            guard let matchRange = Range(match.range(at: group), in: html) else { continue }
            let value = String(html[matchRange])
            if (index == patterns.count - 1 || value.hasPrefix("/")), !value.contains("..") {
                return value
            }
        }
        return nil
    }

    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private static func mapErrors(_ errors: [GraphQLErrorDTO]) -> [GraphQLServiceError] {
        errors.map { GraphQLServiceError(message: $0.message, path: $0.path, code: $0.code) }
    }

    /// Compact `code: message @ path` rendering used for diagnostics. GraphQL errors carry no
    /// credentials, only the field that was rejected and why.
    private static func errorSummary(_ errors: [GraphQLErrorDTO]) -> String {
        errors.prefix(5).map { error in
            let code = error.code.map { "\($0): " } ?? ""
            let path = !error.path.isEmpty ? " @ \(error.path.joined(separator: "."))" : ""
            return "\(code)\(error.message)\(path)"
        }.joined(separator: " | ")
    }

    static func containsAuthenticationError(_ errors: [GraphQLErrorDTO]) -> Bool {
        errors.contains { error in
            // A field-scoped error rejects one field, not the session — GraphQL reuses the same
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
        guard let error = error as? PolestarError else { return false }
        switch error {
        case .authenticationRequired, .rateLimited: return true
        default: return false
        }
    }

    /// Errors that mean the request itself failed — authentication, rate limiting, server
    /// outage, or transport breakdown. Callers that degrade provider-specific gaps to "no
    /// data" must still surface these: swallowing an expired session or a rate-limit window
    /// here is what made outages masquerade as "Open Settings to sign in".
    static func isRequestLevelFailure(_ error: Error) -> Bool {
        switch error as? PolestarError {
        case .authenticationRequired, .rateLimited, .server, .network, .invalidResponse,
             .responseTooLarge:
            return true
        default:
            return false
        }
    }

    static func capabilityCacheLifetime(_ feature: AppFeature, key: String) -> TimeInterval {
        if key == "climate-status" {
            return 15
        }
        if feature == .exteriorStatus || feature == .airQuality || feature == .vehicleLocation {
            return 30
        }
        if feature == .vehicleWeather {
            return 300
        }
        return 60 * 60
    }

    static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func hasWarning(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.contains("NO_WARNING") && !value.contains("UNSPECIFIED")
    }

    static func fluidWarnings(_ health: HealthDTO?) -> [String] {
        guard let health else { return [] }
        let values = [
            (health.brakeFluidLevelWarning, "BRAKE_FLUID_LEVEL_WARNING_", L10n.text("Brake fluid")),
            (health.engineCoolantLevelWarning, "ENGINE_COOLANT_LEVEL_WARNING_", L10n.text("Coolant")),
            (health.oilLevelWarning, "OIL_LEVEL_WARNING_", L10n.text("Oil"))
        ]
        return values.compactMap { raw, prefix, label in
            guard let raw, hasWarning(raw) else { return nil }
            let detail = raw.replacingOccurrences(of: prefix, with: "")
                .replacingOccurrences(of: "_", with: " ").lowercased()
            return "\(label) \(detail)"
        }
    }
}

extension PolestarAPI: VehicleLiveStreaming {
    func liveVehicleUpdates(vin: String) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        return try await grpc.liveUpdates(vin: vin, accessToken: token)
    }
}

final class OAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// Both OAuth clients redirect through this one session, and the command client's callback
    /// is a custom scheme `URLSession` cannot load — so every callback the app might see has to
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
