import Foundation
import OSLog


actor VolvoAPI {
    nonisolated let brand: VehicleBrand = .volvo
    let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "volvo-api")


    private let identityHost = URL(string: "https://volvoid.eu.volvocars.com")!
    let authorizationPath = "/as/authorization.oauth2"
    private let tokenPath = "/as/token.oauth2"
    private let apiBaseURL = URL(string: "https://api.volvocars.com")!


    let redirectURI = URL(string: "https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html")!


    static let readScopes = [
        "openid",
        "conve:battery_charge_level", "conve:brake_status", "conve:climatization_start_stop",
        "conve:command_accessibility", "conve:commands", "conve:diagnostics_engine_status",
        "conve:diagnostics_workshop", "conve:doors_status", "conve:engine_status",
        "conve:fuel_status", "conve:lock_status", "conve:odometer_status",
        "conve:trip_statistics", "conve:tyre_status", "conve:vehicle_relation",
        "conve:warnings", "conve:windows_status", "energy:capability:read", "energy:state:read"
    ]

    static let restrictedScopes = [
        "conve:lock", "conve:unlock", "conve:engine_start_stop", "conve:honk_flash",
        "location:read"
    ]


    // Volvo gates these scopes behind per-application approval. Settings exposes an explicit
    // opt-in; only then does the next OAuth sign-in request them. This keeps an unapproved app
    // from breaking an otherwise valid read-only authorization request.


    var clientID: String?
    var clientSecret: String?
    var vccApiKey: String?


    var session: URLSession
    var accessToken: String?
    var refreshToken: String?
    var tokenExpiry: Date?
    var refreshTask: Task<VolvoTokenResponseDTO, Error>?
    var pendingVerifier: String?
    var pendingState: String?
    let keychain: KeychainStore
    let imageCache: CarImageCache
    let preferences: PreferencesStore

    var cars: [CarSummary] = []
    var selectedVIN: String?
    var vehicleDetailsCache: [String: VolvoVehicleDetailsDTO] = [:]
    var capabilityCache: [String: (value: VolvoEnergyCapabilitiesDTO, expiresAt: Date)] = [:]
    var endpointBackoff: [String: Date] = [:]
    var remoteCommandsInFlight: Set<String> = []
    var carImageData: [String: Data] = [:]
    var interiorImageData: [String: Data] = [:]

    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache(), preferences: PreferencesStore = PreferencesStore()) {
        self.keychain = keychain
        self.imageCache = imageCache
        self.preferences = preferences
        session = Self.makeSession()
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
        case .honkAndFlash: commandName = "honk-flash"
        case .flashLights: commandName = "flash"
        case .honkHorn: commandName = "honk"
        default:
            throw RemoteCommandError.unsupported
        }
        guard let vccApiKey else { throw VolvoError.appNotConfigured }
        var request = URLRequest(url: apiURL(
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
                throw VolvoError.permissionDenied(operation: "\(commandName) (\(text))")
            }
            throw failure
        }
        guard let envelope = try? JSONDecoder.volvo.decode(
            VolvoEnvelope<VolvoCommandResponseDTO>.self, from: data
        ), let payload = envelope.data else {
            throw VolvoError.decoding(operation: "command: \(commandName)")
        }
        if payload.isFailure {
            throw RemoteCommandError.rejected(payload.text
                ?? L10n.text("Vehicle reported command failed"))
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

    private func apiURL(path: String) -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: clean, relativeTo: apiBaseURL)!.absoluteURL
    }

    func identityURL(path: String) -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return URL(string: clean, relativeTo: identityHost)!.absoluteURL
    }

    func discoverVehicles(preferredVIN: String?) async throws {
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
            cars = summaries
            let selected = (savedVIN != nil) ? (cars.first(where: { $0.vin == savedVIN }) ?? cars.first) : cars.first
            selectedVIN = selected?.vin
        } catch {
            logger.warning("Volvo vehicle discovery fallback: \(error.localizedDescription, privacy: .public)")
            if let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
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
        guard let clientID, let clientSecret else { throw VolvoError.appNotConfigured }
        var request = URLRequest(url: identityURL(path: tokenPath))
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
        try apply(token)
    }

    func refreshTokenIfNeeded() async throws {
        if accessToken == nil || tokenExpiry == nil || (tokenExpiry?.timeIntervalSinceNow ?? 0) < 300 {
            try await refreshAccessToken(force: true)
        }
    }

    func refreshAccessToken(force: Bool) async throws {
        if !force, let expiry = tokenExpiry, accessToken != nil, expiry.timeIntervalSinceNow >= 300 { return }
        if let refreshTask {
            try apply(try await refreshTask.value)
            return
        }
        guard let clientID, let clientSecret, let refreshToken, !refreshToken.isEmpty else {
            throw VolvoError.authenticationRequired(.noStoredSession)
        }
        var request = URLRequest(url: identityURL(path: tokenPath))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        Self.applyBasicAuth(&request, clientID: clientID, clientSecret: clientSecret)
        request.httpBody = Self.formBody(["grant_type": "refresh_token", "refresh_token": refreshToken])
        let tokenRequest = request
        let task = Task { try await self.requestToken(tokenRequest) }
        refreshTask = task
        defer { refreshTask = nil }
        try apply(try await task.value)
    }

    private func apply(_ token: VolvoTokenResponseDTO) throws {
        let previous = refreshToken
        let renewable = token.refreshToken ?? refreshToken
        if let renewable, renewable != previous {
            try keychain.saveVolvoSessionToken(renewable)
        }
        accessToken = token.accessToken
        refreshToken = renewable
        tokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
    }

    private func requestToken(_ request: URLRequest) async throws -> VolvoTokenResponseDTO {
        let (data, response) = try await perform(request, operation: "Volvo token request")
        if response.statusCode == 400 || response.statusCode == 401 {
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let err = json["error"] as? String ?? "auth_error"
                let desc = json["error_description"] as? String ?? ""
                logger.error("Volvo token request rejected: \(err, privacy: .public) - \(desc, privacy: .public)")
            }
            throw VolvoError.authenticationRequired(.invalidCredentials)
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
            var request = URLRequest(url: apiURL(path: path))
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
            // not use this path, so their 403s stay `.permissionDenied` — the asymmetry is
            // deliberate. This is tuned from observed behaviour, not Volvo documentation.
            throw VolvoError.regionRestricted(service: path)
        }
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: path) { throw failure }
        let envelope = try? JSONDecoder.volvo.decode(VolvoEnvelope<T>.self, from: data)
        if let value = envelope?.data { return value }
        guard let direct = try? JSONDecoder.volvo.decode(T.self, from: data) else {
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


    func optional<Value: Sendable>(
        enabled: Bool, key: String, vin: String, operation: @Sendable () async throws -> Value
    ) async throws -> Value? {
        guard enabled else { return nil }
        let backoffKey = "\(vin)|\(key)"
        if let until = endpointBackoff[backoffKey], until > Date() { return nil }
        do {
            let value = try await operation()
            endpointBackoff[backoffKey] = nil
            return value
        } catch {
            if Self.isGlobalFailure(error) { throw error }
            endpointBackoff[backoffKey] = Date().addingTimeInterval(5 * 60)
            logger.error("""
                Optional Volvo endpoint unavailable: \(key, privacy: .public) — \
                \(String(describing: error), privacy: .public)
                """)
            return nil
        }
    }


    private static func isGlobalFailure(_ error: Error) -> Bool {
        guard let error = error as? VolvoError else { return false }
        switch error {
        case .authenticationRequired, .appNotConfigured, .rateLimited: return true
        default: return false
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
