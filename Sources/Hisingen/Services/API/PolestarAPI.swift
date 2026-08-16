import AppKit
import Foundation
import OSLog

private struct OptionalCapability<Value: Sendable>: Sendable {
    let value: Value?
    let unavailable: Bool
}

private struct CapabilityCacheEntry {
    let value: (any Sendable)?
    let expiresAt: Date
}

actor PolestarAPI {
    nonisolated let brand: VehicleBrand = .polestar
    private let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "api")

    private let apiBaseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-v2/")!
    private let publicApiURL = URL(string: "https://pc-api.polestar.com/eu-north-1/mystar-public/")!
    private let appBackendURL = URL(string: "https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql")!


    private let publicApiKey = "da2-js63uvc7c5hwpdudt657d5lyou"
    private let oidcProviderURL = URL(string: "https://polestarid.eu.polestar.com")!

    // The polestar.com web client. The mobile-app client (`lp8dyrd_10`,
    // `polestar-explore://explore.polestar.com`) authenticates fine but its token is rejected
    // by `pc-api.polestar.com/mystar-v2` with `UnauthorizedException`, so vehicle discovery
    // returns nothing and the app has no car to talk about — verified live against a real
    // account. The `getConsumerCarsV2` query only accepts this client.
    private let oidcClientID = "l3oopkc_10"
    private let oidcRedirectURL = URL(string: "https://www.polestar.com/sign-in-callback")!
    // `customer:attributes:write` is what the C3 `ota_mobcache.SchedulerService` write RPCs
    // require. This client grants it on request — adding it does not disturb discovery.
    private let oidcScope = "openid profile email customer:attributes customer:attributes:write"

    // Remote commands are gated on a *client-id allowlist*, separate from scope. C3 spells the
    // rule out when it refuses: `Client id l3oopkc_10 is not a required client id: [… lp8dyrd_10 …]`.
    // The web client above can list vehicles but cannot invoke; this one can invoke but is
    // rejected by `mystar-v2` for reads. Neither is sufficient alone, so the app holds a token
    // from each and picks per call. Verified live: `Lock` via C3 with this client returns
    // `outcome = accepted`.
    private let commandClientID = "lp8dyrd_10"
    private let commandRedirectURL = URL(string: "polestar-explore://explore.polestar.com")!

    private var commandAccessToken: String?
    private var commandRefreshToken: String?
    private var commandTokenExpiry: Date?

    private var session: URLSession
    private var redirectDelegate: OAuthRedirectDelegate
    private let grpc = PolestarGRPC()
    private let keychain: KeychainStore

    private var accessToken: String?
    private var refreshToken: String?
    private var tokenExpiry: Date?
    private var refreshTask: Task<TokenResponseDTO, Error>?

    private var tokenEndpoint: URL?
    private var authorizationEndpoint: URL?
    private var userinfoEndpoint: URL?
    private var revocationEndpoint: URL?

    private(set) var cars: [CarSummary] = []
    private var selectedVIN: String?
    private var internalVehicleIdentifier: String?
    private var modelName: String?
    private var modelYear: String?
    private var registrationNo: String?
    private var pno34: String?
    private var structureWeek: String?
    private var exteriorColorName: String?
    private var upholsteryName: String?
    private var wheelsName: String?
    private var packageNames: [String] = []
    private var ownerFirstName: String?
    private var market: String?
    private var carImageData: Data?
    private var targetCache: [String: (value: Int?, fetchedAt: Date)] = [:]
    private var capabilityBackoff: [String: [String: Date]] = [:]
    private var capabilityCache: [String: CapabilityCacheEntry] = [:]
    private var remoteCommandsInFlight: Set<String> = []

    init(keychain: KeychainStore = .app) {
        self.keychain = keychain
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
    }

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
        await acquireCommandToken(email: email, password: password)
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage) { await fetchCarImage() }
        if features.contains(.ownerGreeting) { await fetchOwnerInfo() }
    }

    /// Signs in a second time as the command-capable client. Failure is non-fatal: reads and
    /// OTA still work without it, only invocation-backed commands become unavailable.
    private func acquireCommandToken(email: String, password: String) async {
        do {
            let authorization = try await obtainAuthorizationCode(
                email: email, password: password,
                clientID: commandClientID, redirectURI: commandRedirectURL, scope: oidcScope
            )
            let token = try await exchangeCode(authorization.code, verifier: authorization.verifier,
                                               clientID: commandClientID, redirectURI: commandRedirectURL)
            commandAccessToken = token.accessToken
            commandRefreshToken = token.refreshToken
            commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
            if let refresh = token.refreshToken { try? keychain.saveCommandSessionToken(refresh) }
            logger.info("Polestar command-client token acquired")
        } catch {
            print("❌ acquireCommandToken failed with error: \(error)")
            logger.warning("Polestar command-client sign-in failed: \(error, privacy: .public); remote commands unavailable")
        }
    }

    @MainActor
    private static func promptForCredentials(prefilledEmail: String) -> (email: String, password: String)? {
        NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps])
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = L10n.text("Polestar ID Password Required")
        alert.informativeText = L10n.text(
            "Enter your Polestar ID password to authorize remote vehicle controls. Hisingen will securely save your mobile command session in macOS Keychain."
        )
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 280, height: prefilledEmail.isEmpty ? 56 : 26))
        stack.orientation = .vertical
        stack.spacing = 6
        stack.alignment = .leading

        let emailField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        emailField.placeholderString = L10n.text("Polestar ID (Email)")
        emailField.stringValue = prefilledEmail

        let passwordField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        passwordField.placeholderString = L10n.text("Password")

        if prefilledEmail.isEmpty {
            stack.addArrangedSubview(emailField)
        }
        stack.addArrangedSubview(passwordField)

        alert.accessoryView = stack
        alert.addButton(withTitle: L10n.text("Authorize"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        alert.window.initialFirstResponder = prefilledEmail.isEmpty ? emailField : passwordField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let email = (prefilledEmail.isEmpty ? emailField.stringValue : prefilledEmail).trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = passwordField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !email.isEmpty, !pass.isEmpty else { return nil }
        if Preferences.email.isEmpty { Preferences.email = email }
        return (email, pass)
    }

    /// A valid token for invocation-backed commands, refreshed on demand.
    private func validCommandToken() async -> String? {
        if let expiry = commandTokenExpiry, expiry.timeIntervalSinceNow > 300,
           let token = commandAccessToken { return token }
        let stored = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        if let refresh = stored, let tokenEndpoint {
            var request = URLRequest(url: tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                "grant_type": "refresh_token",
                "client_id": commandClientID,
                "refresh_token": refresh
            ])
            if let token = try? await Self.requestToken(request: request, session: session,
                                                        invalidReason: .expiredSession) {
                commandAccessToken = token.accessToken
                commandRefreshToken = token.refreshToken ?? refresh
                commandTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
                if let refreshed = token.refreshToken { try? keychain.saveCommandSessionToken(refreshed) }
                return token.accessToken
            }
        }
        let savedEmail = (await MainActor.run { Preferences.email }).trimmingCharacters(in: .whitespacesAndNewlines)
        var emailToUse = savedEmail
        var passwordToUse = (try? keychain.readPassword()) ?? nil
        if passwordToUse == nil || passwordToUse?.isEmpty == true {
            if let creds = await MainActor.run(body: { Self.promptForCredentials(prefilledEmail: savedEmail) }) {
                emailToUse = creds.email
                passwordToUse = creds.password
            }
        }
        if !emailToUse.isEmpty, let password = passwordToUse, !password.isEmpty {
            await acquireCommandToken(email: emailToUse, password: password)
            return commandAccessToken
        }
        return nil
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else {
            throw PolestarError.authenticationRequired(.noStoredSession)
        }
        clearAccountState(keepRefreshToken: true)
        if let commandRefresh = (try? keychain.readCommandSessionToken()) ?? nil, !commandRefresh.isEmpty {
            commandRefreshToken = commandRefresh
        }
        try await discoverOIDCConfiguration()
        refreshToken = token
        do {
            try await refreshAccessToken(force: true)
        } catch let error as PolestarError where error.requiresAuthentication {
            try? keychain.deleteSessionToken()
            refreshToken = nil
            throw error
        }
        try await fetchCarInfo(preferredVIN: preferredVIN)
        if features.contains(.vehicleImage) { await fetchCarImage() }
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
        refreshTask?.cancel()
        refreshTask = nil
        clearAccountState()
        session.invalidateAndCancel()
        let delegate = OAuthRedirectDelegate(callbackURLs: [oidcRedirectURL, commandRedirectURL])
        redirectDelegate = delegate
        session = Self.makeSession(delegate: delegate)
        await grpc.invalidateDiscoveredHost()
    }

    func signOut() async throws {
        // Two clients were signed in, so both refresh tokens have to go. Revoke the command
        // client's first — it is the one that can act on the vehicle.
        let commandToRevoke = commandRefreshToken ?? ((try? keychain.readCommandSessionToken()) ?? nil)
        if let commandToRevoke, let endpoint = revocationEndpoint {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formBody([
                "client_id": commandClientID,
                "token": commandToRevoke,
                "token_type_hint": "refresh_token"
            ])
            _ = try? await perform(request, limit: 64_000, operation: "command session revocation")
        }
        try? keychain.deleteCommandSessionToken()

        let tokenToRevoke = refreshToken
        let endpoint = revocationEndpoint
        if let tokenToRevoke, let endpoint {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                request.httpBody = Self.formBody([
                    "client_id": oidcClientID,
                    "token": tokenToRevoke,
                    "token_type_hint": "refresh_token"
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
        guard cars.contains(where: { $0.vin == vin }) else {
            throw PolestarError.notConfigured
        }
        try await applyCarInfo(vin: vin)
        if features.contains(.vehicleImage) { await fetchCarImage() }
        if features.contains(.ownerGreeting), ownerFirstName == nil { await fetchOwnerInfo() }
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }

        let query = Self.telematicsQuery(features: features)
        let response: GraphQLResponse<TelematicsPayloadDTO>? = try? await graphQL(
            query: query,
            variables: ["vins": [vin]],
            token: token,
            operation: "vehicle telematics"
        )
        let telematics = response?.data?.carTelematicsV2

        let battery = Self.matchingReading(telematics?.battery, vin: vin, vinOf: { $0.vin })
        let odometer = Self.matchingReading(telematics?.odometer, vin: vin, vinOf: { $0.vin })
        let health = Self.matchingReading(telematics?.health, vin: vin, vinOf: { $0.vin })

        let serviceToken = accessToken ?? token

        let needsChargingContext = features.contains(.chargingDetails) || features.contains(.remoteCharging)
            || battery == nil
        let modelProfile = VehicleCapabilityProfile(modelName: modelName)
        let needsExterior = features.contains(.exteriorStatus) || features.contains(.remoteLocks)
            || features.contains(.remoteWindows)
        let needsSoftware = features.contains(.softwareUpdates) || features.contains(.remoteOTA)
        let needsSchedules = features.contains(.chargingSchedule) || features.contains(.remoteSchedules)
        let needsClimate = features.contains(.climateStatus) || features.contains(.remoteClimate)
        let needsClimateTimers = features.contains(.climateStatus) || features.contains(.remoteSchedules)
        let needsAirQuality = features.contains(.airQuality)
            || (features.contains(.remotePreCleaning) && modelProfile.permits(.preCleaning))

        async let batteryExtrasTask = optionalBattery(
            enabled: needsChargingContext || features.contains(.batteryDiagnostics) || battery == nil,
            vin: vin, token: serviceToken
        )
        async let availabilityTask = optionalAvailability(
            enabled: features.contains(.vehicleAvailability), vin: vin, token: serviceToken
        )
        async let targetTask = targetSOC(
            enabled: needsChargingContext, vin: vin, token: serviceToken
        )
        async let exteriorTask: OptionalCapability<ExteriorSnapshot> = optionalCapability(
            features.contains(.exteriorStatus) ? .exteriorStatus : .remoteLocks,
            enabled: needsExterior, vin: vin
        ) { try await self.grpc.fetchExterior(vin: vin, accessToken: serviceToken) }
        async let healthTask: OptionalCapability<GrpcHealthReport> = optionalCapability(
            .tyreAndWarnings,
            enabled: features.contains(.tyreAndWarnings) || features.contains(.vehicleHealth), vin: vin
        ) { try await self.grpc.fetchHealth(vin: vin, accessToken: serviceToken) }
        async let softwareTask: OptionalCapability<VehicleSoftwareInfo> = optionalCapability(
            features.contains(.softwareUpdates) ? .softwareUpdates : .remoteOTA,
            enabled: needsSoftware, vin: vin
        ) {
            try await self.grpc.fetchSoftware(vin: vin, accessToken: serviceToken,
                                              locale: Preferences.interfaceLanguage.effectiveLanguageCode)
        }
        async let scheduleTask: OptionalCapability<[VehicleSchedule]> = optionalCapability(
            features.contains(.chargingSchedule) ? .chargingSchedule : .remoteSchedules,
            enabled: needsSchedules, vin: vin
        ) { Optional(try await self.grpc.fetchChargingSchedules(vin: vin, accessToken: serviceToken)) }
        async let climateTask: OptionalCapability<VehicleClimateStatus> = optionalCapability(
            features.contains(.climateStatus) ? .climateStatus : .remoteClimate,
            key: "climate-status", enabled: needsClimate, vin: vin
        ) { try await self.grpc.fetchClimate(vin: vin, accessToken: serviceToken) }
        async let climateTimersTask: OptionalCapability<[VehicleSchedule]> = optionalCapability(
            features.contains(.climateStatus) ? .climateStatus : .remoteSchedules,
            key: "climate-timers", enabled: needsClimateTimers, vin: vin
        ) { Optional(try await self.grpc.fetchClimateTimers(vin: vin, accessToken: serviceToken)) }
        async let tripsTask: OptionalCapability<GrpcOdometerReport> = optionalCapability(
            .tripMeters, enabled: features.contains(.tripMeters), vin: vin
        ) { try await self.grpc.fetchOdometer(vin: vin, accessToken: serviceToken) }
        async let connectivityTask: OptionalCapability<VehicleConnectivity> = optionalCapability(
            .connectivityDiagnostics,
            enabled: features.contains(.connectivityDiagnostics) && modelProfile.permits(.connectivity),
            vin: vin
        ) { try await self.grpc.fetchConnectivity(vin: vin, accessToken: serviceToken) }
        async let airTask: OptionalCapability<VehicleAirQuality> = optionalCapability(
            features.contains(.airQuality) ? .airQuality : .remotePreCleaning,
            enabled: needsAirQuality, vin: vin
        ) { try await self.grpc.fetchAirQuality(vin: vin, accessToken: serviceToken) }
        async let weatherTask: OptionalCapability<VehicleWeather> = optionalCapability(
            .vehicleWeather, enabled: features.contains(.vehicleWeather), vin: vin
        ) { try await self.grpc.fetchWeather(vin: vin, accessToken: serviceToken) }
        async let locationTask: OptionalCapability<VehicleLocation> = optionalCapability(
            .vehicleLocation, enabled: features.contains(.vehicleLocation), vin: vin
        ) { try await self.grpc.fetchLocation(vin: vin, accessToken: serviceToken) }
        async let ampLimitTask: OptionalCapability<Int> = optionalCapability(
            .chargingDetails, key: "amp-limit",
            enabled: needsChargingContext && modelProfile.permits(.chargingCurrentLimit), vin: vin
        ) { try await self.grpc.fetchAmpLimit(vin: vin, accessToken: serviceToken) }

        let extras = try await batteryExtrasTask
        let vehicleAvailability = try await availabilityTask
        let chargeTarget = try await targetTask
        let exterior = try await exteriorTask
        let c3Health = try await healthTask
        let software = try await softwareTask
        let schedules = try await scheduleTask
        let climate = try await climateTask
        let climateTimers = try await climateTimersTask
        let trips = try await tripsTask
        let connectivity = try await connectivityTask
        let air = try await airTask
        let weather = try await weatherTask
        let location = try await locationTask
        let ampLimit = try await ampLimitTask

        let primaryReportedAt = battery?.timestamp?.date
        let extrasAreNewer = extras?.reportedAt.map { reported in
            primaryReportedAt.map { reported > $0 } ?? true
        } ?? false
        let batteryPercentage = extrasAreNewer
            ? (extras?.batteryPercentage ?? battery?.batteryChargeLevelPercentage?.value)
            : (battery?.batteryChargeLevelPercentage?.value ?? extras?.batteryPercentage)
        let range = extrasAreNewer
            ? (extras?.rangeKm ?? battery?.estimatedDistanceToEmptyKm?.value)
            : (battery?.estimatedDistanceToEmptyKm?.value ?? extras?.rangeKm)
        let primaryChargingState = battery?.chargingStatusV2.map {
            ChargingState(apiValue: $0.value)
        }
        let chargingState = extrasAreNewer
            ? (extras?.chargingState ?? primaryChargingState ?? .unknown("UNSPECIFIED"))
            : (primaryChargingState ?? extras?.chargingState ?? .unknown("UNSPECIFIED"))
        let minutes = extrasAreNewer
            ? (extras?.estimatedChargingTimeToFullMinutes ?? battery?.estimatedChargingTimeToFullMinutes?.value)
            : (battery?.estimatedChargingTimeToFullMinutes?.value ?? extras?.estimatedChargingTimeToFullMinutes)

        var warnings: [String] = []
        if response?.errors?.isEmpty == false { warnings.append(L10n.text("Some API fields were unavailable")) }
        if battery == nil && extras == nil { warnings.append(L10n.text("Battery data was unavailable")) }

        var optionalResults: [(AppFeature, Bool)] = [
            (.tyreAndWarnings, features.contains(.tyreAndWarnings) && c3Health.unavailable),


            (.vehicleHealth, features.contains(.vehicleHealth) && health == nil && c3Health.unavailable),
            (.tripMeters, trips.unavailable), (.connectivityDiagnostics, connectivity.unavailable),
            (.batteryDiagnostics, features.contains(.batteryDiagnostics) && extras == nil)
        ]
        if needsExterior {
            if features.contains(.exteriorStatus) { optionalResults.append((.exteriorStatus, exterior.unavailable)) }
            if features.contains(.remoteLocks) { optionalResults.append((.remoteLocks, exterior.unavailable)) }
            if features.contains(.remoteWindows) { optionalResults.append((.remoteWindows, exterior.unavailable)) }
        }
        if needsSoftware {
            if features.contains(.softwareUpdates) { optionalResults.append((.softwareUpdates, software.unavailable)) }
            if features.contains(.remoteOTA) { optionalResults.append((.remoteOTA, software.unavailable)) }
        }
        if needsSchedules {
            if features.contains(.chargingSchedule) { optionalResults.append((.chargingSchedule, schedules.unavailable)) }
            if features.contains(.remoteSchedules) { optionalResults.append((.remoteSchedules, schedules.unavailable)) }
        }
        if features.contains(.climateStatus) {
            optionalResults.append((.climateStatus, climate.unavailable && climateTimers.unavailable))
        }
        if features.contains(.remoteClimate) { optionalResults.append((.remoteClimate, climate.unavailable)) }
        if features.contains(.remoteSchedules) { optionalResults.append((.remoteSchedules, climateTimers.unavailable)) }
        if needsAirQuality {
            if features.contains(.airQuality) { optionalResults.append((.airQuality, air.unavailable)) }
            if features.contains(.remotePreCleaning) { optionalResults.append((.remotePreCleaning, air.unavailable)) }
        }
        if features.contains(.vehicleWeather) { optionalResults.append((.vehicleWeather, weather.unavailable)) }
        var seenUnavailable = Set<AppFeature>()
        let unavailable = optionalResults.compactMap { feature, failed in
            failed && seenUnavailable.insert(feature).inserted ? feature : nil
        }
        let c3ServiceHealth = features.contains(.vehicleHealth) ? c3Health.value : nil
        var probes = VehicleProbedCapabilities()
        if exterior.value != nil { probes.record(.exteriorStatus, as: .supported) }
        if let health = c3Health.value {
            probes.record(.serviceWarnings, as: .supported)
            if health.details.tyres.contains(where: { $0.kilopascals != nil }) {
                probes.record(.tyrePressureValues, as: .supported)
            }
        }
        if software.value != nil { probes.record(.softwareStatus, as: .supported) }
        if schedules.value != nil { probes.record(.chargingSchedule, as: .supported) }
        if climateTimers.value != nil { probes.record(.climateTimers, as: .supported) }
        if trips.value != nil { probes.record(.tripMeters, as: .supported) }
        if connectivity.value != nil { probes.record(.connectivity, as: .supported) }
        if chargeTarget != nil { probes.record(.chargeTarget, as: .supported) }
        if ampLimit.value != nil { probes.record(.chargingCurrentLimit, as: .supported) }

        var state = VehicleState(
            batteryPercentage: batteryPercentage,
            rangeKm: range,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: Self.positive(minutes),
            chargeTargetPercentage: chargeTarget,
            chargingPowerWatts: needsChargingContext ? Self.positive(extras?.chargingPowerWatts) : nil,
            chargingCurrentAmps: needsChargingContext
                ? (Self.positive(extras?.chargingCurrentAmps) ?? ampLimit.value) : nil,
            chargingVoltageVolts: needsChargingContext ? Self.positive(extras?.chargingVoltageVolts) : nil,
            chargingType: needsChargingContext ? (extras?.chargingType ?? .unknown) : .unknown,
            chargerConnection: needsChargingContext ? (extras?.chargerConnection ?? .unknown) : .unknown,
            availability: vehicleAvailability,


            modelName: modelName,
            modelYear: features.contains(.vehicleIdentity) ? modelYear : nil,
            registrationNo: features.contains(.vehicleIdentity) ? registrationNo : nil,
            vin: vin,
            ownerFirstName: features.contains(.ownerGreeting) ? ownerFirstName : nil,
            odometerKm: (odometer?.odometerMeters?.value).map { $0 / 1_000 }
                ?? (features.contains(.vehicleHealth) ? trips.value?.odometerKm : nil),
            daysToService: health?.daysToService?.value ?? c3ServiceHealth?.daysToService,
            distanceToServiceKm: health?.distanceToServiceKm?.value ?? c3ServiceHealth?.distanceToServiceKm,
            serviceWarning: Self.hasWarning(health?.serviceWarning) || (c3ServiceHealth?.serviceWarning ?? false),
            fluidWarnings: Self.fluidWarnings(health),
            exteriorStatus: exterior.value,
            healthDetails: features.contains(.tyreAndWarnings) ? (c3Health.value?.details ?? VehicleHealthDetails(
                tyres: TyrePosition.allCases.map { TyrePressure(position: $0, kilopascals: nil, warning: .none) },
                warnings: []
            )) : nil,
            softwareInfo: software.value,
            chargingSchedules: schedules.value ?? [],
            climateStatus: climate.value,
            climateTimers: climateTimers.value ?? [],
            tripMeterManualKm: trips.value?.manualTripKm,
            tripMeterAutomaticKm: trips.value?.automaticTripKm,
            connectivity: connectivity.value,
            airQuality: air.value,
            batteryDiagnostics: features.contains(.batteryDiagnostics) ? extras?.diagnostics : nil,
            weather: features.contains(.vehicleWeather) ? weather.value : nil,
            location: features.contains(.vehicleLocation) ? location.value : nil,
            unavailableFeatures: unavailable,
            probedCapabilities: probes.count > 0 ? probes : nil,
            imageData: features.contains(.vehicleImage) ? carImageData : nil,
            fetchedAt: Date(),
            vehicleReportedAt: [primaryReportedAt, extras?.reportedAt].compactMap { $0 }.max(),
            dataWarnings: warnings
        )
        state.structureWeek = features.contains(.vehicleIdentity) ? structureWeek : nil
        state.internalVehicleIdentifier = features.contains(.vehicleIdentity) ? internalVehicleIdentifier : nil
        state.pno34 = features.contains(.vehicleIdentity) ? pno34 : nil
        state.externalColour = features.contains(.vehicleIdentity) ? exteriorColorName : nil
        state.upholstery = features.contains(.vehicleIdentity) ? upholsteryName : nil
        state.wheels = features.contains(.vehicleIdentity) ? wheelsName : nil
        state.packages = features.contains(.vehicleIdentity) ? packageNames : []
        state.accountMarket = market
        return state
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        guard selectedVIN == vin, cars.contains(where: { $0.vin == vin }) else {
            throw RemoteCommandError.missingContext
        }
        guard !remoteCommandsInFlight.contains(vin) else { throw RemoteCommandError.busy }
        remoteCommandsInFlight.insert(vin)
        defer { remoteCommandsInFlight.remove(vin) }
        try await refreshTokenIfNeeded()
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let profile = VehicleCapabilityProfile(modelName: modelName, vin: vin)
        guard profile.permits(command.requiredCapability) else {
            throw RemoteCommandError.unsupported
        }
        let adaptedCommand = command.adapted(to: profile)
        let result = try await grpc.executeRemoteCommand(
            adaptedCommand, vin: vin, accessToken: token,
            commandToken: await validCommandToken()
        )
        if case .setChargeTarget(let target) = adaptedCommand { targetCache[vin] = (target, Date()) }
        logger.info("Remote command accepted: \(adaptedCommand.identifier, privacy: .public)")
        return result
    }

    static func telematicsQuery(features: FeatureSelection) -> String {
        let odometerSelection = features.contains(.vehicleHealth)
            ? "odometer { vin odometerMeters timestamp { seconds } }" : ""
        let healthSelection = features.contains(.vehicleHealth) ? """
            health {
              vin daysToService distanceToServiceKm serviceWarning
              brakeFluidLevelWarning engineCoolantLevelWarning oilLevelWarning
              timestamp { seconds }
            }
            """ : ""
        return """
        query CarTelematicsV2($vins: [String!]!) {
          carTelematicsV2(vins: $vins) {
            battery {
              vin batteryChargeLevelPercentage estimatedDistanceToEmptyKm
              chargingStatusV2 estimatedChargingTimeToFullMinutes
              timestamp { seconds }
            }
            \(odometerSelection)
            \(healthSelection)
          }
        }
        """
    }

    static func matchingReading<Value>(
        _ values: [Value]?,
        vin: String,
        vinOf: (Value) -> String?
    ) -> Value? {
        guard let values else { return nil }
        if let exact = values.first(where: { vinOf($0) == vin }) { return exact }


        guard values.count == 1, let only = values.first, vinOf(only) == nil else { return nil }
        return only
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

    private func discoverOIDCConfiguration() async throws {
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

    private func obtainAuthorizationCode(email: String, password: String,
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

    private func exchangeCode(_ code: String, verifier: String,
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

    private func exchangeCodeForToken(_ code: String, verifier: String) async throws {
        guard let tokenEndpoint else {
            throw PolestarError.authenticationRequired(.callbackRejected)
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody([
            "grant_type": "authorization_code",
            "client_id": oidcClientID,
            "code": code,
            "redirect_uri": oidcRedirectURL.absoluteString,
            "code_verifier": verifier
        ])
        let token = try await Self.requestToken(request: request, session: session,
                                                invalidReason: .callbackRejected)
        try apply(token)
    }

    private func refreshTokenIfNeeded() async throws {
        guard let expiry = tokenExpiry else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        if expiry.timeIntervalSinceNow < 300 { try await refreshAccessToken(force: false) }
    }

    private func refreshAccessToken(force: Bool) async throws {
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

    private static func requestToken(request: URLRequest, session: URLSession,
                                     invalidReason: AuthFailureReason) async throws -> TokenResponseDTO {
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: 256_000, operation: "token response"
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


    private func graphQL<Payload: Decodable>(query: String, variables: [String: Any]?,
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
                logger.error("""
                    Polestar \(operation, privacy: .public) returned an authentication error after \
                    token refresh: \(Self.errorSummary(errors), privacy: .public)
                    """)
                throw PolestarError.authenticationRequired(.expiredSession)
            }
            if decoded.data == nil, let errors = decoded.errors, !errors.isEmpty {
                logger.error("""
                    Polestar \(operation, privacy: .public) failed: \
                    \(Self.errorSummary(errors), privacy: .public)
                    """)
                throw PolestarError.graphQL(Self.mapErrors(errors), hasPartialData: false)
            }
            return decoded
        }
        throw PolestarError.authenticationRequired(.expiredSession)
    }

    private func fetchCarInfo(preferredVIN: String?) async throws {
        guard let token = accessToken else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        let query = """
        query GetConsumerCarsV2 {
          getConsumerCarsV2 { vin internalVehicleIdentifier modelName modelYear registrationNo pno34 structureWeek }
        }
        """
        var accountCars: [ConsumerCarDTO] = []
        var legacyCars: [ConsumerCarDTO] = []
        if let response: GraphQLResponse<ConsumerCarsPayloadDTO> = try? await graphQL(
            query: query, variables: nil, token: token, operation: "vehicle discovery"
        ) {
            legacyCars = response.data?.getConsumerCarsV2 ?? []
        }
        let vdmsCars = (try? await fetchAppBackendCars(token: accessToken ?? token)) ?? []
        if !vdmsCars.isEmpty {
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
        } else {
            accountCars = legacyCars
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
            return CarSummary(vin: vin, title: title.isEmpty ? vin : title)
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

    private func applyCarInfo(vin: String) async throws {
        guard accessToken != nil else {
            throw PolestarError.authenticationRequired(.expiredSession)
        }

        try await fetchCarInfo(preferredVIN: vin)
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

    private func fetchOwnerInfo() async {
        guard let token = accessToken, let userinfoEndpoint else { return }
        var request = URLRequest(url: userinfoEndpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await HTTPBodyReader.data(
                  for: request, using: session, limit: 256_000, operation: "user information"),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let info = try? JSONDecoder().decode(UserInfoDTO.self, from: data) else { return }
        ownerFirstName = info.givenName ?? info.firstName
        market = info.market?.isEmpty == false ? info.market : nil
    }

    private func fetchCarImage() async {
        let requestedAngle = await MainActor.run { Preferences.carRenderAngle.rawValue }
        if let vin = selectedVIN, let cached = CarImageCache.shared.image(for: vin, angle: requestedAngle) {
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
                  for: request, using: session, limit: 1_000_000, operation: "vehicle image metadata"),
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
                      for: URLRequest(url: url), using: session, limit: 5_000_000, operation: "vehicle image"),
                  let http = imageResponse as? HTTPURLResponse,
                  http.statusCode == 200,
                  http.mimeType?.hasPrefix("image/") == true,
                  bytes.count <= 5_000_000 {
                carImageData = bytes
                if let vin = selectedVIN {
                    let angle = (pick?["angle"] as? Int) ?? requestedAngle
                    CarImageCache.shared.save(bytes, for: vin, angle: angle)
                    CarImageCache.shared.save(bytes, for: vin)
                }
            }
        }

        if let vin = selectedVIN {
            for other in pool {
                guard let otherAngle = other["angle"] as? Int,
                      let otherUrlStr = other["url"] as? String,
                      let otherUrl = URL(string: otherUrlStr),
                      otherUrl.scheme == "https",
                      CarImageCache.shared.image(for: vin, angle: otherAngle) == nil else { continue }
                Task.detached { [session] in
                    guard let (otherBytes, otherResp) = try? await HTTPBodyReader.data(
                        for: URLRequest(url: otherUrl), using: session, limit: 5_000_000, operation: "vehicle angle image"),
                        (otherResp as? HTTPURLResponse)?.statusCode == 200,
                        otherBytes.count <= 5_000_000 else { return }
                    CarImageCache.shared.save(otherBytes, for: vin, angle: otherAngle)
                }
            }
        }
    }


    private func optionalBattery(enabled: Bool, vin: String, token: String) async throws -> GrpcBatteryExtras? {
        guard enabled else { return nil }
        do { return try await grpc.fetchBattery(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional live battery service unavailable")
            return nil
        }
    }

    private func optionalAvailability(enabled: Bool, vin: String, token: String) async throws -> VehicleAvailability {
        guard enabled else { return .unknown }
        do { return try await grpc.fetchAvailability(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional availability service unavailable")
            return .unknown
        }
    }

    private func targetSOC(enabled: Bool, vin: String, token: String) async throws -> Int? {
        guard enabled else { return nil }
        if let cached = targetCache[vin], Date().timeIntervalSince(cached.fetchedAt) < 900 {
            return cached.value
        }
        let value: Int?
        do { value = try await grpc.fetchTargetSoc(vin: vin, accessToken: token) }
        catch {
            if Self.isGlobalFailure(error) { throw error }
            logger.debug("Optional target SOC service unavailable")
            value = nil
        }
        targetCache[vin] = (value, Date())
        return value
    }

    private func optionalCapability<Value: Sendable>(
        _ feature: AppFeature,
        key: String? = nil,
        enabled: Bool,
        vin: String,
        operation: @Sendable () async throws -> Value?
    ) async throws -> OptionalCapability<Value> {
        guard enabled else { return OptionalCapability(value: nil, unavailable: false) }
        let cacheKey = key ?? feature.rawValue
        let scopedCacheKey = "\(vin)|\(cacheKey)"
        if let cached = capabilityCache[scopedCacheKey], cached.expiresAt > Date() {
            return OptionalCapability(value: cached.value as? Value, unavailable: false)
        }
        if let until = capabilityBackoff[vin]?[cacheKey], until > Date() {


            return OptionalCapability(value: nil, unavailable: false)
        }
        do {
            let value = try await operation()
            capabilityBackoff[vin]?[cacheKey] = nil
            capabilityCache[scopedCacheKey] = CapabilityCacheEntry(
                value: value,
                expiresAt: Date().addingTimeInterval(Self.capabilityCacheLifetime(feature, key: cacheKey))
            )
            return OptionalCapability(value: value, unavailable: false)
        } catch {
            if Self.isGlobalFailure(error) { throw error }
            let interval: TimeInterval
            if case PolestarError.incompatibleAPI = error { interval = 6 * 60 * 60 }
            else if case PolestarError.invalidResponse = error { interval = 60 * 60 }
            else { interval = 5 * 60 }
            capabilityBackoff[vin, default: [:]][cacheKey] = Date().addingTimeInterval(interval)
            logger.debug("Optional \(feature.rawValue, privacy: .public) capability unavailable")
            return OptionalCapability(value: nil, unavailable: true)
        }
    }


    private func perform(_ request: URLRequest, limit: Int = 2_000_000,
                         operation: String = "HTTP request") async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: limit, operation: operation
            )
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "HTTP request")
            }
            return (data, http)
        } catch let error as URLError {
            throw PolestarError.network(error)
        }
    }

    private func validateHTTP(_ response: HTTPURLResponse, operation: String = "request") throws {
        if let failure = PolestarError.httpFailure(
            statusCode: response.statusCode,
            retryAfter: Self.retryAfter(from: response),
            operation: operation
        ) { throw failure }
    }

    private func postForm(to url: URL, fields: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formBody(fields)
        return try await perform(request)
    }

    private func clearAccountState(keepRefreshToken: Bool = false) {
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

    private static func makeSession(delegate: URLSessionDelegate) -> URLSession {
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

    private static func formBody(_ fields: [String: String]) -> Data? {
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
    fileprivate static func normalizedPath(_ url: URL) -> String {
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

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
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

    private static func isGlobalFailure(_ error: Error) -> Bool {
        guard let error = error as? PolestarError else { return false }
        switch error {
        case .authenticationRequired, .rateLimited: return true
        default: return false
        }
    }

    private static func capabilityCacheLifetime(_ feature: AppFeature, key: String) -> TimeInterval {
        if key == "climate-status" || feature == .exteriorStatus || feature == .airQuality {
            return 10 * 60
        }
        return 60 * 60
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func hasWarning(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.contains("NO_WARNING") && !value.contains("UNSPECIFIED")
    }

    private static func fluidWarnings(_ health: HealthDTO?) -> [String] {
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

private final class OAuthRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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



