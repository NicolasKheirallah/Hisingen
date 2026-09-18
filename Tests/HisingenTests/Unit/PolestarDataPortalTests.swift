import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct PolestarDataPortalTests {

    // MARK: - Token Decoding Tests

    @Test
    func tokenResponseDecodesCorrectly() throws {
        let json = """
        {
            "accessToken": "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test-token",
            "expiresIn": 3600,
            "tokenType": "Bearer"
        }
        """
        let token = try JSONDecoder().decode(PolestarDataPortalTokenResponse.self, from: Data(json.utf8))
        #expect(token.accessToken == "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9.test-token")
        #expect(token.expiresIn == 3600)
        #expect(token.tokenType == "Bearer")
    }

    @Test
    func tokenErrorDecodesCorrectly() throws {
        let json = """
        {
            "error": "invalid_client",
            "error_description": "Invalid client credentials",
            "requestId": "req-12345",
            "timestamp": "2026-03-31T12:00:00Z"
        }
        """
        let errorDTO = try JSONDecoder().decode(PolestarDataPortalTokenError.self, from: Data(json.utf8))
        #expect(errorDTO.error == "invalid_client")
        #expect(errorDTO.errorDescription == "Invalid client credentials")
        #expect(errorDTO.requestId == "req-12345")
    }

    // MARK: - Vehicle Discovery Decoding Tests

    @Test
    func vehicleListDecodesArrayOfVins() throws {
        let json = """
        [
            "YSM12345678901234",
            "YSM98765432109876"
        ]
        """
        let vehicles = try JSONDecoder().decode(PolestarDataPortalVehiclesDTO.self, from: Data(json.utf8))
        #expect(vehicles.vins.count == 2)
        #expect(vehicles.vins.first == "YSM12345678901234")
    }

    @Test
    func vehicleListDecodesEnvelopeWithData() throws {
        let json = """
        {
            "data": [
                "YSM12345678901234"
            ]
        }
        """
        let vehicles = try JSONDecoder().decode(PolestarDataPortalVehiclesDTO.self, from: Data(json.utf8))
        #expect(vehicles.vins == ["YSM12345678901234"])
    }

    // MARK: - Battery Telemetry & Mapping Tests

    @Test
    func batteryTelemetryDecodesAndMapsToSnapshot() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "batteryChargeLevelPercentage": 78.5,
            "estimatedDistanceToEmptyKm": 420.0,
            "chargerConnectionStatus": "CONNECTED",
            "chargingStatus": "CHARGING",
            "chargingCurrentAmps": 16.0,
            "chargingVoltageVolts": 230.0,
            "chargingPowerWatts": 11000.0,
            "estimatedChargingTimeToFullMinutes": 45.0,
            "timestamp": {
                "seconds": "1774968000",
                "nanos": 500000000
            }
        }
        """
        let batteryDTO = try JSONDecoder().decode(PolestarDataPortalBatteryDTO.self, from: Data(json.utf8))
        #expect(batteryDTO.batteryChargeLevelPercentage == 78.5)
        #expect(batteryDTO.estimatedDistanceToEmptyKm == 420.0)
        #expect(batteryDTO.timestamp?.date != nil)

        let snapshot = batteryDTO.toEnergySnapshot()
        #expect(snapshot.batteryPercentage == 78.5)
        #expect(snapshot.rangeKm == 420)
        #expect(snapshot.connection == .connected)
        #expect(snapshot.chargingState == .charging)
        #expect(snapshot.currentAmps == 16)
        #expect(snapshot.powerWatts == 11000)
        #expect(snapshot.estimatedTimeToFullMinutes == 45)
    }

    // MARK: - Exterior Telemetry & Mapping Tests

    @Test
    func exteriorTelemetryDecodesAndMapsToSnapshot() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "centralLock": "LOCKED",
            "frontLeftDoor": "CLOSED",
            "frontRightDoor": "CLOSED",
            "rearLeftDoor": "CLOSED",
            "rearRightDoor": "OPEN",
            "hood": "CLOSED",
            "tailgate": "CLOSED",
            "frontLeftWindow": "CLOSED",
            "frontRightWindow": "OPEN",
            "rearLeftWindow": "CLOSED",
            "rearRightWindow": "CLOSED",
            "sunroof": "CLOSED",
            "timestamp": {
                "seconds": "1774968100",
                "nanos": 0
            }
        }
        """
        let exteriorDTO = try JSONDecoder().decode(PolestarDataPortalExteriorDTO.self, from: Data(json.utf8))
        let snapshot = exteriorDTO.toExteriorSnapshot()

        #expect(snapshot.isLocked == true)
        let openReadings = snapshot.openings.filter { $0.state == .open }.map(\.opening)
        #expect(openReadings.contains(.rearRightDoor))
        #expect(openReadings.contains(.frontRightWindow))
    }

    // MARK: - Health Telemetry & Mapping Tests

    @Test
    func healthTelemetryDecodesAndMapsToSnapshot() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "serviceWarning": "NORMAL",
            "daysToService": 120.0,
            "distanceToServiceKm": 15000.0,
            "brakeFluidLevelWarning": "NORMAL",
            "washerFluidLevelWarning": "LOW_WARNING",
            "frontLeftTyrePressureKpa": 260.0,
            "frontLeftTyrePressureWarning": "NORMAL",
            "rearRightTyrePressureKpa": 190.0,
            "rearRightTyrePressureWarning": "LOW_PRESSURE_WARNING",
            "timestamp": {
                "seconds": "1774968200",
                "nanos": 0
            }
        }
        """
        let healthDTO = try JSONDecoder().decode(PolestarDataPortalHealthDTO.self, from: Data(json.utf8))
        let snapshot = healthDTO.toMaintenanceSnapshot()

        #expect(snapshot.service.daysToService == 120)
        #expect(snapshot.service.distanceToServiceKm == 15000)
        #expect(snapshot.service.fluidWarnings.contains("Washer Fluid"))

        let details = try #require(snapshot.details)
        #expect(details.tyres.count == 4)

        let rearRight = details.tyres.first(where: { $0.position == .rearRight })
        #expect(rearRight?.warning == .low)
        #expect(details.warnings.contains(.tyrePressure))
    }

    // MARK: - Availability Telemetry Tests

    @Test
    func availabilityTelemetryDecodesCorrectly() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "availabilityStatus": "AVAILABLE",
            "timestamp": {
                "seconds": "1774968300",
                "nanos": 0
            }
        }
        """
        let availDTO = try JSONDecoder().decode(PolestarDataPortalAvailabilityDTO.self, from: Data(json.utf8))
        #expect(availDTO.availabilityStatus == "AVAILABLE")
        #expect(availDTO.timestamp?.date != nil)
    }

    // MARK: - Error Mapping Tests

    @Test
    func errorMappingConvertsToVehicleServiceError() {
        let unauth = PolestarDataPortalError.authenticationRequired(.invalidCredentials)
        #expect(unauth.requiresAuthentication == true)
        #expect(unauth.isRejectedCredential == true)

        let mapped = unauth.asVehicleServiceError
        if case .authenticationRequired(let provider, let reason) = mapped {
            #expect(provider == .polestar)
            #expect(reason == .invalidCredentials)
        } else {
            Issue.record("Expected authenticationRequired error")
        }

        let rateLimit = PolestarDataPortalError.rateLimited(retryAfter: 60)
        if case .rateLimited(let retry) = rateLimit.asVehicleServiceError {
            #expect(retry == 60)
        } else {
            Issue.record("Expected rateLimited error")
        }

        let generalServiceMap = VehicleServiceError.map(unauth, provider: .polestar)
        if case .authenticationRequired(let provider, _) = generalServiceMap {
            #expect(provider == .polestar)
        } else {
            Issue.record("Expected mapped authenticationRequired error")
        }
    }

    // MARK: - Provider Registry Dynamic Resolution Tests

    @Test
    @MainActor
    func providerRegistrySwitchesBasedOnPolestarConnectionMode() async throws {
        let suite = "io.kheirallah.hisingen.portal.registry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)

        let polestarDefault = PortalTestProbeProvider(brand: .polestar, name: "default")
        let polestarPortal = PortalTestProbeProvider(brand: .polestar, name: "portal")
        let volvo = PortalTestProbeProvider(brand: .volvo, name: "volvo")

        let registry = ProviderRegistry(
            polestar: polestarDefault,
            polestarDataPortal: polestarPortal,
            volvo: volvo,
            preferences: preferences
        )

        // Default mode is .polestarID
        preferences.polestarConnectionMode = .polestarID
        let active1 = registry.provider(for: .polestar)
        let cars1 = await active1.cars
        #expect(cars1.first?.vin == "default")

        // Switch mode to .dataPortal
        preferences.polestarConnectionMode = .dataPortal
        let active2 = registry.provider(for: .polestar)
        let cars2 = await active2.cars
        #expect(cars2.first?.vin == "portal")

        // Volvo is unaffected
        let volvoCars = await registry.provider(for: .volvo).cars
        #expect(volvoCars.first?.vin == "volvo")
    }

    // MARK: - Keychain Isolation Tests

    @Test
    func keychainStoresAndReadsDataPortalCredentials() throws {
        let service = "io.kheirallah.hisingen.tests.portal.\(UUID().uuidString)"
        let store = KeychainStore(service: service)

        #expect(store.hasStoredPolestarDataPortalCredentials == false)

        try store.savePolestarDataPortalCredentials(accountID: "test-account-id", clientID: "test-client-id", clientSecret: "test-client-secret")
        #expect(try store.readPolestarDataPortalAccountID() == "test-account-id")
        #expect(try store.readPolestarDataPortalClientID() == "test-client-id")
        #expect(try store.readPolestarDataPortalClientSecret() == "test-client-secret")
        #expect(store.hasStoredPolestarDataPortalCredentials == true)

        try store.savePolestarDataPortalToken("test-portal-token")
        #expect(try store.readPolestarDataPortalToken() == "test-portal-token")

        try store.deletePolestarDataPortalToken()
        #expect(try store.readPolestarDataPortalToken() == nil)

        try store.deletePolestarDataPortalCredentials()
        #expect(try store.readPolestarDataPortalAccountID() == nil)
        #expect(try store.readPolestarDataPortalClientID() == nil)
        #expect(try store.readPolestarDataPortalClientSecret() == nil)
        #expect(store.hasStoredPolestarDataPortalCredentials == false)
    }

    @Test
    func credentialsDoNotConflictBetweenConsumerAndDataPortal() throws {
        let service = "io.kheirallah.hisingen.tests.portal.no-conflict.\(UUID().uuidString)"
        let store = KeychainStore(service: service)

        try store.savePassword("consumer-password-123")
        try store.saveSessionToken("consumer-session-token")
        try store.savePolestarDataPortalCredentials(
            accountID: "portal-account-id",
            clientID: "portal-client-id",
            clientSecret: "portal-client-secret"
        )

        #expect(try store.readPassword() == "consumer-password-123")
        #expect(try store.readSessionToken() == "consumer-session-token")
        #expect(try store.readPolestarDataPortalAccountID() == "portal-account-id")
        #expect(try store.readPolestarDataPortalClientID() == "portal-client-id")

        try store.deletePassword()
        try store.deleteSessionToken()
        #expect(try store.readPassword() == nil)
        #expect(try store.readSessionToken() == nil)
        #expect(try store.readPolestarDataPortalClientID() == "portal-client-id")
        #expect(store.hasStoredPolestarDataPortalCredentials == true)

        try store.deletePolestarDataPortalCredentials()
    }


    // MARK: - Odometer & Location Telemetry Tests

    @Test
    func odometerTelemetryDecodesAndCalculatesKm() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "odometerMeters": 42150800,
            "tripMeterManualKm": 96.5,
            "averageSpeedKmPerHour": 38.0,
            "timestamp": { "seconds": "1774968000", "nanos": 0 }
        }
        """
        let odoDTO = try JSONDecoder().decode(PolestarOdometerDTO.self, from: Data(json.utf8))
        #expect(odoDTO.odometerMeters == 42150800)
        #expect(odoDTO.calculatedOdometerKm == 42151)
        #expect(odoDTO.tripMeterManualKm == 96.5)
    }

    @Test
    func locationTelemetryDecodesAndMapsToVehicleLocation() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "coordinate": { "latitude": 57.7089, "longitude": 11.9746 },
            "heading": 180.0,
            "speed": "90.0",
            "altitude": "35.0"
        }
        """
        let locDTO = try JSONDecoder().decode(PolestarLocationDTO.self, from: Data(json.utf8))
        #expect(locDTO.latitude == 57.7089)
        #expect(locDTO.longitude == 11.9746)

        let vehicleLoc = locDTO.toVehicleLocation()
        #expect(vehicleLoc.latitude == 57.7089)
        #expect(vehicleLoc.longitude == 11.9746)
        #expect(vehicleLoc.speed == 90.0) // wire speed is already km/h
        #expect(vehicleLoc.heading == 180.0)
        #expect(vehicleLoc.altitudeMeters == 35.0)
    }

    // MARK: - Daily Quota Tracking Tests

    @Test
    func dailyQuotaTracksAndRollsOverAcrossDays() {
        PolestarDataPortalAPI.resetDailyQuotaForTesting()
        #expect(PolestarDataPortalAPI.dailyCallLimit == 10_000)
        #expect(PolestarDataPortalAPI.dailyCallCount == 0)

        // Simulate 42 calls today
        PolestarDataPortalAPI.setDailyQuotaForTesting(count: 42, date: Date())
        #expect(PolestarDataPortalAPI.dailyCallCount == 42)

        // Simulate calls from yesterday (should rollover to 0)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        PolestarDataPortalAPI.setDailyQuotaForTesting(count: 99, date: yesterday)
        #expect(PolestarDataPortalAPI.dailyCallCount == 0)

        PolestarDataPortalAPI.resetDailyQuotaForTesting()
    }

    // MARK: - Command Catalog & Read-Only Gating Tests

    @Test
    func providerCommandCatalogDataPortalCommands() {
        let portalCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .dataPortal)
        #expect(portalCatalog.implements(.lock) == false)
        #expect(portalCatalog.implements(.unlock) == false)
        #expect(portalCatalog.implements(.openWindows) == false)
        #expect(portalCatalog.implements(.stopClimate) == true)
        #expect(portalCatalog.implements(.startPreCleaning) == true)
        #expect(portalCatalog.implements(.setChargeTarget(80)) == true)
        #expect(portalCatalog.implements(.setAmpLimit(16)) == true)
        #expect(portalCatalog.implements(.startChargingOverride) == true)

        let consumerCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID)
        #expect(consumerCatalog.implements(.lock) == true)
        #expect(consumerCatalog.implements(.stopClimate) == true)
    }

    @Test
    func dataPortalCatalogCoversSchedulesAndChargeLocations() {
        let portalCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .dataPortal)
        #expect(portalCatalog.implements(.setGlobalChargeTimer(
            VehicleSchedule(kind: .globalCharging, startHour: 23, startMinute: 0, endHour: 6, endMinute: 0, weekdays: [.monday], isActive: true))))
        #expect(portalCatalog.implements(.setClimateTimer(
            VehicleSchedule(kind: .climate, startHour: 7, startMinute: 30, endHour: nil, endMinute: nil, isActive: true))))
        #expect(portalCatalog.implements(.deleteClimateTimer(id: "t1")))
        #expect(portalCatalog.implements(.createChargeLocationAtCar(alias: "Work", ampLimit: 16, minimumSoc: 60, optimisedCharging: false)))
        #expect(portalCatalog.implements(.updateChargeLocationAlias(id: "l1", alias: "Work")))
        #expect(portalCatalog.implements(.updateChargeLocationAmpLimit(id: "l1", amps: 10)))
        #expect(portalCatalog.implements(.updateChargeLocationMinimumSoc(id: "l1", soc: 70)))
        #expect(portalCatalog.implements(.setChargeLocationOptimisedCharging(id: "l1", enabled: true)))
        #expect(portalCatalog.implements(.deleteChargeLocation(id: "l1")))
        #expect(!portalCatalog.implements(.honkAndFlash))
        #expect(!portalCatalog.implements(.unlockTrunk))
        #expect(!portalCatalog.implements(.scheduleOTA(delayMinutes: 5)))
        // Bare catalogs default to consumer mode so parallel suites never inherit portal gating.
        #expect(ProviderCommandCatalog(brand: .polestar).polestarConnectionMode == .polestarID)
    }

    @Test
    func commandAvailabilityExplainsDataPortalReadonly() {
        // Isolated catalog + gate: mutating PreferencesStore.shared here would leak the
        // dataPortal mode into suites running concurrently in this process.
        let state = VehicleState(
            energy: EnergyAndChargingSnapshot(),
            identity: VehicleIdentitySnapshot(availability: .available, modelName: "Polestar 2", vin: "TESTVIN"),
            freshness: SnapshotFreshness(fetchedAt: Date())
        )
        let gate = CapabilityGate()
        let availability = gate.availability(
            for: .lock, state: state,
            commandCatalog: ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .dataPortal),
            enabledFeatures: [.remoteLocks], commandInProgress: false)
        guard case .unimplementedByProvider(let reason) = availability else {
            Issue.record("Expected unimplementedByProvider in Developer Portal mode, got \(availability)")
            return
        }
        #expect(reason?.contains("Developer Portal") == true)
        // The reason-less payload keeps the generic service-level wording.
        #expect(CommandAvailability.unimplementedByProvider().shortReason?.contains("Not available") == true)
    }

    // MARK: - API VehicleProviding Conformance Tests

    @Test
    @MainActor
    func apiRemoteCommandsAreUnsupported() async throws {
        let api = PolestarDataPortalAPI()
        await #expect(throws: RemoteCommandError.unsupported) {
            try await api.executeRemoteCommand(.lock, vin: "YSM12345678901234")
        }
    }

    @Test
    @MainActor
    func apiExecuteRemoteCommandsActuatesSupportedEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PortalMockTransport.self]
        let session = URLSession(configuration: config)

        let api = PolestarDataPortalAPI()
        await api.setSessionForTesting(session)
        await api.setAccessTokenForTesting("test-token")
        await api.configure(clientID: "client-id", clientSecret: "client-secret")

        var lastMethod = ""
        var lastPath = ""
        var lastBody: Data?
        defer { PortalMockTransport.requestHandler = nil }
        PortalMockTransport.requestHandler = { req in
            lastMethod = req.httpMethod ?? ""
            lastPath = req.url?.path ?? ""
            lastBody = portalRequestBody(req)
            return (200, Data("{}".utf8))
        }

        // Climate - level 1 steering wheel turns ON
        let climateResult = try await api.executeRemoteCommand(
            .startClimate(temperatureCelsius: 21.0, frontLeftSeat: .level2, frontRightSeat: .off, rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .level1),
            vin: "TESTVIN"
        )
        #expect(climateResult.outcome == .accepted)
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/telemetry/parking-climatization"))
        let onBody = try JSONSerialization.jsonObject(with: #require(lastBody)) as? [String: Any]
        #expect(onBody?["steeringWheelHeating"] as? String == "ON")

        // Climate - unspecified steering wheel turns OFF (does not inadvertently activate)
        _ = try await api.executeRemoteCommand(
            .startClimate(temperatureCelsius: 21.0, frontLeftSeat: .unspecified, frontRightSeat: .unspecified, rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified),
            vin: "TESTVIN"
        )
        let offBody = try JSONSerialization.jsonObject(with: #require(lastBody)) as? [String: Any]
        #expect(offBody?["steeringWheelHeating"] as? String == "OFF")

        let stopClimateResult = try await api.executeRemoteCommand(.stopClimate, vin: "TESTVIN")
        #expect(stopClimateResult.outcome == .completed)
        #expect(lastMethod == "DELETE")
        #expect(lastPath.contains("/telemetry/parking-climatization"))

        // Pre-cleaning
        let startCleanResult = try await api.executeRemoteCommand(.startPreCleaning, vin: "TESTVIN")
        #expect(startCleanResult.outcome == .accepted)
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/telemetry/pre-cleaning"))

        let stopCleanResult = try await api.executeRemoteCommand(.stopPreCleaning, vin: "TESTVIN")
        #expect(stopCleanResult.outcome == .completed)
        #expect(lastMethod == "DELETE")
        #expect(lastPath.contains("/telemetry/pre-cleaning"))

        // Target SoC
        let socResult = try await api.executeRemoteCommand(.setChargeTarget(85), vin: "TESTVIN")
        #expect(socResult.outcome == .accepted)
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/target-soc"))

        // Amp Limit
        let ampResult = try await api.executeRemoteCommand(.setAmpLimit(16), vin: "TESTVIN")
        #expect(ampResult.outcome == .accepted)
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/amp-limit"))

        // Override timer
        let overrideStartResult = try await api.executeRemoteCommand(.startChargingOverride, vin: "TESTVIN")
        #expect(overrideStartResult.outcome == .accepted)
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/override-charge-timer"))

        let overrideStopResult = try await api.executeRemoteCommand(.stopChargingOverride, vin: "TESTVIN")
        #expect(overrideStopResult.outcome == .completed)
        #expect(lastMethod == "DELETE")
        #expect(lastPath.contains("/charging/override-charge-timer"))
    }

    @Test
    @MainActor
    func apiFetchVehicleStateAssemblesAll15Endpoints() async throws {
        func fixtureData(named name: String) throws -> Data {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PortalMockTransport.self]
        let session = URLSession(configuration: config)

        let api = PolestarDataPortalAPI()
        await api.setSessionForTesting(session)
        await api.setAccessTokenForTesting("test-token")
        await api.configure(clientID: "client-id", clientSecret: "client-secret")

        let batteryData = try fixtureData(named: "polestar-portal-battery")
        let exteriorData = try fixtureData(named: "polestar-portal-exterior")
        let healthData = try fixtureData(named: "polestar-portal-health")
        let availData = try fixtureData(named: "polestar-portal-availability")
        let odoData = try fixtureData(named: "polestar-portal-odometer")
        let locData = try fixtureData(named: "polestar-portal-location")
        let climData = try fixtureData(named: "polestar-portal-telemetry-parking-climatization")
        let cleanData = try fixtureData(named: "polestar-portal-telemetry-pre-cleaning")
        let socData = try fixtureData(named: "polestar-portal-charging-target-soc")
        let ampData = try fixtureData(named: "polestar-portal-charging-amp-limit")
        let locsData = try fixtureData(named: "polestar-portal-charging-charge-locations")
        let isAtData = try fixtureData(named: "polestar-portal-charging-is-at-charge-location")
        let timerData = try fixtureData(named: "polestar-portal-charging-global-charge-timer")
        let chargeNowData = try fixtureData(named: "polestar-portal-charging-charge-now")
        let climTimerData = try fixtureData(named: "polestar-portal-charging-parking-climate-timer")

        PortalMockTransport.requestHandler = { req in
            let path = req.url?.path ?? ""
            if path.contains("/telemetry/battery") { return (200, batteryData) }
            if path.contains("/telemetry/exterior") { return (200, exteriorData) }
            if path.contains("/telemetry/health") { return (200, healthData) }
            if path.contains("/telemetry/availability") { return (200, availData) }
            if path.contains("/telemetry/odometer") { return (200, odoData) }
            if path.contains("/telemetry/location") { return (200, locData) }
            if path.contains("/telemetry/parking-climatization") { return (200, climData) }
            if path.contains("/telemetry/pre-cleaning") { return (200, cleanData) }
            if path.contains("/charging/target-soc") { return (200, socData) }
            if path.contains("/charging/amp-limit") { return (200, ampData) }
            if path.contains("/charging/charge-locations") { return (200, locsData) }
            if path.contains("/charging/is-at-charge-location") { return (200, isAtData) }
            if path.contains("/charging/global-charge-timer") { return (200, timerData) }
            if path.contains("/charging/charge-now") { return (200, chargeNowData) }
            if path.contains("/charging/parking-climate-timer") { return (200, climTimerData) }
            return (404, Data())
        }

        let state = try await api.fetchVehicleState(
            vin: "YSMVSEDE6PL147228",
            features: FeatureSelection(enabled: Set(AppFeature.allCases))
        )

        #expect(state.energy.batteryPercentage == 78.5)
        #expect(state.energy.chargingState == .charging)
        #expect(state.energy.targetPercentage == 80)
        #expect(state.energy.currentLimitAmps == 16)
        #expect(state.energy.locations.count == 1)
        #expect(state.energy.isAtChargeLocation == true)
        // The is-at state only carries a locationId; assembly joins it against the
        // charge-locations list to recover the display name.
        #expect(state.energy.currentChargeLocationName == "Home Garage")
        #expect(state.energy.arrivedAtLocationDate == Date(timeIntervalSince1970: 1_716_299_100))
        #expect(state.energy.chargeNowActive == true)
        // The vehicle-level capability flags join from the charge-locations list even when
        // the is-at read and the battery frame disagree about who fetched first.
        #expect(state.energy.diagnostics?.isBidirectionalChargingEnabled == false)
        #expect(state.energy.diagnostics?.isOptimizedChargingEnabled == true)
        #expect(state.energy.schedules.count == 1)
        #expect(state.climateStatus?.activity == .active)
        #expect(state.climateStatus?.timeRemainingMinutes == 18)
        #expect(state.climateStatus?.requestedTemperatureCelsius == 21.0)
        #expect(state.climateStatus?.driverSeatHeatingLevel == 2)
        #expect(state.climateStatus?.steeringWheelHeatingLevel == 1)
        #expect(state.airQuality?.cleaningState == .off)
        #expect(state.airQuality?.airQualityIndex == 25)
        #expect(state.climateTimers.count == 1)
        #expect(state.maintenance.odometerKm == 42151)
        #expect(state.location?.latitude == 57.708870)
        #expect(state.exteriorStatus?.isLocked == true)
        // ARMED is not an alarm event; only the spec's TRIGGERED spelling is.
        #expect(state.exteriorStatus?.alarmTriggered == false)
        #expect(state.identity.usageMode == "INACTIVE")
        #expect(state.tripComputer.manualTripKm == 128.4)
        #expect(state.tripComputer.automaticTripKm == 42102.1)
        #expect(state.tripComputer.sinceChargeTripKm == 96.7)
        #expect(state.tripComputer.manualAverageSpeedKmH == 34)
        #expect(state.tripComputer.automaticAverageSpeedKmH == 41)
        #expect(state.tripComputer.sinceChargeAverageSpeedKmH == 52)
        #expect(state.energy.diagnostics?.energyAvailableIncreaseKwh == 5.2)
        #expect(state.energy.diagnostics?.batteryPreconditioningStatus == "ACTIVE")
        #expect(state.energy.diagnostics?.batteryPreconditioningEndsAt == Date(timeIntervalSince1970: 1_716_300_800))
    }

    @Test
    @MainActor
    func apiFetchVehicleStateAlarmIdleIsNotTriggered() async throws {
        // The shared exterior mapper reads any value containing "ALARM" as an event;
        // assembly must re-derive the flag so spec value ALARM_STATUS_IDLE stays false.
        let exteriorJSON = """
        {
          "data": {
            "vin": "TESTVIN",
            "timestamp": { "seconds": "1716300100", "nanos": 0 },
            "centralLock": "LOCKED",
            "alarm": "ALARM_STATUS_IDLE",
            "frontLeftDoor": "CLOSED",
            "frontRightDoor": "CLOSED",
            "rearLeftDoor": "CLOSED",
            "rearRightDoor": "CLOSED",
            "hood": "CLOSED",
            "tailgate": "CLOSED"
          },
          "meta": { "vin": "TESTVIN", "domain": "exterior" }
        }
        """
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PortalMockTransport.self]
        let session = URLSession(configuration: config)

        let api = PolestarDataPortalAPI()
        await api.setSessionForTesting(session)
        await api.setAccessTokenForTesting("test-token")
        await api.configure(clientID: "client-id", clientSecret: "client-secret")

        PortalMockTransport.requestHandler = { req in
            if req.url?.path.contains("/telemetry/exterior") == true { return (200, Data(exteriorJSON.utf8)) }
            return (404, Data())
        }

        let state = try await api.fetchVehicleState(
            vin: "TESTVIN",
            features: FeatureSelection(enabled: [.exteriorStatus])
        )
        #expect(state.exteriorStatus?.alarmTriggered == false)
    }

    // MARK: - Deep Telemetry & Augmented Mode Tests

    @Test
    func batteryTelemetryDecodesEnergyBreakdownAndPowerLimits() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "batteryChargeLevelPercentage": 75.0,
            "estimatedDistanceToEmptyKm": 350.0,
            "chargingStatus": "CHARGING_STATUS_IDLE",
            "chargerConnectionStatus": "CHARGER_CONNECTION_STATUS_CONNECTED",
            "chargingType": "CHARGING_TYPE_AC",
            "chargerPowerStatus": "CHARGER_POWER_STATUS_PROVIDING_POWER",
            "dischargeInfo": {
                "powerLimit": 220.0,
                "energyAvailable": 65.5
            },
            "energyConsumptionWhSinceCharge": {
                "driving": 12000.0,
                "climate": 2500.0,
                "battery": 1800.0,
                "other": 700.0
            },
            "energyConsumptionPercentageSinceCharge": {
                "driving": 70.0,
                "climate": 15.0,
                "battery": 11.0,
                "other": 4.0
            }
        }
        """
        let dto = try JSONDecoder().decode(PolestarBatteryDTO.self, from: Data(json.utf8))
        let snapshot = dto.toEnergySnapshot()
        #expect(snapshot.diagnostics?.powerLimitKw == 220.0)
        #expect(snapshot.diagnostics?.energyAvailableKwh == 65.5)
        #expect(snapshot.diagnostics?.energyBreakdown?.hasData == true)
        #expect(snapshot.diagnostics?.energyBreakdown?.driving?.wattHours == 12000.0)
        #expect(snapshot.diagnostics?.energyBreakdown?.driving?.percentage == 70.0)
        #expect(snapshot.diagnostics?.energyBreakdown?.climate?.wattHours == 2500.0)
        #expect(snapshot.diagnostics?.energyBreakdown?.battery?.percentage == 11.0)
    }

    @Test
    func healthTelemetryDecodesReferenceTyrePressures() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "frontLeftTyrePressureKpa": 275.0,
            "frontRightTyrePressureKpa": 280.0,
            "rearLeftTyrePressureKpa": 285.0,
            "rearRightTyrePressureKpa": 282.0,
            "frontTyresReferencePressureKpa": 280.0,
            "rearTyresReferencePressureKpa": 290.0,
            "frontLeftTyrePressureWarning": "TYRE_PRESSURE_WARNING_NONE"
        }
        """
        let dto = try JSONDecoder().decode(PolestarHealthDTO.self, from: Data(json.utf8))
        let snapshot = dto.toMaintenanceSnapshot()
        let frontLeft = snapshot.details?.tyres.first(where: { $0.position == .frontLeft })
        let rearRight = snapshot.details?.tyres.first(where: { $0.position == .rearRight })
        #expect(frontLeft?.kilopascals == 275.0)
        #expect(frontLeft?.referenceKilopascals == 280.0)
        #expect(rearRight?.kilopascals == 282.0)
        #expect(rearRight?.referenceKilopascals == 290.0)
    }

    @Test
    func chargerConnectionDisconnectedDecodesAsDisconnected() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "batteryChargeLevelPercentage": 75.0,
            "chargerConnectionStatus": "CHARGER_CONNECTION_STATUS_DISCONNECTED",
            "chargerPowerStatus": "CHARGER_POWER_STATUS_NO_POWER_AVAILABLE",
            "chargingStatusV2": "CHARGING_STATUS_V2_IDLE"
        }
        """
        let dto = try JSONDecoder().decode(PolestarBatteryDTO.self, from: Data(json.utf8))
        let snapshot = dto.toEnergySnapshot()
        #expect(snapshot.connection == .disconnected)
        #expect(snapshot.diagnostics?.chargerPowerState == .noPower)
    }

    @Test
    func modernV2ChargingStatusesDecodeCorrectly() {
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_CHARGE_LEVEL_IS_GOOD_TO_GO") == .complete)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_CHARGING_TOWARDS_MIN_SOC") == .charging)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_CHARGING_IS_EN_ROUTE") == .charging)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_SCHEDULED_CHARGING_WILL_COMPLETE") == .scheduled)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_SCHEDULED_CHARGING_CANNOT_COMPLETE") == .scheduled)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_DISCHARGING_V2H") == .discharging)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_DISCHARGING_V2L") == .discharging)
        #expect(ChargingState(apiValue: "CHARGING_STATUS_V2_SMART_CHARGING_WILL_NOT_FINISH") == .smartCharging)
    }

    @Test
    func dailyTimeAdjustsUtc0ToLocalTimezone() {
        let utcDailyTime = PolestarDailyTimeDTO(hour: 6, minute: 30, timeZone: nil)
        let gmtPlus2 = TimeZone(secondsFromGMT: 7200)!
        #expect(utcDailyTime.localHour(isUtc0: true, timeZone: gmtPlus2) == 8)
        #expect(utcDailyTime.localMinute(isUtc0: true, timeZone: gmtPlus2) == 30)
        #expect(utcDailyTime.localHour(isUtc0: false, timeZone: gmtPlus2) == 6)
    }

    @Test
    func timerSettingsDecodesAndPropagatesComfortPreferences() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "parkingClimateTimers": [],
            "timerSettings": {
                "seatHeatingIntensity": {
                    "frontRowLeftSeat": "I_LEVEL2",
                    "frontRowRightSeat": "I_LEVEL1",
                    "rearRowLeftSeat": "I_OFF",
                    "rearRowRightSeat": "I_LEVEL3"
                },
                "steeringWheelHeatingIntensity": "I_LEVEL2",
                "requestedCompartmentTemperatureCelsius": 22.5,
                "isCompartmentTemperatureRequested": true,
                "batteryPreconditioning": "BP_WHEN_PLUGGED"
            }
        }
        """
        let dto = try JSONDecoder().decode(PolestarParkingClimateTimerDTO.self, from: Data(json.utf8))
        let settings = try #require(dto.timerSettings)
        #expect(settings.requestedCompartmentTemperatureCelsius == 22.5)
        #expect(settings.batteryPreconditioning == "BP_WHEN_PLUGGED")
        #expect(settings.steeringWheelHeatingIntensity == "I_LEVEL2")
        #expect(settings.seatHeatingIntensity?.frontRowLeftSeat == "I_LEVEL2")
    }

    @Test
    @MainActor
    func augmentedModeEnablesRemoteCommandsInCommandCatalog() {
        let catalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .augmented)
        #expect(catalog.implements(.lock) == true)
        #expect(catalog.implements(.unlock) == true)
        #expect(catalog.implements(ClimateControlCard.probe) == true)
        #expect(catalog.implements(.stopClimate) == true)
    }

    @Test
    @MainActor
    func augmentedProviderDelegatesTelemetryAndCommands() async throws {
        let telemetry = PortalTestProbeProvider(brand: .polestar, name: "telemetry-portal")
        let commands = PortalTestProbeProvider(brand: .polestar, name: "commands-consumer")
        let augmented = PolestarAugmentedProvider(telemetryProvider: telemetry, commandProvider: commands)

        let cars = await augmented.cars
        #expect(cars.first?.vin == "telemetry-portal")

        let warm = await augmented.hasWarmSession
        #expect(warm == true)
    }

    @Test
    @MainActor
    func augmentedProviderFallsBackToCommandProviderOnTelemetryError() async throws {
        let dummyState = VehicleState(
            batteryPercentage: 60,
            rangeKm: 250,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: nil,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .ac,
            chargerConnection: .connected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ABC 123",
            vin: "P2-FALLBACK",
            ownerFirstName: nil,
            odometerKm: nil,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: nil,
            dataWarnings: []
        )
        let telemetry = PortalTestProbeProvider(brand: .polestar, name: "telemetry-portal", shouldFailState: true)
        let commands = PortalTestProbeProvider(brand: .polestar, name: "commands-consumer", state: dummyState)
        let augmented = PolestarAugmentedProvider(telemetryProvider: telemetry, commandProvider: commands)

        let state = try await augmented.fetchVehicleState(vin: "P2-FALLBACK", features: .default)
        #expect(state.identity.vin == "P2-FALLBACK")
        #expect(state.energy.batteryPercentage == 60)
    }

    @Test
    @MainActor
    func augmentedProviderRestoresSessionWhenAtLeastOneProviderSucceeds() async throws {
        let failingTelemetry = PortalTestProbeProvider(
            brand: .polestar, name: "telemetry", shouldFailRestore: true, warm: false
        )
        let workingConsumer = PortalTestProbeProvider(
            brand: .polestar, name: "consumer", shouldFailRestore: false, warm: true
        )
        let augmented = PolestarAugmentedProvider(
            telemetryProvider: failingTelemetry, commandProvider: workingConsumer
        )

        try await augmented.restoreSession(token: "test-token", preferredVIN: "VIN1", features: FeatureSelection.default)
        let isWarm = await augmented.hasWarmSession
        #expect(isWarm == true)
    }

    @Test
    @MainActor
    func augmentedProviderThrowsWhenBothProvidersFailToRestore() async throws {
        let telemetry = PortalTestProbeProvider(brand: .polestar, name: "telemetry", shouldFailRestore: true, warm: false)
        let consumer = PortalTestProbeProvider(brand: .polestar, name: "consumer", shouldFailRestore: true, warm: false)
        let augmented = PolestarAugmentedProvider(telemetryProvider: telemetry, commandProvider: consumer)

        await #expect(throws: VehicleServiceError.self) {
            try await augmented.restoreSession(token: "test-token", preferredVIN: "VIN1", features: FeatureSelection.default)
        }
    }

    @Test
    @MainActor
    func augmentedProviderFallsBackToConsumerWhenTelemetryHasEmptyBattery() async throws {
        let emptyState = VehicleState(
            batteryPercentage: nil,
            rangeKm: nil,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: nil,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            vin: "P2-EMPTY",
            ownerFirstName: nil,
            odometerKm: nil,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: nil,
            dataWarnings: []
        )
        let fallbackState = VehicleState(
            batteryPercentage: 75,
            rangeKm: 320,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .ac,
            chargerConnection: .connected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: nil,
            vin: "P2-EMPTY",
            ownerFirstName: nil,
            odometerKm: nil,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: nil,
            dataWarnings: []
        )
        let telemetry = PortalTestProbeProvider(brand: .polestar, name: "telemetry-portal", state: emptyState)
        let commands = PortalTestProbeProvider(brand: .polestar, name: "commands-consumer", state: fallbackState)
        let augmented = PolestarAugmentedProvider(telemetryProvider: telemetry, commandProvider: commands)

        let state = try await augmented.fetchVehicleState(vin: "P2-EMPTY", features: FeatureSelection.default)
        #expect(state.energy.batteryPercentage == 75)
        #expect(state.energy.rangeKm == 320)
    }

    // MARK: - Augmented Provider Portal-First Routing

    @Test
    func augmentedProviderRoutesPortalSupportedCommandsPortalFirst() async throws {
        let portal = RoutingProbeProvider(name: "portal-primary")
        let consumer = RoutingProbeProvider(name: "consumer-backup")
        let augmented = PolestarAugmentedProvider(telemetryProvider: portal, commandProvider: consumer)

        let result = try await augmented.executeRemoteCommand(.setChargeTarget(80), vin: "TESTVIN")
        #expect(result.outcome == .completed)
        #expect(await portal.receivedCommands.count == 1)
        #expect(await consumer.receivedCommands.isEmpty)
    }

    @Test
    func augmentedProviderFallsBackToConsumerWhenPortalCommandFails() async throws {
        let portal = RoutingProbeProvider(name: "portal-primary", failCommands: true)
        let consumer = RoutingProbeProvider(name: "consumer-backup")
        let augmented = PolestarAugmentedProvider(telemetryProvider: portal, commandProvider: consumer)

        let result = try await augmented.executeRemoteCommand(.setAmpLimit(12), vin: "TESTVIN")
        #expect(result.outcome == .completed)
        #expect(await portal.receivedCommands.count == 1)
        #expect(await consumer.receivedCommands.count == 1)
    }

    @Test
    func augmentedProviderRethrowsPrimaryErrorWhenConsumerIsCold() async throws {
        let portal = RoutingProbeProvider(name: "portal-primary", failCommands: true)
        let consumer = RoutingProbeProvider(name: "consumer-cold", warm: false)
        let augmented = PolestarAugmentedProvider(telemetryProvider: portal, commandProvider: consumer)

        await #expect(throws: RemoteCommandError.busy) {
            try await augmented.executeRemoteCommand(.setChargeTarget(80), vin: "TESTVIN")
        }
        #expect(await consumer.receivedCommands.isEmpty)
    }

    @Test
    func augmentedProviderSendsConsumerExclusiveCommandsDirectly() async throws {
        let portal = RoutingProbeProvider(name: "portal-primary")
        let consumer = RoutingProbeProvider(name: "consumer-backup")
        let augmented = PolestarAugmentedProvider(telemetryProvider: portal, commandProvider: consumer)

        let result = try await augmented.executeRemoteCommand(.lock, vin: "TESTVIN")
        #expect(result.outcome == .completed)
        #expect(await portal.receivedCommands.isEmpty)
        #expect(await consumer.receivedCommands.count == 1)
    }

    @Test
    func augmentedProviderRethrowsPrimaryErrorWhenBothTelemetryFail() async throws {
        let portal = PortalTestProbeProvider(brand: .polestar, name: "portal-primary", shouldFailState: true)
        let consumer = PortalTestProbeProvider(brand: .polestar, name: "consumer-warm", shouldFailState: true)
        let augmented = PolestarAugmentedProvider(telemetryProvider: portal, commandProvider: consumer)

        do {
            _ = try await augmented.fetchVehicleState(vin: "TESTVIN", features: .default)
            Issue.record("Expected fetchVehicleState to throw")
        } catch let err as VehicleServiceError {
            if case .rateLimited(let retry) = err {
                #expect(retry == 60)
            } else {
                Issue.record("Unexpected error case: \(err)")
            }
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    @MainActor
    func augmentedModeResumesSessionWithPortalCredentials() throws {
        let suite = "io.kheirallah.hisingen.augmented-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let keychain = KeychainStore(service: "io.kheirallah.hisingen.augmented-keychain.\(UUID().uuidString)")
        try? keychain.deletePolestarDataPortalCredentials()
        try? keychain.deletePolestarDataPortalToken()
        try? keychain.deleteSessionToken()
        defer {
            try? keychain.deletePolestarDataPortalCredentials()
            try? keychain.deletePolestarDataPortalToken()
            try? keychain.deleteSessionToken()
        }

        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        preferences.polestarConnectionMode = .augmented
        preferences.polestarDataPortalClientID = "test-client"
        try keychain.savePolestarDataPortalCredentials(accountID: "acc-1", clientID: "test-client", clientSecret: "test-sec")

        #expect(preferences.hasResumableSession(for: .polestar) == true)
    }

    // MARK: - Schedule & Charge-Location REST Writes

    @Test
    @MainActor
    func apiWritesSchedulesAndChargeLocationsToPortalEndpoints() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PortalMockTransport.self]
        let session = URLSession(configuration: config)

        let api = PolestarDataPortalAPI()
        await api.setSessionForTesting(session)
        await api.setAccessTokenForTesting("test-token")
        await api.configure(clientID: "client-id", clientSecret: "client-secret")

        var lastMethod = ""
        var lastPath = ""
        var lastBody = Data()
        defer { PortalMockTransport.requestHandler = nil }
        PortalMockTransport.requestHandler = { req in
            lastMethod = req.httpMethod ?? ""
            lastPath = req.url?.path ?? ""
            lastBody = portalRequestBody(req)
            return (200, Data("{}".utf8))
        }
        defer { PortalMockTransport.requestHandler = nil }

        _ = try await api.executeRemoteCommand(
            .setGlobalChargeTimer(VehicleSchedule(kind: .globalCharging, startHour: 23, startMinute: 0, endHour: 6, endMinute: 0, weekdays: [.friday], isActive: true)),
            vin: "TESTVIN")
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/global-charge-timer"))
        let timerBody = String(data: lastBody, encoding: .utf8) ?? ""
        #expect(timerBody.contains("23:00"))
        #expect(timerBody.contains("06:00"))
        #expect(timerBody.contains("FRIDAY"))

        _ = try await api.executeRemoteCommand(
            .setClimateTimer(VehicleSchedule(kind: .climate, startHour: 7, startMinute: 30, endHour: nil, endMinute: nil, weekdays: [], isActive: true)),
            vin: "TESTVIN")
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/parking-climate-timer"))
        #expect((String(data: lastBody, encoding: .utf8) ?? "").contains("07:30"))

        _ = try await api.executeRemoteCommand(.deleteClimateTimer(id: "timer-9"), vin: "TESTVIN")
        #expect(lastMethod == "DELETE")
        #expect(lastPath.contains("/charging/parking-climate-timer/timer-9"))

        _ = try await api.executeRemoteCommand(
            .createChargeLocationAtCar(alias: "Work", ampLimit: 16, minimumSoc: 70, optimisedCharging: true),
            vin: "TESTVIN")
        #expect(lastMethod == "POST")
        #expect(lastPath.contains("/charging/charge-locations"))
        let locationBody = String(data: lastBody, encoding: .utf8) ?? ""
        #expect(locationBody.contains("Work"))
        #expect(locationBody.contains("optimisedCharging"))

        _ = try await api.executeRemoteCommand(.updateChargeLocationAmpLimit(id: "loc-1", amps: 10), vin: "TESTVIN")
        #expect(lastMethod == "PUT")
        #expect(lastPath.contains("/charging/charge-locations/loc-1"))
        #expect((String(data: lastBody, encoding: .utf8) ?? "").contains("ampLimit"))

        _ = try await api.executeRemoteCommand(.deleteChargeLocation(id: "loc-1"), vin: "TESTVIN")
        #expect(lastMethod == "DELETE")
        #expect(lastPath.contains("/charging/charge-locations/loc-1"))
    }

    // MARK: - Canonical Fixture End-to-End Decoding

    @Test
    func savedJSONFixturesDecodeAndMapToVehicleState() throws {
        func fixtureData(named name: String) throws -> Data {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
            return try Data(contentsOf: url)
        }

        // 1. Token
        let tokenData = try fixtureData(named: "polestar-portal-token")
        let token = try JSONDecoder().decode(PolestarDataPortalTokenResponse.self, from: tokenData)
        #expect(token.expiresIn == 3600)
        #expect(token.tokenType == "Bearer")

        // 2. Vehicles
        let vehiclesData = try fixtureData(named: "polestar-portal-vehicles")
        let vehicles = try JSONDecoder().decode(PolestarDataPortalVehiclesDTO.self, from: vehiclesData)
        #expect(vehicles.vins.contains("YSMVSEDE6PL147228"))

        // 3. Availability
        let availData = try fixtureData(named: "polestar-portal-availability")
        let availEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarAvailabilityDTO>.self, from: availData)
        #expect(availEnv.data?.availabilityStatus == "AVAILABLE")

        // 4. Battery
        let batteryData = try fixtureData(named: "polestar-portal-battery")
        let batteryEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarBatteryDTO>.self, from: batteryData)
        let batteryDTO = try #require(batteryEnv.data)
        #expect(batteryDTO.batteryChargeLevelPercentage == 78.5)
        #expect(batteryDTO.dischargeInfo?.powerLimit == 240.0)
        #expect(batteryDTO.dischargeInfo?.energyAvailable == 62.4)
        #expect(batteryDTO.energyConsumptionPercentageManual?.driving == 72.0)
        #expect(batteryDTO.energyConsumptionWhManual?.driving == 1022760)

        let energy = batteryDTO.toEnergySnapshot()
        #expect(energy.batteryPercentage == 78.5)
        #expect(energy.chargingState == .charging)
        #expect(energy.estimatedTimeToTargetMinutes == 20)
        #expect(energy.diagnostics?.powerLimitKw == 240.0)
        #expect(energy.diagnostics?.energyAvailableKwh == 62.4)
        #expect(energy.diagnostics?.energyBreakdown?.driving?.percentage == 74.0)
        #expect(energy.diagnostics?.energyBreakdown?.driving?.wattHours == 25900)
        // Diagnostics fields that drive rendered rows but had no decode assertion.
        #expect(energy.diagnostics?.timeToMinimumSOCMinutes == 12)
        #expect(energy.diagnostics?.timeToTargetMinutes == 20)
        #expect(energy.diagnostics?.averageConsumption == 19.4)
        #expect(energy.diagnostics?.averageConsumptionSinceCharge == 17.5)
        #expect(energy.diagnostics?.averageConsumptionAutomatic == 18.9)
        #expect(energy.diagnostics?.energyUsedSinceChargeWh == 35000)

        // 5. Exterior
        let extData = try fixtureData(named: "polestar-portal-exterior")
        let extEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarExteriorDTO>.self, from: extData)
        let extDTO = try #require(extEnv.data)
        #expect(extDTO.centralLock == "LOCKED")
        #expect(extDTO.alarm == "ARMED")

        // 6. Health
        let healthData = try fixtureData(named: "polestar-portal-health")
        let healthEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarHealthDTO>.self, from: healthData)
        let healthDTO = try #require(healthEnv.data)
        #expect(healthDTO.frontTyresReferencePressureKpa == 280)
        #expect(healthDTO.rearTyresReferencePressureKpa == 290)
        let maintenance = healthDTO.toMaintenanceSnapshot()
        let frontLeft = maintenance.details?.tyres.first(where: { $0.position == .frontLeft })
        let rearRight = maintenance.details?.tyres.first(where: { $0.position == .rearRight })
        #expect(frontLeft?.referenceKilopascals == 280.0)
        #expect(rearRight?.referenceKilopascals == 290.0)

        // 7. Odometer
        let odoData = try fixtureData(named: "polestar-portal-odometer")
        let odoEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarOdometerDTO>.self, from: odoData)
        let odoDTO = try #require(odoEnv.data)
        #expect(odoDTO.calculatedOdometerKm == 42151)
        let tripSnap = odoDTO.toTripComputerSnapshot()
        #expect(tripSnap.manualTripKm == 128.4)
        #expect(tripSnap.automaticTripKm == 42102.1)
        #expect(tripSnap.sinceChargeTripKm == 96.7)
        #expect(tripSnap.manualAverageSpeedKmH == 34)
        #expect(tripSnap.automaticAverageSpeedKmH == 41)
        #expect(tripSnap.sinceChargeAverageSpeedKmH == 52)

        // 8. Location
        let locData = try fixtureData(named: "polestar-portal-location")
        let locEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarLocationDTO>.self, from: locData)
        let locDTO = try #require(locEnv.data)
        let loc = locDTO.toVehicleLocation()
        #expect(loc.latitude == 57.708870)
        #expect(loc.longitude == 11.974560)
        #expect(loc.altitudeMeters == 24.5)

        // 9. Parking Climatization
        let climData = try fixtureData(named: "polestar-portal-telemetry-parking-climatization")
        let climEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarParkingClimatizationDTO>.self, from: climData)
        let climDTO = try #require(climEnv.data)
        #expect(climDTO.runningStatus == "RUNNING_STATUS_ON")
        #expect(climDTO.requestedCompartmentTemperatureCelsius == 21.0)
        #expect(climDTO.requestedFrontLeftSeat == "HEATING_INTENSITY_MEDIUM")
        #expect(climDTO.requestedSteeringWheelHeating == "HEATING_INTENSITY_LOW")
        #expect(climDTO.runtimeLeftMinutes == 18)
        let climate = climDTO.toVehicleClimateStatus()
        #expect(climate.activity == .active)
        #expect(climate.timeRemainingMinutes == 18)
        #expect(climate.interiorTemperatureCelsius == 16.5)
        #expect(climate.requestedTemperatureCelsius == 21.0)
        #expect(climate.driverSeatHeatingLevel == 2)
        #expect(climate.passengerSeatHeatingLevel == 0)
        #expect(climate.rearLeftSeatHeatingLevel == 1)
        #expect(climate.rearRightSeatHeatingLevel == 0)
        #expect(climate.steeringWheelHeatingLevel == 1)
        #expect(climate.ventilation == "VENTILATION_HEATING")
        #expect(climate.mainClimateRunningStatus == "MAIN_CLIMATE_RUNNING_STATUS_ON")
        #expect(climate.sessionStartedAt != nil)
        #expect(climate.sessionEndsAt != nil)

        // 10. Pre-cleaning
        let cleanData = try fixtureData(named: "polestar-portal-telemetry-pre-cleaning")
        let cleanEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarPreCleaningDTO>.self, from: cleanData)
        let cleanDTO = try #require(cleanEnv.data)
        #expect(cleanDTO.runningStatus == "RUNNING_STATUS_OFF")
        #expect(cleanDTO.measuredAirQualityIndex == 25)
        let air = cleanDTO.toVehicleAirQuality()
        #expect(air.cleaningState == .off)
        #expect(air.airQualityIndex == 25)
        #expect(air.particulateMatter25 == 8)
        #expect(air.lastCycleValid == true)
        #expect(air.errorKind == AirCleaningError.none)
        #expect(air.measuredAt != nil)
        #expect(air.lastCycleCompleted != nil)

        // 11. Target SoC
        let socData = try fixtureData(named: "polestar-portal-charging-target-soc")
        let socEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarTargetSocDTO>.self, from: socData)
        let socDTO = try #require(socEnv.data)
        #expect(socDTO.targetSoc?.batteryChargeTargetLevel == 80)
        #expect(socDTO.targetSocPercentage == 80)

        // 12. Amp Limit
        let ampData = try fixtureData(named: "polestar-portal-charging-amp-limit")
        let ampEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarAmpLimitDTO>.self, from: ampData)
        let ampDTO = try #require(ampEnv.data)
        #expect(ampDTO.syncedAmpLimit?.ampLimit == 16)
        #expect(ampDTO.ampLimit == 16)
        #expect(ampDTO.pendingAmpLimit == nil)

        // 13. Charge Locations
        let locsData = try fixtureData(named: "polestar-portal-charging-charge-locations")
        let locsEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarChargeLocationsDTO>.self, from: locsData)
        let locsDTO = try #require(locsEnv.data)
        #expect(locsDTO.chargeLocations?.first?.locationAlias == "Home Garage")
        #expect(locsDTO.chargeLocations?.first?.minimumSoc == 90)
        let locList = locsDTO.toChargeLocations()
        #expect(locList.count == 1)
        #expect(locList.first?.id == "loc-home-01")
        #expect(locList.first?.alias == "Home Garage")
        #expect(locList.first?.latitude == 57.70887)
        #expect(locList.first?.minimumSoc == 90)
        #expect(locList.first?.ampLimit == 16)
        #expect(locList.first?.optimisedChargingEnabled == true)
        #expect(locList.first?.optimisedChargingMode == 1)
        #expect(locList.first?.kind == 2)
        #expect(locList.first?.isBidirectionalChargingEnabled == false)
        #expect(locList.first?.availableOptimizedCharging == "INTELLIGENT_TIMER")
        #expect(locList.first?.chargeTimers.count == 1)
        #expect(locList.first?.chargeTimers.first?.startHour == 1)
        #expect(locList.first?.chargeTimers.first?.startMinute == 0)
        #expect(locList.first?.chargeTimers.first?.endHour == 5)
        #expect(locList.first?.chargeTimers.first?.endMinute == 30)
        #expect(locList.first?.departureTimes.count == 1)
        #expect(locList.first?.departureTimes.first?.startHour == 7)
        #expect(locList.first?.departureTimes.first?.startMinute == 45)

        // 14. Is At Charge Location
        let isAtData = try fixtureData(named: "polestar-portal-charging-is-at-charge-location")
        let isAtEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarIsAtChargeLocationDTO>.self, from: isAtData)
        let isAtDTO = try #require(isAtEnv.data)
        #expect(isAtDTO.locationId == "loc-home-01")
        #expect(isAtDTO.isAtChargeLocation == true)
        #expect(isAtDTO.arrivedAtTimestamp?.date != nil)
        // The state carries no name; the id → name join happens in snapshot assembly.
        #expect(isAtDTO.currentLocationName == nil)

        // 15. Global Charge Timer
        let timerData = try fixtureData(named: "polestar-portal-charging-global-charge-timer")
        let timerEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarGlobalChargeTimerDTO>.self, from: timerData)
        let timerDTO = try #require(timerEnv.data)
        #expect(timerDTO.globalChargeTimer?.start?.hourComponent == 23)
        #expect(timerDTO.globalChargeTimer?.stop?.hourComponent == 6)
        let schedules = timerDTO.toSchedules()
        #expect(schedules.count == 1)
        #expect(schedules.first?.startHour == 23)
        #expect(schedules.first?.startMinute == 0)
        #expect(schedules.first?.endHour == 6)
        #expect(schedules.first?.isActive == true)
        // The spec global window is a daily range with no weekday list.
        #expect(schedules.first?.weekdays.isEmpty == true)

        // 16. Charge Now
        let chargeNowData = try fixtureData(named: "polestar-portal-charging-charge-now")
        let chargeNowEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarChargeNowDTO>.self, from: chargeNowData)
        let chargeNowDTO = try #require(chargeNowEnv.data)
        #expect(chargeNowDTO.syncedOverrideChargeTimer?.override == true)
        #expect(chargeNowDTO.pendingOverrideChargeTimer == nil)

        // 17. Override Charge Timer — same wire shape as charge-now, mid-sync after a POST
        let overrideData = try fixtureData(named: "polestar-portal-charging-override-charge-timer")
        let overrideEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarChargeNowDTO>.self, from: overrideData)
        let overrideDTO = try #require(overrideEnv.data)
        #expect(overrideDTO.pendingOverrideChargeTimer?.override == true)
        #expect(overrideDTO.syncedOverrideChargeTimer?.override == false)

        // 18. Parking Climate Timer
        let climTimerData = try fixtureData(named: "polestar-portal-charging-parking-climate-timer")
        let climTimerEnv = try JSONDecoder().decode(PolestarDataPortalEnvelope<PolestarParkingClimateTimerDTO>.self, from: climTimerData)
        let climTimerDTO = try #require(climTimerEnv.data)
        #expect(climTimerDTO.parkingClimateTimers?.first?.readyAt?.hourComponent == 7)
        let climateTimers = climTimerDTO.toClimateSchedules()
        #expect(climateTimers.count == 1)
        #expect(climateTimers.first?.backendID == "climate-timer-morning-01")
        #expect(climateTimers.first?.startHour == 7)
        #expect(climateTimers.first?.startMinute == 30)
        #expect(climateTimers.first?.isActive == true)
        #expect(climateTimers.first?.weekdays.count == 5)
    }
}

private actor PortalTestProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand
    let providerName: String
    var stateToReturn: VehicleState?
    var shouldFailState: Bool = false
    var shouldFailRestore: Bool = false
    var warm: Bool = true

    init(
        brand: VehicleBrand,
        name: String,
        state: VehicleState? = nil,
        shouldFailState: Bool = false,
        shouldFailRestore: Bool = false,
        warm: Bool = true
    ) {
        self.brand = brand
        self.providerName = name
        self.stateToReturn = state
        self.shouldFailState = shouldFailState
        self.shouldFailRestore = shouldFailRestore
        self.warm = warm
    }

    var cars: [CarSummary] {
        [CarSummary(vin: providerName, title: providerName)]
    }
    var hasWarmSession: Bool { warm }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        if shouldFailRestore {
            throw VehicleServiceError.authenticationRequired(provider: brand, reason: .expiredSession)
        }
    }
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        if shouldFailState {
            throw VehicleServiceError.rateLimited(retryAfter: 60)
        }
        if let state = stateToReturn {
            return state
        }
        throw VehicleServiceError.notConfigured
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}

private final class PortalMockTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://polestar.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Records commands and can fail each channel independently, proving the augmented
/// provider's portal-first routing and its warm-session fallback guard.
private actor RoutingProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand
    let name: String
    let warm: Bool
    let failFetch: Bool
    let failCommands: Bool
    private(set) var receivedCommands: [RemoteCommand] = []

    init(name: String, warm: Bool = true, failFetch: Bool = false, failCommands: Bool = false) {
        self.brand = .polestar
        self.name = name
        self.warm = warm
        self.failFetch = failFetch
        self.failCommands = failCommands
    }

    var cars: [CarSummary] { [CarSummary(vin: name, title: name)] }
    var hasWarmSession: Bool { warm }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        if failFetch { throw VehicleServiceError.rateLimited(retryAfter: 60) }
        return VehicleState(
            energy: EnergyAndChargingSnapshot(batteryPercentage: 60),
            identity: VehicleIdentitySnapshot(availability: .available, modelName: name, vin: name),
            freshness: SnapshotFreshness(fetchedAt: Date())
        )
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        receivedCommands.append(command)
        if failCommands { throw RemoteCommandError.busy }
        return RemoteCommandResult(outcome: .completed, message: nil)
    }
}

/// URLSession hands POST bodies to URLProtocol as a stream, not `httpBody`, so drain
/// whichever form the request carries.
private func portalRequestBody(_ request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: 4096)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}
