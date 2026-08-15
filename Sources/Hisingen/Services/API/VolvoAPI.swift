import Foundation
import OSLog


actor VolvoAPI {
    nonisolated let brand: VehicleBrand = .volvo
    private let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "volvo-api")


    private let identityHost = URL(string: "https://volvoid.eu.volvocars.com")!
    private let authorizationPath = "/as/authorization.oauth2"
    private let tokenPath = "/as/token.oauth2"
    private let apiBaseURL = URL(string: "https://api.volvocars.com")!


    let redirectURI = URL(string: "https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html")!


    private static let readScopes = [
        "openid",
        "conve:battery_charge_level", "conve:brake_status", "conve:climatization_start_stop",
        "conve:command_accessibility", "conve:commands", "conve:diagnostics_engine_status",
        "conve:diagnostics_workshop", "conve:doors_status", "conve:engine_status",
        "conve:fuel_status", "conve:lock_status", "conve:odometer_status",
        "conve:trip_statistics", "conve:tyre_status", "conve:vehicle_relation",
        "conve:warnings", "conve:windows_status", "energy:capability:read", "energy:state:read"
    ]


    private static let restrictedScopes = [
        "conve:lock", "conve:unlock", "conve:engine_start_stop", "conve:honk_flash", "location:read"
    ]


    private var clientID: String?
    private var clientSecret: String?
    private var vccApiKey: String?


    private var session: URLSession
    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var refreshTask: Task<VolvoTokenResponseDTO, Error>?
    private var pendingVerifier: String?
    private var pendingState: String?
    private let keychain: KeychainStore

    private(set) var cars: [CarSummary] = []
    private var selectedVIN: String?
    private var vehicleDetailsCache: [String: VolvoVehicleDetailsDTO] = [:]
    private var capabilityCache: [String: (value: VolvoEnergyCapabilitiesDTO, expiresAt: Date)] = [:]
    private var endpointBackoff: [String: Date] = [:]
    private var remoteCommandsInFlight: Set<String> = []


    init(keychain: KeychainStore = .app) {
        self.keychain = keychain
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


    func beginSignIn() throws -> URL {
        guard isConfigured, let clientID else { throw VolvoError.appNotConfigured }
        let verifier = try PKCE.randomURLSafeString()
        let state = try PKCE.randomURLSafeString()
        pendingVerifier = verifier
        pendingState = state
        var components = URLComponents(
            url: identityHost.appendingPathComponent(authorizationPath), resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: (Self.readScopes + Self.restrictedScopes).joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: PKCE.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "response_mode", value: "query")
        ]
        guard let url = components.url else { throw VolvoError.incompatibleAPI(operation: "authorization request") }
        return url
    }


    func completeSignIn(callbackURL: URL, preferredVIN: String?, features: FeatureSelection) async throws {
        guard let verifier = pendingVerifier, let expectedState = pendingState else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        pendingVerifier = nil
        pendingState = nil
        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        if let error = components.queryItems?.first(where: { $0.name == "error" })?.value {
            let desc = components.queryItems?.first(where: { $0.name == "error_description" })?.value ?? error
            throw VolvoError.permissionDenied(operation: desc)
        }
        guard components.queryItems?.first(where: { $0.name == "state" })?.value == expectedState,
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw VolvoError.authenticationRequired(.callbackRejected)
        }
        try await exchangeCodeForToken(code, verifier: verifier)
        try await discoverVehicles(preferredVIN: preferredVIN)
    }


    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        throw VolvoError.authenticationRequired(.callbackRejected)
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else { throw VolvoError.authenticationRequired(.noStoredSession) }
        guard isConfigured else { throw VolvoError.appNotConfigured }
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as VolvoError where error.requiresAuthentication {
            try? keychain.deleteVolvoSessionToken()
            refreshToken = nil
            throw error
        }
        try await discoverVehicles(preferredVIN: preferredVIN)
        logger.info("Stored Volvo session restored")
    }

    func resetSession() async {
        accessToken = nil
        refreshToken = nil
        tokenExpiry = nil
        refreshTask?.cancel()
        refreshTask = nil
        pendingVerifier = nil
        pendingState = nil
        cars = []
        selectedVIN = nil
        vehicleDetailsCache = [:]
        capabilityCache = [:]
        endpointBackoff = [:]
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
        if let preferred, cars.contains(where: { $0.vin == preferred }) { return preferred }
        return cars.first?.vin
    }

    func selectCar(vin: String, features: FeatureSelection) async throws {
        guard cars.contains(where: { $0.vin == vin }) else { throw VolvoError.notConfigured }
        selectedVIN = vin
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await refreshTokenIfNeeded()
        guard accessToken != nil else { throw VolvoError.authenticationRequired(.expiredSession) }

        let details = try await vehicleDetails(vin: vin)
        let powertrain = VolvoPowertrain.classify(fuelType: details.fuelType)
        let needsEnergy = powertrain.hasElectricRange
            && (features.contains(.chargingDetails) || features.contains(.remoteCharging)
                || features.contains(.batteryDiagnostics))


        let needsStatistics = features.contains(.tripMeters)
            || (powertrain.hasFuelRange && features.contains(.batteryDiagnostics))

        async let energyTask: VolvoEnergyStateDTO? = optional(enabled: needsEnergy, key: "energy-state", vin: vin) {
            try await self.get("/energy/v2/vehicles/\(vin)/state")
        }
        async let doorsTask: VolvoDoorsDTO? = optional(
            enabled: features.contains(.exteriorStatus) || features.contains(.remoteLocks), key: "doors", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/doors") }
        async let windowsTask: VolvoWindowsDTO? = optional(
            enabled: features.contains(.exteriorStatus) || features.contains(.remoteWindows), key: "windows", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/windows") }
        async let tyresTask: VolvoTyresDTO? = optional(
            enabled: features.contains(.tyreAndWarnings), key: "tyres", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/tyres") }
        async let diagnosticsTask: VolvoDiagnosticsDTO? = optional(
            enabled: features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings), key: "diagnostics", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/diagnostics") }
        async let odometerTask: VolvoOdometerDTO? = optional(
            enabled: features.contains(.vehicleHealth), key: "odometer", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/odometer") }
        async let statisticsTask: VolvoStatisticsDTO? = optional(
            enabled: needsStatistics, key: "statistics", vin: vin
        ) { try await self.get("/connected-vehicle/v2/vehicles/\(vin)/statistics") }
        async let locationTask: VolvoLocationDTO? = optional(
            enabled: features.contains(.vehicleLocation), key: "location", vin: vin
        ) { try await self.get("/location/v1/vehicles/\(vin)/location") }

        let energy = try await energyTask
        let doors = try await doorsTask
        let windows = try await windowsTask
        let tyres = try await tyresTask
        let diagnostics = try await diagnosticsTask
        let odometer = try await odometerTask
        let statistics = try await statisticsTask
        let location = try await locationTask

        var unavailable: [AppFeature] = []
        if features.contains(.exteriorStatus), doors == nil, windows == nil { unavailable.append(.exteriorStatus) }
        if features.contains(.tyreAndWarnings), tyres == nil { unavailable.append(.tyreAndWarnings) }
        if features.contains(.vehicleHealth), diagnostics == nil, odometer == nil { unavailable.append(.vehicleHealth) }
        if features.contains(.vehicleLocation), location == nil { unavailable.append(.vehicleLocation) }
        if features.contains(.tripMeters), statistics == nil { unavailable.append(.tripMeters) }

        var openings: [OpeningReading] = []
        let doorFields: [(VehicleOpening, String?)] = [
            (.frontLeftDoor, doors?.frontLeftDoor?.value), (.frontRightDoor, doors?.frontRightDoor?.value),
            (.rearLeftDoor, doors?.rearLeftDoor?.value), (.rearRightDoor, doors?.rearRightDoor?.value),
            (.hood, doors?.hood?.value), (.tailgate, doors?.tailgate?.value), (.chargeLid, doors?.tankLid?.value)
        ]
        let windowFields: [(VehicleOpening, String?)] = [
            (.frontLeftWindow, windows?.frontLeftWindow?.value), (.frontRightWindow, windows?.frontRightWindow?.value),
            (.rearLeftWindow, windows?.rearLeftWindow?.value), (.rearRightWindow, windows?.rearRightWindow?.value),
            (.sunroof, windows?.sunroof?.value)
        ]
        for (opening, raw) in doorFields + windowFields {
            if let state = OpeningState(volvoStatus: raw) { openings.append(OpeningReading(opening: opening, state: state)) }
        }
        let exterior: ExteriorSnapshot? = (doors != nil || windows != nil)
            ? ExteriorSnapshot(openings: openings, isLocked: doors?.isLocked, alarmTriggered: nil)
            : nil

        let energyCaps = needsEnergy ? try? await energyCapabilities(vin: vin) : nil
        var probes = VehicleProbedCapabilities()
        if doors != nil || windows != nil { probes.record(.exteriorStatus, as: .supported) }
        if diagnostics != nil { probes.record(.serviceWarnings, as: .supported) }
        if statistics?.tripMeterManual != nil || statistics?.tripMeterAutomatic != nil {
            probes.record(.tripMeters, as: .supported)
        }


        if let supported = energyCaps?.targetBatteryLevel?.isSupported {
            probes.record(.chargeTarget, as: supported ? .supported : .unavailable)
        }
        if let supported = energyCaps?.chargingPower?.isSupported {
            probes.record(.chargingCurrentLimit, as: supported ? .supported : .unavailable)
        }


        return VehicleState(
            batteryPercentage: energy?.batteryChargeLevel?.value,
            rangeKm: energy?.electricRange?.value,
            chargingState: ChargingState(volvoChargingStatus: energy?.chargingStatus?.value),
            estimatedChargingTimeToFullMinutes: energy?.estimatedChargingTimeToFull?.value,
            chargeTargetPercentage: energy?.targetBatteryLevel?.value,
            chargingPowerWatts: energy?.chargingPower?.value.map { Int(($0 * 1_000).rounded()) },
            chargingCurrentAmps: energy?.chargingCurrent?.value.map { Int($0.rounded()) },
            chargingVoltageVolts: energy?.chargingVoltage?.value.map { Int($0.rounded()) },
            chargingType: .unknown,
            chargerConnection: ChargerConnection(volvoConnectionStatus: energy?.chargerConnectionStatus?.value),
            availability: .unknown,
            modelName: details.descriptions?.model,
            modelYear: details.modelYear.map(String.init),
            registrationNo: nil,
            vin: vin,
            ownerFirstName: nil,
            odometerKm: odometer?.odometer?.value,
            daysToService: diagnostics?.daysToServiceApprox,
            distanceToServiceKm: diagnostics?.distanceToService?.value,
            serviceWarning: diagnostics?.hasServiceWarning ?? false,
            fluidWarnings: diagnostics?.fluidWarnings ?? [],
            exteriorStatus: exterior,
            healthDetails: (tyres != nil || diagnostics != nil)
                ? VehicleHealthDetails(tyres: tyres?.readings ?? [], warnings: diagnostics?.vehicleWarnings ?? [])
                : nil,
            tripMeterManualKm: statistics?.tripMeterManual?.value,
            tripMeterAutomaticKm: statistics?.tripMeterAutomatic?.value,
            unavailableFeatures: unavailable,
            probedCapabilities: probes.count > 0 ? probes : nil,
            powertrain: powertrain,


            fuelLevelPercent: nil,
            fuelRangeKm: statistics?.distanceToEmptyTank?.value,
            reportedBatteryCapacityKwh: details.batteryCapacityKWH,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: [energy?.batteryChargeLevel?.updatedAt, diagnostics?.serviceWarning?.updatedAt]
                .compactMap { $0 }.max(),
            dataWarnings: []
        )
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        guard selectedVIN == vin || cars.contains(where: { $0.vin == vin }) else {
            throw RemoteCommandError.missingContext
        }
        guard !remoteCommandsInFlight.contains(vin) else { throw RemoteCommandError.busy }
        remoteCommandsInFlight.insert(vin)
        defer { remoteCommandsInFlight.remove(vin) }
        try await refreshTokenIfNeeded()
        guard let token = accessToken else { throw VolvoError.authenticationRequired(.expiredSession) }


#if HISINGEN_EXPERIMENTAL_REMOTE
        return try await dispatchCommand(command, vin: vin, accessToken: token)
#else
        _ = token
        throw RemoteCommandError.unsupported
#endif
    }

#if HISINGEN_EXPERIMENTAL_REMOTE


    private func dispatchCommand(_ command: RemoteCommand, vin: String, accessToken: String) async throws -> RemoteCommandResult {
        let commandName: String
        switch command {
        case .lock: commandName = "lock"
        case .unlock: commandName = "unlock"
        case .startClimate: commandName = "climatization-start"
        case .stopClimate: commandName = "climatization-stop"
        case .honkAndFlash: commandName = "honk-flash"
        case .flashLights: commandName = "flash"
        default:
            throw RemoteCommandError.unsupported
        }
        guard let vccApiKey else { throw VolvoError.appNotConfigured }
        var request = URLRequest(url: apiBaseURL.appendingPathComponent(
            "/connected-vehicle/v2/vehicles/\(vin)/commands/\(commandName)"
        ))
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
        let (_, response) = try await perform(request, operation: "command: \(commandName)")
        if let failure = VolvoError.httpFailure(statusCode: response.statusCode, operation: commandName) {
            throw failure
        }
        return RemoteCommandResult(outcome: .accepted, message: nil)
    }
#endif


    private func discoverVehicles(preferredVIN: String?) async throws {
        let list: [VolvoVehicleSummaryDTO] = try await getList("/connected-vehicle/v2/vehicles")
        guard !list.isEmpty else {
            cars = []
            selectedVIN = nil
            return
        }
        var summaries: [CarSummary] = []
        for entry in list {
            let details = try? await vehicleDetails(vin: entry.vin)
            let title = [details?.descriptions?.model, details?.modelYear.map(String.init)]
                .compactMap { $0 }.joined(separator: " · ")
            summaries.append(CarSummary(vin: entry.vin, title: title.isEmpty ? entry.vin : title))
        }
        cars = summaries
        let selected = preferredVIN.flatMap { wanted in cars.first(where: { $0.vin == wanted }) } ?? cars.first
        selectedVIN = selected?.vin
    }

    private func vehicleDetails(vin: String) async throws -> VolvoVehicleDetailsDTO {
        if let cached = vehicleDetailsCache[vin] { return cached }
        let details: VolvoVehicleDetailsDTO = try await get("/connected-vehicle/v2/vehicles/\(vin)")
        vehicleDetailsCache[vin] = details
        return details
    }


    private func exchangeCodeForToken(_ code: String, verifier: String) async throws {
        guard let clientID, let clientSecret else { throw VolvoError.appNotConfigured }
        var request = URLRequest(url: identityHost.appendingPathComponent(tokenPath))
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

    private func refreshTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry else { throw VolvoError.authenticationRequired(.expiredSession) }
        if expiry.timeIntervalSinceNow < 300 { try await refreshAccessToken(force: false) }
    }

    private func refreshAccessToken(force: Bool) async throws {
        if !force, let expiry = tokenExpiry, expiry.timeIntervalSinceNow >= 300 { return }
        if let refreshTask {
            try apply(try await refreshTask.value)
            return
        }
        guard let clientID, let clientSecret, let refreshToken else {
            throw VolvoError.authenticationRequired(.expiredSession)
        }
        var request = URLRequest(url: identityHost.appendingPathComponent(tokenPath))
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
            var request = URLRequest(url: apiBaseURL.appendingPathComponent(path))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(vccApiKey, forHTTPHeaderField: "vcc-api-key")
            request.setValue("Hisingen/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await perform(request, operation: path)
            if response.statusCode == 401, attempt == 0 {
                try await refreshAccessToken(force: true)
                guard let refreshed = accessToken else {
                    throw VolvoError.authenticationRequired(.expiredSession)
                }
                token = refreshed
                continue
            }
            return (data, response)
        }
        throw VolvoError.authenticationRequired(.expiredSession)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await authenticatedGET(path)
        if response.statusCode == 403 {


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

    private func getList<T: Decodable>(_ path: String) async throws -> [T] {
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


    private func optional<Value: Sendable>(
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
            logger.debug("Optional Volvo endpoint unavailable: \(key, privacy: .public)")
            return nil
        }
    }


    private func energyCapabilities(vin: String) async throws -> VolvoEnergyCapabilitiesDTO? {
        if let cached = capabilityCache[vin], cached.expiresAt > Date() { return cached.value }
        guard let caps: VolvoEnergyCapabilitiesDTO = try? await get("/energy/v2/vehicles/\(vin)/capabilities") else {
            return nil
        }
        capabilityCache[vin] = (caps, Date().addingTimeInterval(3_600))
        return caps
    }


    private static func isGlobalFailure(_ error: Error) -> Bool {
        guard let error = error as? VolvoError else { return false }
        switch error {
        case .authenticationRequired, .appNotConfigured, .rateLimited: return true
        default: return false
        }
    }


    private func perform(_ request: URLRequest, limit: Int = 2_000_000,
                         operation: String) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if response.expectedContentLength > Int64(limit) {
                throw VolvoError.responseTooLarge(operation: operation)
            }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw VolvoError.responseTooLarge(operation: operation) }
                data.append(byte)
            }
            guard let http = response as? HTTPURLResponse else {
                throw VolvoError.invalidResponse(operation: operation)
            }
            return (data, http)
        } catch let error as URLError {
            throw VolvoError.network(error)
        }
    }

    private static func applyBasicAuth(_ request: inout URLRequest, clientID: String, clientSecret: String) {
        let credentials = Data("\(clientID):\(clientSecret)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
    }

    private static func formBody(_ fields: [String: String]) -> Data? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        let encoded = fields.sorted(by: { $0.key < $1.key })
            .compactMap { key, value in
                guard let k = key.addingPercentEncoding(withAllowedCharacters: allowed),
                      let v = value.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func makeSession() -> URLSession {
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


