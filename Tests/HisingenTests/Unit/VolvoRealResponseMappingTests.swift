import Foundation
import Testing
@testable import Hisingen

// Payloads shaped like live Connected Vehicle API responses. The values are fake; the shapes and
// the timestamp formats are real.

private let mappingVIN = "YV1TESTDUMP000001"

private let mappingDetailsJSON = #"{"batteryCapacityKWH":81.608,"descriptions":{"model":"XC40","steering":"LEFT","upholstery":"null"},"externalColour":"Silver Dawn","fuelType":"ELECTRIC","gearbox":"AUTOMATIC","modelYear":2024,"specifications":{"driveType":"RWD","enginePowerKw":185.0,"grossWeightKg":2520,"numberOfSeats":5},"vin":"YV1TESTDUMP000001"}"#

private let mappingStatisticsJSON = #"{"averageEnergyConsumption":{"timestamp":"2026-11-21T08:43:22.647Z","unit":"kWh/100km","value":18.0},"averageSpeed":{"timestamp":"2026-11-20T06:08:48.624Z","unit":"km/h","value":38},"averageSpeedAutomatic":{"timestamp":"2026-11-20T06:08:48.624Z","unit":"km/h","value":41},"distanceToEmptyBattery":{"timestamp":"2026-11-21T08:24:06.587Z","unit":"km","value":270},"tripMeterAutomatic":{"timestamp":"2026-11-20T06:08:48.624Z","unit":"km","value":12.1},"tripMeterManual":{"timestamp":"2026-11-20T06:08:48.624Z","unit":"km","value":3361.1}}"#

private let mappingEnergyJSON = #"{"batteryChargeLevel":{"status":"OK","value":63.0,"unit":"percentage","updatedAt":"2026-11-21T08:24:06Z"},"chargingCurrentLimit":{"status":"OK","value":32,"unit":"ampere","updatedAt":"2026-07-08T04:09:32Z"},"targetBatteryChargeLevel":{"status":"OK","value":100,"unit":"percentage","updatedAt":"2025-05-04T12:19:18Z"},"chargingPower":{"status":"ERROR","code":"PROPERTY_NOT_FOUND","message":"No valid value could be found for the requested property"},"transferLimit":{"status":"ERROR","code":"PROPERTY_NOT_SUPPORTED","message":"Property is not supported for this vehicle"}}"#

private let mappingLocationJSON = #"{"type":"Feature","properties":{"heading":"123","timestamp":"2026-11-20T06:08:52.600Z"},"geometry":{"type":"Point","coordinates":[11.97,57.73,0.0]}}"#

private let mappingDoorsJSON = #"{"centralLock":{"timestamp":"2026-11-21T06:20:06.337Z","value":"LOCKED"},"frontLeftDoor":{"timestamp":"2026-11-21T06:20:06.337Z","value":"CLOSED"},"frontRightDoor":{"timestamp":"2026-11-21T06:20:06.337Z","value":"CLOSED"}}"#

private let mappingWindowsJSON = #"{"frontLeftWindow":{"timestamp":"2026-11-21T06:31:40.100Z","value":"CLOSED"},"frontRightWindow":{"timestamp":"2026-11-21T06:20:06.337Z","value":"CLOSED"}}"#

private let mappingAccessibilityJSON = #"{"availabilityStatus":{"timestamp":"2026-11-21T08:39:12.650Z","value":"AVAILABLE"}}"#

private let mappingCapabilitiesJSON = #"{"data":{"getEnergyState":{"isSupported":true,"batteryChargeLevel":{"isSupported":true},"electricRange":{"isSupported":true},"chargerConnectionStatus":{"isSupported":true},"chargingSystemStatus":{"isSupported":true},"chargingType":{"isSupported":true},"chargerPowerStatus":{"isSupported":true},"chargingPower":{"isSupported":true},"chargingCurrentLimit":{"isSupported":true},"estimatedChargingTimeToTargetBatteryChargeLevel":{"isSupported":true},"targetBatteryChargeLevel":{"isSupported":false}}}}"#

private let mappingTokenJSON = #"{"access_token":"fake-access-token","refresh_token":"fake-refresh-token","expires_in":3600,"token_type":"Bearer"}"#

private let mappingRoutes: [String: String] = [
    "/connected-vehicle/v2/vehicles/\(mappingVIN)": mappingDetailsJSON,
    "/connected-vehicle/v2/vehicles/\(mappingVIN)/statistics": mappingStatisticsJSON,
    "/energy/v2/vehicles/\(mappingVIN)/state": mappingEnergyJSON,
    "/energy/v2/vehicles/\(mappingVIN)/capabilities": mappingCapabilitiesJSON,
    "/connected-vehicle/v2/vehicles/\(mappingVIN)/doors": mappingDoorsJSON,
    "/connected-vehicle/v2/vehicles/\(mappingVIN)/windows": mappingWindowsJSON,
    "/location/v1/vehicles/\(mappingVIN)/location": mappingLocationJSON,
    "/connected-vehicle/v2/vehicles/\(mappingVIN)/command-accessibility": mappingAccessibilityJSON
]

/// Unrouted API paths answer 404, which is how the energy capabilities probe sees a missing
/// resource. Anything outside the API prefixes is the identity provider's token endpoint.
private func mappingReply(for path: String) -> (status: Int, body: String) {
    if let body = mappingRoutes[path] { return (200, body) }
    if ["/connected-vehicle/", "/energy/", "/location/"].contains(where: { path.hasPrefix($0) }) {
        return (404, "{}")
    }
    return (200, mappingTokenJSON)
}

private func isWithinCentisecond(_ date: Date?, of seconds: Double) -> Bool {
    guard let date else { return false }
    return abs(date.timeIntervalSince1970 - seconds) < 0.01
}

@Suite("Volvo real response mapping", .serialized)
struct VolvoRealResponseMappingTests {

    @Test("Manual and automatic average speeds map to their own fields")
    func averageSpeedsStayApart() throws {
        let stats = try JSONDecoder.volvo.decode(VolvoStatisticsDTO.self, from: Data(mappingStatisticsJSON.utf8))
        #expect(stats.averageSpeedManualKmH == 38)
        #expect(stats.averageSpeedAutomaticKmH == 41)
        // The blended accessor still prefers the automatic period.
        #expect(stats.averageSpeedKmH == 41)
    }

    @Test("Volvo's placeholder altitude of 0.0 reads as no altitude")
    func placeholderAltitudeIsNil() throws {
        let placeholder = try JSONDecoder.volvo.decode(VolvoLocationDTO.self, from: Data(mappingLocationJSON.utf8))
        #expect(placeholder.altitudeMeters == nil)

        let withAltitude = try JSONDecoder.volvo.decode(
            VolvoLocationDTO.self,
            from: Data(#"{"geometry":{"type":"Point","coordinates":[11.97,57.73,42.5]}}"#.utf8))
        #expect(withAltitude.altitudeMeters == 42.5)

        let noThirdCoordinate = try JSONDecoder.volvo.decode(
            VolvoLocationDTO.self,
            from: Data(#"{"geometry":{"type":"Point","coordinates":[11.97,57.73]}}"#.utf8))
        #expect(noThirdCoordinate.altitudeMeters == nil)
    }

    @Test("Vehicle specifications decode from the details payload")
    func specificationsDecode() throws {
        let details = try JSONDecoder.volvo.decode(VolvoVehicleDetailsDTO.self, from: Data(mappingDetailsJSON.utf8))
        #expect(details.specifications?.driveType == "RWD")
        #expect(details.specifications?.enginePowerKw == 185.0)
        #expect(details.specifications?.grossWeightKg == 2520)
        #expect(details.specifications?.numberOfSeats == 5)
        // The literal "null" upholstery is still absent after decoding.
        #expect(details.descriptions?.upholstery.volvoMeaningful == nil)
    }

    @Test("A malformed specifications block does not take the rest of the details with it")
    func malformedSpecificationsStayContained() throws {
        let json = #"{"vin":"YV1TESTDUMP000001","modelYear":2024,"fuelType":"ELECTRIC","specifications":"unexpected"}"#
        let details = try JSONDecoder.volvo.decode(VolvoVehicleDetailsDTO.self, from: Data(json.utf8))
        #expect(details.modelYear == 2024)
        #expect(details.specifications == nil)
    }

    @Test("Energy error fields give no value and keep their code as the reason")
    func energyErrorFieldsKeepTheirCode() throws {
        let energy = try JSONDecoder.volvo.decode(VolvoEnergyStateDTO.self, from: Data(mappingEnergyJSON.utf8))
        #expect(energy.chargingPower?.value == nil)
        #expect(energy.chargingPower?.status == "ERROR")
        #expect(energy.chargingPower?.unavailableReason == "PROPERTY_NOT_FOUND")
        #expect(energy.chargingPowerWatts == nil)
        #expect(energy.batteryChargeLevel?.value == 63.0)
        #expect(energy.batteryChargeLevel?.unavailableReason == nil)

        let transfer = try JSONDecoder.volvo.decode(
            VolvoField<Double>.self,
            from: Data(#"{"status":"ERROR","code":"PROPERTY_NOT_SUPPORTED","message":"Property is not supported for this vehicle"}"#.utf8))
        #expect(transfer.value == nil)
        #expect(transfer.unavailableReason == "PROPERTY_NOT_SUPPORTED")

        // An explicit reason wins over the error code.
        let explicit = try JSONDecoder.volvo.decode(
            VolvoField<Double>.self,
            from: Data(#"{"status":"ERROR","code":"PROPERTY_NOT_FOUND","unavailableReason":"POWER_SAVING_MODE"}"#.utf8))
        #expect(explicit.unavailableReason == "POWER_SAVING_MODE")
    }

    @Test("Timestamps decode with and without fractional seconds")
    func timestampsDecodeInBothForms() throws {
        let energy = try JSONDecoder.volvo.decode(VolvoEnergyStateDTO.self, from: Data(mappingEnergyJSON.utf8))
        // 2025-05-04T12:19:18Z, whole seconds.
        #expect(energy.targetBatteryChargeLevel?.updatedAt == Date(timeIntervalSince1970: 1_746_361_158))
        // 2026-07-08T04:09:32Z, whole seconds.
        #expect(energy.chargingCurrentLimit?.updatedAt == Date(timeIntervalSince1970: 1_783_483_772))

        // 2026-11-20T06:08:48.624Z, fractional seconds.
        let stats = try JSONDecoder.volvo.decode(VolvoStatisticsDTO.self, from: Data(mappingStatisticsJSON.utf8))
        #expect(isWithinCentisecond(stats.tripMeterManual?.updatedAt, of: 1_795_154_928.624))

        // 2026-11-20T06:08:52.600Z, fractional seconds inside the location properties.
        let location = try JSONDecoder.volvo.decode(VolvoLocationDTO.self, from: Data(mappingLocationJSON.utf8))
        #expect(isWithinCentisecond(location.properties?.timestamp, of: 1_795_154_932.6))
    }

    @Test("A telemetry fetch assembles the real shapes into VehicleState")
    func fetchAssemblesRealShapes() async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteVolvoSessionToken() }
        let api = await makeReplayAPI(keychain: keychain)
        await api.seedReplayRefreshToken("fake-stored-refresh-token")

        let state = try await api.fetchVehicleState(
            vin: mappingVIN,
            features: FeatureSelection(enabled: [
                .chargingDetails, .tripMeters, .vehicleLocation, .exteriorStatus, .vehicleAvailability
            ])
        )

        #expect(state.tripComputer.manualAverageSpeedKmH == 38)
        #expect(state.tripComputer.automaticAverageSpeedKmH == 41)
        #expect(state.location?.altitudeMeters == nil)
        #expect(state.identity.driveType == "RWD")
        #expect(state.identity.enginePowerKw == 185.0)
        #expect(state.identity.grossWeightKg == 2520)
        #expect(state.identity.numberOfSeats == 5)
        #expect(state.identity.upholstery == nil)
        #expect(state.energy.powerWatts == nil)
        #expect(state.energy.targetPercentage == 100)
        #expect(state.energy.targetPercentageReportedAt == Date(timeIntervalSince1970: 1_746_361_158))
        #expect(state.energy.currentLimitAmps == 32)
        #expect(state.energy.currentLimitReportedAt == Date(timeIntervalSince1970: 1_783_483_772))
        // Newest of the door and window readings, which here is a window.
        #expect(isWithinCentisecond(state.exteriorStatus?.reportedAt, of: 1_795_242_700.1))
        #expect(isWithinCentisecond(state.identity.availabilityReportedAt, of: 1_795_250_352.65))
    }

    /// Live Volvo refreshes each resource on its own schedule. These payloads carry the real
    /// spread from one account: the doors reported at 06:20 and the energy state at 08:24, while
    /// the location sat at 06:08 the previous day. Collapsing them into one `vehicleReportedAt`
    /// made the day-old location read as the newest thing in the sweep.
    @Test("A reading keeps its own report time instead of the sweep's newest")
    func readingDatesFollowEachEndpoint() async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteVolvoSessionToken() }
        let api = await makeReplayAPI(keychain: keychain)
        await api.seedReplayRefreshToken("fake-stored-refresh-token")

        let state = try await api.fetchVehicleState(
            vin: mappingVIN,
            features: FeatureSelection(enabled: [
                .chargingDetails, .tripMeters, .vehicleLocation, .exteriorStatus, .vehicleAvailability
            ])
        )

        #expect(state.reportedDate(for: .battery) == Date(timeIntervalSince1970: 1_795_249_446))
        #expect(isWithinCentisecond(state.reportedDate(for: .locks), of: 1_795_242_006.337))
        #expect(isWithinCentisecond(state.reportedDate(for: .location), of: 1_795_154_932.6))
        #expect(isWithinCentisecond(state.reportedDate(for: .availability), of: 1_795_250_352.65))
        // The vehicle as a whole is as fresh as its newest reading, which must not stand in for
        // the older ones: the location is more than a day behind it.
        let newest = try #require(state.freshness.vehicleReportedAt)
        let location = try #require(state.reportedDate(for: .location))
        #expect(newest.timeIntervalSince(location) > 86_400)
    }


    /// The capabilities response is the car's own statement of what it can report. Every
    /// decoded flag has to reach the probe record in both directions: a `false` flag is
    /// what hides a charging-card row the car cannot report, so losing it would put the
    /// blank right back.
    @Test("Every energy-capability flag reaches the probe record")
    func energyCapabilityFlagsProbePerVIN() async throws {
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer { try? keychain.deleteVolvoSessionToken() }
        let api = await makeReplayAPI(keychain: keychain)
        await api.seedReplayRefreshToken("fake-stored-refresh-token")

        let state = try await api.fetchVehicleState(
            vin: mappingVIN,
            features: FeatureSelection(enabled: [.chargingDetails])
        )

        let probes = try #require(state.probedCapabilities)
        #expect(probes.support(for: .batteryChargeLevel) == .supported)
        #expect(probes.support(for: .electricRange) == .supported)
        #expect(probes.support(for: .chargerConnectionStatus) == .supported)
        #expect(probes.support(for: .chargingSystemStatus) == .supported)
        #expect(probes.support(for: .chargingType) == .supported)
        #expect(probes.support(for: .chargerPowerStatus) == .supported)
        #expect(probes.support(for: .chargingPower) == .supported)
        #expect(probes.support(for: .estimatedChargingTimeToTarget) == .supported)
        #expect(probes.support(for: .chargingCurrentLimit) == .supported)
        // The one flag the fixture says is false: the car cannot report a charge target.
        #expect(probes.support(for: .chargeTarget) == .unavailable)
    }

    // MARK: - Harness

    @MainActor
    private func makeReplayAPI(keychain: KeychainStore) async -> VolvoAPI {
        let defaults = UserDefaults(suiteName: "VolvoRealResponseMappingTests.\(UUID())")!
        let api = VolvoAPI(
            keychain: keychain,
            preferences: PreferencesStore(defaults: defaults),
            backoffs: ProviderBackoffStore(database: VehicleDatabase.inMemory())
        )
        await api.configure(clientID: "test-client", clientSecret: "test-secret", vccApiKey: "test-key")
        await api.useReplayTransport()
        return api
    }
}

private extension VolvoAPI {
    func useReplayTransport() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MappingReplayTransport.self]
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration)
    }

    func seedReplayRefreshToken(_ token: String) {
        refreshToken = token
    }
}

private final class MappingReplayTransport: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let reply = mappingReply(for: request.url?.path ?? "")
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
