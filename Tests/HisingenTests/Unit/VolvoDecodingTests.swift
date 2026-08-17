import Foundation
import Testing
@testable import Hisingen


struct VolvoDecodingTests {

    #if SWIFT_PACKAGE
    private func loadFixture<Payload: Decodable>(_ name: String, as: Payload.Type) throws -> Payload {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: data)
        return try XCTUnwrap(envelope.data)
    }

    @Test
    func testVehiclesListFixtureDecodes() throws {
        let list = try loadFixture("volvo-vehicles-list", as: [VolvoVehicleSummaryDTO].self)
        XCTAssertEqual(list.map(\.vin), ["YV1FIXTURE0000001", "YV1FIXTURE0000002"])
    }

    @Test
    func testBEVVehicleDetailsFixtureDecodes() throws {
        let details = try loadFixture("volvo-vehicle-details-bev", as: VolvoVehicleDetailsDTO.self)
        XCTAssertEqual(details.descriptions?.model, "EX30")
        XCTAssertEqual(details.descriptions?.upholstery, "Fixture Textile")
        XCTAssertEqual(details.descriptions?.steering, "Left")
        XCTAssertEqual(details.batteryCapacityKWH, 64.0)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: details.fuelType), .bev)
    }

    @Test
    func testPHEVVehicleDetailsFixtureDecodes() throws {
        let details = try loadFixture("volvo-vehicle-details-phev", as: VolvoVehicleDetailsDTO.self)
        XCTAssertEqual(details.descriptions?.model, "XC60")
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: details.fuelType), .phev)
    }

    @Test
    func testICEVehicleDetailsFixtureDecodesWithoutBatteryCapacity() throws {
        let details = try loadFixture("volvo-vehicle-details-ice", as: VolvoVehicleDetailsDTO.self)
        XCTAssertEqual(details.descriptions?.model, "XC90")
        XCTAssertNil(details.batteryCapacityKWH)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: details.fuelType), .ice)
    }

    @Test
    func testPartialVehicleDetailsFixtureFallsBackToBareRoot() throws {


        let details = try loadFixture("volvo-vehicle-details-partial", as: VolvoVehicleDetailsDTO.self)
        XCTAssertEqual(details.modelYear, 2025)
        XCTAssertNil(details.descriptions)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: details.fuelType), .mildHybrid)
    }

    @Test
    func testUnknownFieldsFixtureDoesNotBreakDecoding() throws {


        let details = try loadFixture("volvo-vehicle-details-unknown-fields", as: VolvoVehicleDetailsDTO.self)
        XCTAssertEqual(details.descriptions?.model, "Concept Recharge X")
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: details.fuelType), .unknown)
    }

    @Test
    func testEnergyStateFixtureDecodes() throws {
        let state = try loadFixture("volvo-energy-state", as: VolvoEnergyStateDTO.self)
        XCTAssertEqual(state.batteryChargeLevel?.value, 68.0)
        XCTAssertEqual(state.electricRange?.value, 210)
        XCTAssertEqual(ChargingState(volvoChargingStatus: state.chargingStatus?.value), .charging)
        XCTAssertEqual(ChargerConnection(volvoConnectionStatus: state.chargerConnectionStatus?.value), .connected)
        XCTAssertEqual(state.targetBatteryLevel?.value, 90)
    }

    @Test
    func testEnergyCapabilitiesFixtureDecodes() throws {
        let caps = try loadFixture("volvo-energy-capabilities", as: VolvoEnergyCapabilitiesDTO.self)
        XCTAssertEqual(caps.chargingPower?.isSupported, true)
        XCTAssertEqual(caps.targetBatteryLevel?.isSupported, false)
    }

    @Test
    func testDoorsFixtureDecodesLockedAndClosed() throws {
        let doors = try loadFixture("volvo-doors", as: VolvoDoorsDTO.self)
        XCTAssertEqual(doors.isLocked, true)
        XCTAssertEqual(OpeningState(volvoStatus: doors.frontLeftDoor?.value), .closed)
        XCTAssertEqual(OpeningState(volvoStatus: doors.tankLid?.value), .closed)
    }

    @Test
    func testDoorsOpenFixtureDecodesUnlockedAndOpenDoor() throws {
        let doors = try loadFixture("volvo-doors-open", as: VolvoDoorsDTO.self)
        XCTAssertEqual(doors.isLocked, false)
        XCTAssertEqual(OpeningState(volvoStatus: doors.frontLeftDoor?.value), .open)
        XCTAssertEqual(OpeningState(volvoStatus: doors.frontRightDoor?.value), .closed)
    }

    @Test
    func testWindowsFixtureDecodes() throws {
        let windows = try loadFixture("volvo-windows", as: VolvoWindowsDTO.self)
        XCTAssertEqual(OpeningState(volvoStatus: windows.frontLeftWindow?.value), .closed)
        XCTAssertEqual(OpeningState(volvoStatus: windows.sunroof?.value), .closed)
    }

    @Test
    func testTyresFixtureDecodesMixedWarnings() throws {
        let tyres = try loadFixture("volvo-tyres", as: VolvoTyresDTO.self)
        let readings = tyres.readings
        XCTAssertEqual(readings.count, 4)
        XCTAssertNil(readings.first(where: { $0.position == .frontLeft })?.kilopascals)
        XCTAssertEqual(readings.first(where: { $0.position == .frontLeft })?.warning, .unknown)
        XCTAssertEqual(readings.first(where: { $0.position == .frontRight })?.warning, TyrePressureWarning.none)
        XCTAssertEqual(readings.first(where: { $0.position == .rearLeft })?.warning, .low)
        XCTAssertEqual(readings.first(where: { $0.position == .rearRight })?.warning, .high)
    }

    @Test
    func testDiagnosticsFixtureOnlyReportsActualWarnings() throws {
        let diagnostics = try loadFixture("volvo-diagnostics", as: VolvoDiagnosticsDTO.self)
        XCTAssertFalse(diagnostics.hasServiceWarning)
        XCTAssertEqual(diagnostics.serviceTrigger?.value, "CALENDAR_TIME")
        XCTAssertEqual(diagnostics.fluidWarnings, ["Oil"])
        XCTAssertEqual(diagnostics.vehicleWarnings, [.oil])


        XCTAssertEqual(diagnostics.distanceToService?.value, 8500)
        XCTAssertEqual(diagnostics.timeToService?.value, 5)
        XCTAssertEqual(diagnostics.daysToServiceApprox, 150)
    }

    @Test
    func testOdometerFixtureDecodes() throws {
        let odometer = try loadFixture("volvo-odometer", as: VolvoOdometerDTO.self)
        XCTAssertEqual(odometer.odometer?.value, 42317)
    }

    @Test
    func testFuelFixtureDecodes() throws {


        let fuel = try loadFixture("volvo-fuel", as: VolvoFuelDTO.self)
        XCTAssertEqual(fuel.fuelAmount?.value, 42.0)
    }

    @Test
    func testStatisticsFixtureDecodesTripMetersAndRange() throws {
        let stats = try loadFixture("volvo-statistics", as: VolvoStatisticsDTO.self)
        XCTAssertEqual(stats.tripMeterManual?.value, 500.0)
        XCTAssertEqual(stats.tripMeterAutomatic?.value, 420.0)
        XCTAssertEqual(stats.distanceToEmptyTank?.value, 1312)
        XCTAssertEqual(stats.distanceToEmptyBattery?.value, 200)
    }

    @Test
    func testLocationFixtureDecodes() throws {
        let location = try loadFixture("volvo-location", as: VolvoLocationDTO.self)
        XCTAssertEqual(location.geometry?.coordinates?.count, 2)
        XCTAssertEqual(location.properties?.heading, "180")
    }

    @Test
    func testTokenResponseFixtureDecodes() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "volvo-token-response", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let token = try JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: data)
        XCTAssertEqual(token.accessToken, "fixture-access-token-not-real")
        XCTAssertEqual(token.refreshToken, "fixture-refresh-token-not-real")
        XCTAssertEqual(token.expiresIn, 3600)
    }
    #endif


    @Test
    func testFieldDecodesWrappedValueShape() throws {
        let json = #"{"value": 72.5, "status": "OK", "updatedAt": "2026-08-15T10:00:00Z"}"#
        let field = try JSONDecoder.volvo.decode(VolvoField<Double>.self, from: Data(json.utf8))
        XCTAssertEqual(field.value, 72.5)
        XCTAssertEqual(field.status, "OK")
        XCTAssertNotNil(field.updatedAt)
    }

    @Test
    func testFieldFallsBackToBareScalar() throws {
        let json = "42"
        let field = try JSONDecoder.volvo.decode(VolvoField<Int>.self, from: Data(json.utf8))
        XCTAssertEqual(field.value, 42)
        XCTAssertNil(field.status)
    }

    @Test
    func testEnvelopeUnwrapsDataKey() throws {
        struct Payload: Decodable, Equatable { let vin: String }
        let json = #"{"data": {"vin": "FIXTURE"}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.data, Payload(vin: "FIXTURE"))
    }

    @Test
    func testEnvelopeFallsBackToBareRoot() throws {
        struct Payload: Decodable, Equatable { let vin: String }
        let json = #"{"vin": "FIXTURE"}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: Data(json.utf8))
        XCTAssertEqual(envelope.data, Payload(vin: "FIXTURE"))
    }

    @Test
    func testPowertrainClassification() {
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "NONE"), .unknown)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "ELECTRIC"), .bev)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL/ELECTRIC"), .phev)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL"), .ice)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "DIESEL"), .ice)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: nil), .unknown)
        XCTAssertEqual(VolvoPowertrain.classify(fuelType: "PETROL MHEV"), .mildHybrid)
    }

    @Test
    func testChargingStateMapping() {
        XCTAssertEqual(ChargingState(volvoChargingStatus: "CHARGING"), .charging)
        XCTAssertEqual(ChargingState(volvoChargingStatus: "DONE"), .complete)
        XCTAssertEqual(ChargingState(volvoChargingStatus: "IDLE"), .idle)
        XCTAssertEqual(ChargingState(volvoChargingStatus: nil), .unknown("UNSPECIFIED"))


        XCTAssertEqual(ChargingState(volvoChargingStatus: "SOME_NEW_STATE"), .unknown("SOME_NEW_STATE"))
    }

    @Test
    func testChargerConnectionMapping() {
        XCTAssertEqual(ChargerConnection(volvoConnectionStatus: "CONNECTED"), .connected)
        XCTAssertEqual(ChargerConnection(volvoConnectionStatus: "DISCONNECTED"), .disconnected)
        XCTAssertEqual(ChargerConnection(volvoConnectionStatus: nil), .unknown)
    }

    @Test
    func testOpeningStateMapping() {
        XCTAssertEqual(OpeningState(volvoStatus: "OPEN"), .open)
        XCTAssertEqual(OpeningState(volvoStatus: "CLOSED"), .closed)
        XCTAssertEqual(OpeningState(volvoStatus: "AJAR"), .ajar)
        XCTAssertNil(OpeningState(volvoStatus: nil))
    }

    @Test
    func testWarningsDecodingAndActiveSensors() throws {
        let json = """
        {
            "data": {
                "brakeLightCenterWarning": {"value": "NO_WARNING"},
                "brakeLightLeftWarning": {"value": "BULB_FAILURE"},
                "highBeamRightWarning": {"value": "FAILURE"},
                "lowBeamLeftWarning": {"value": "NO_WARNING"},
                "hazardLightsWarning": {"value": "FAULT"},
                "reverseLightsWarning": {"value": "FAILURE"}
            }
        }
        """
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoWarningsDTO>.self, from: Data(json.utf8))
        let warnings = try XCTUnwrap(envelope.data)
        XCTAssertEqual(warnings.activeWarnings.count, 4)
        XCTAssertTrue(warnings.activeWarnings.contains(where: { $0.contains("Left brake light") }))
        XCTAssertTrue(warnings.activeWarnings.contains(where: { $0.contains("Right high beam") }))
        XCTAssertTrue(warnings.activeWarnings.contains(where: { $0.contains("Hazard warning lights") }))
        XCTAssertTrue(warnings.activeWarnings.contains(where: { $0.contains("Reverse light") }))
    }

    @Test
    func testBrakesDecoding() throws {
        let json = """
        {
            "data": {
                "brakeFluidLevelWarning": {"value": "WARNING"}
            }
        }
        """
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoBrakesDTO>.self, from: Data(json.utf8))
        let dto = try XCTUnwrap(envelope.data)
        XCTAssertEqual(dto.brakeFluidLevelWarning?.value, "WARNING")
    }

    @Test
    func testEngineStatusDecoding() throws {
        let json = """
        {
            "data": {
                "engineStatus": {"value": "RUNNING"}
            }
        }
        """
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoEngineStatusDTO>.self, from: Data(json.utf8))
        let dto = try XCTUnwrap(envelope.data)
        XCTAssertTrue(dto.isRunning)
    }

    @Test
    func testCommandAccessibilityDecoding() throws {
        let json = """
        {
            "data": {
                "availabilityStatus": {"value": "AVAILABLE"}
            }
        }
        """
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoCommandAccessibilityDTO>.self, from: Data(json.utf8))
        let dto = try XCTUnwrap(envelope.data)
        XCTAssertTrue(dto.isAvailable)
    }

    @Test
    func testVehicleStateFormattedHelpers() {
        var state = VehicleState(
            batteryPercentage: 80, rangeKm: 300, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 90,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "EX30", modelYear: "2024", registrationNo: nil, vin: "YV1TEST00001",
            ownerFirstName: nil, odometerKm: 10000, daysToService: 150, distanceToServiceKm: 8500,
            serviceWarning: false, fluidWarnings: [], imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )
        state.serviceTrigger = "CALENDAR_TIME"
        state.steeringOrientation = "Left"
        state.upholstery = "Nordico"
        state.tripComputerElectricRangeKm = 310
        state.chargingCurrentLimitAmps = 32

        XCTAssertEqual(state.formattedServiceTrigger, "Time")
        XCTAssertEqual(state.formattedSteeringOrientation, "Left-hand drive")
        XCTAssertEqual(state.upholstery, "Nordico")
        XCTAssertEqual(state.tripComputerElectricRangeKm, 310)
        XCTAssertEqual(state.chargingCurrentLimitAmps, 32)
    }
}


