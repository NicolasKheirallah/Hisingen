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

        try store.savePolestarDataPortalCredentials(clientID: "test-client-id", clientSecret: "test-client-secret")
        #expect(try store.readPolestarDataPortalClientID() == "test-client-id")
        #expect(try store.readPolestarDataPortalClientSecret() == "test-client-secret")
        #expect(store.hasStoredPolestarDataPortalCredentials == true)

        try store.savePolestarDataPortalToken("test-portal-token")
        #expect(try store.readPolestarDataPortalToken() == "test-portal-token")

        try store.deletePolestarDataPortalToken()
        #expect(try store.readPolestarDataPortalToken() == nil)

        try store.deletePolestarDataPortalCredentials()
        #expect(try store.readPolestarDataPortalClientID() == nil)
        #expect(try store.readPolestarDataPortalClientSecret() == nil)
        #expect(store.hasStoredPolestarDataPortalCredentials == false)
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
