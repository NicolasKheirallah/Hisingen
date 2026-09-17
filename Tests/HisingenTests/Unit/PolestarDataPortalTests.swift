import Foundation
import Testing
@testable import Hisingen

@Suite
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
            "odometerMeters": 42150.0,
            "timestamp": { "seconds": "1774968000", "nanos": 0 }
        }
        """
        let odoDTO = try JSONDecoder().decode(PolestarOdometerDTO.self, from: Data(json.utf8))
        #expect(odoDTO.odometerMeters == 42150.0)
        #expect(odoDTO.calculatedOdometerKm == 42)

        let kmJson = """
        { "vin": "YSM12345678901234", "odometerKm": 128.7 }
        """
        let odoKmDTO = try JSONDecoder().decode(PolestarOdometerDTO.self, from: Data(kmJson.utf8))
        #expect(odoKmDTO.calculatedOdometerKm == 129)
    }

    @Test
    func locationTelemetryDecodesAndMapsToVehicleLocation() throws {
        let json = """
        {
            "vin": "YSM12345678901234",
            "latitude": 57.7089,
            "longitude": 11.9746,
            "headingDegrees": 180.0,
            "speedMetersPerSecond": 25.0,
            "altitudeMeters": 35.0,
            "accuracyMeters": 5.0
        }
        """
        let locDTO = try JSONDecoder().decode(PolestarLocationDTO.self, from: Data(json.utf8))
        #expect(locDTO.latitude == 57.7089)
        #expect(locDTO.longitude == 11.9746)

        let vehicleLoc = locDTO.toVehicleLocation()
        #expect(vehicleLoc.latitude == 57.7089)
        #expect(vehicleLoc.longitude == 11.9746)
        #expect(vehicleLoc.speed == 90.0) // 25 m/s * 3.6 = 90 km/h
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
    func providerCommandCatalogDisallowsRemoteCommandsInDataPortalMode() {
        let portalCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .dataPortal)
        #expect(portalCatalog.implements(.lock) == false)
        #expect(portalCatalog.implements(.unlock) == false)
        #expect(portalCatalog.implements(.stopClimate) == false)
        #expect(portalCatalog.implements(.startChargingOverride) == false)

        let consumerCatalog = ProviderCommandCatalog(brand: .polestar, polestarConnectionMode: .polestarID)
        #expect(consumerCatalog.implements(.lock) == true)
        #expect(consumerCatalog.implements(.stopClimate) == true)
    }

    @Test
    @MainActor
    func commandAvailabilityExplainsDataPortalReadonly() {
        let pref = PreferencesStore.shared
        pref.polestarConnectionMode = .dataPortal
        let reason = CommandAvailability.unimplementedByProvider.shortReason
        #expect(reason?.contains("Developer Portal") == true)
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
}

private actor PortalTestProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand
    let providerName: String

    init(brand: VehicleBrand, name: String) {
        self.brand = brand
        self.providerName = name
    }

    var cars: [CarSummary] {
        [CarSummary(vin: providerName, title: providerName)]
    }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? { preferred }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        throw VehicleServiceError.notConfigured
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        throw RemoteCommandError.unsupported
    }
}
