import Foundation
import Testing
@testable import Hisingen


struct VolvoDecodingTests {

    #if SWIFT_PACKAGE
    private func loadFixture<Payload: Decodable & Sendable>(_ name: String, as: Payload.Type) throws -> Payload {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: data)
        return try #require(envelope.data)
    }

    @Test
    func testVehiclesListFixtureDecodes() throws {
        let list = try loadFixture("volvo-vehicles-list", as: [VolvoVehicleSummaryDTO].self)
        #expect(list.map(\.vin) == ["YV1FIXTURE0000001", "YV1FIXTURE0000002"])
    }

    @Test
    func testBEVVehicleDetailsFixtureDecodes() throws {
        let details = try loadFixture("volvo-vehicle-details-bev", as: VolvoVehicleDetailsDTO.self)
        #expect(details.descriptions?.model == "EX30")
        #expect(details.descriptions?.upholstery == "Fixture Textile")
        #expect(details.descriptions?.steering == "Left")
        #expect(details.batteryCapacityKWH == 64.0)
        #expect(VolvoPowertrain.classify(fuelType: details.fuelType) == .bev)
    }

    @Test
    func testPHEVVehicleDetailsFixtureDecodes() throws {
        let details = try loadFixture("volvo-vehicle-details-phev", as: VolvoVehicleDetailsDTO.self)
        #expect(details.descriptions?.model == "XC60")
        #expect(VolvoPowertrain.classify(fuelType: details.fuelType) == .phev)
    }

    @Test
    func testICEVehicleDetailsFixtureDecodesWithoutBatteryCapacity() throws {
        let details = try loadFixture("volvo-vehicle-details-ice", as: VolvoVehicleDetailsDTO.self)
        #expect(details.descriptions?.model == "XC90")
        #expect(details.batteryCapacityKWH == nil)
        #expect(VolvoPowertrain.classify(fuelType: details.fuelType) == .ice)
    }

    @Test
    func testPartialVehicleDetailsFixtureFallsBackToBareRoot() throws {


        let details = try loadFixture("volvo-vehicle-details-partial", as: VolvoVehicleDetailsDTO.self)
        #expect(details.modelYear == 2025)
        #expect(details.descriptions == nil)
        #expect(VolvoPowertrain.classify(fuelType: details.fuelType) == .mildHybrid)
    }

    @Test
    func testUnknownFieldsFixtureDoesNotBreakDecoding() throws {


        let details = try loadFixture("volvo-vehicle-details-unknown-fields", as: VolvoVehicleDetailsDTO.self)
        #expect(details.descriptions?.model == "Concept Recharge X")
        #expect(VolvoPowertrain.classify(fuelType: details.fuelType) == .unknown)
    }

    @Test
    func testEnergyStateFixtureDecodes() throws {
        let state = try loadFixture("volvo-energy-state", as: VolvoEnergyStateDTO.self)
        #expect(state.batteryChargeLevel?.value == 68.0)
        #expect(state.electricRange?.value == 210)
        #expect(ChargingState(volvoChargingStatus: state.chargingStateValue) == .charging)
        #expect(ChargerConnection(volvoConnectionStatus: state.chargerConnectionStatus?.value) == .connected)
        #expect(state.targetBatteryChargeLevel?.value == 90)
        #expect(state.targetPercent == 90)
        #expect(state.chargingPowerWatts == 7_400)
        #expect(state.chargingCurrentLimit?.value == 16)
        #expect(ChargingType(volvoChargingType: state.chargingType?.value) == .ac)
        #expect(ChargerPowerState(volvoPowerStatus: state.chargerPowerStatus?.value) == .providingPower)
    }

    @Test
    func testEnergyCapabilitiesFixtureDecodes() throws {
        let caps = try loadFixture("volvo-energy-capabilities", as: VolvoEnergyCapabilitiesDTO.self)
        #expect(caps.chargingPower?.isSupported == true)
        #expect(caps.targetBatteryLevel?.isSupported == false)
        #expect(caps.chargingCurrentLimit?.isSupported == true)
        #expect(caps.chargingType?.isSupported == true)
    }

    @Test
    func testDoorsFixtureDecodesLockedAndClosed() throws {
        let doors = try loadFixture("volvo-doors", as: VolvoDoorsDTO.self)
        #expect(doors.isLocked == true)
        #expect(OpeningState(volvoStatus: doors.frontLeftDoor?.value) == .closed)
        #expect(OpeningState(volvoStatus: doors.tankLid?.value) == .closed)
    }

    @Test
    func testDoorsOpenFixtureDecodesUnlockedAndOpenDoor() throws {
        let doors = try loadFixture("volvo-doors-open", as: VolvoDoorsDTO.self)
        #expect(doors.isLocked == false)
        #expect(OpeningState(volvoStatus: doors.frontLeftDoor?.value) == .open)
        #expect(OpeningState(volvoStatus: doors.frontRightDoor?.value) == .closed)
    }

    @Test
    func testWindowsFixtureDecodes() throws {
        let windows = try loadFixture("volvo-windows", as: VolvoWindowsDTO.self)
        #expect(OpeningState(volvoStatus: windows.frontLeftWindow?.value) == .closed)
        #expect(OpeningState(volvoStatus: windows.sunroof?.value) == .closed)
    }

    @Test
    func testTyresFixtureDecodesMixedWarnings() throws {
        let tyres = try loadFixture("volvo-tyres", as: VolvoTyresDTO.self)
        let readings = tyres.readings
        #expect(readings.count == 4)
        #expect(readings.first(where: { $0.position == .frontLeft })?.kilopascals == nil)
        #expect(readings.first(where: { $0.position == .frontLeft })?.warning == .unknown)
        #expect(readings.first(where: { $0.position == .frontRight })?.warning == TyrePressureWarning.none)
        #expect(readings.first(where: { $0.position == .rearLeft })?.warning == .low)
        #expect(readings.first(where: { $0.position == .rearRight })?.warning == .high)
    }

    @Test
    func testDiagnosticsFixtureOnlyReportsActualWarnings() throws {
        let diagnostics = try loadFixture("volvo-diagnostics", as: VolvoDiagnosticsDTO.self)
        #expect(!(diagnostics.hasServiceWarning))
        #expect(diagnostics.serviceTrigger?.value == "CALENDAR_TIME")
        #expect(diagnostics.fluidWarnings == ["Oil"])
        #expect(diagnostics.vehicleWarnings == [.oil])


        #expect(diagnostics.distanceToService?.value == 8500)
        #expect(diagnostics.timeToService?.value == 5)
        #expect(diagnostics.daysToServiceApprox == 150)
    }

    @Test
    func testOdometerFixtureDecodes() throws {
        let odometer = try loadFixture("volvo-odometer", as: VolvoOdometerDTO.self)
        #expect(odometer.odometer?.value == 42317)
    }

    @Test
    func testFuelFixtureDecodes() throws {


        let fuel = try loadFixture("volvo-fuel", as: VolvoFuelDTO.self)
        #expect(fuel.fuelAmount?.value == 42.0)
    }

    @Test
    func testStatisticsFixtureDecodesTripMetersAndRange() throws {
        let stats = try loadFixture("volvo-statistics", as: VolvoStatisticsDTO.self)
        #expect(stats.tripMeterManual?.value == 500.0)
        #expect(stats.tripMeterAutomatic?.value == 420.0)
        #expect(stats.distanceToEmptyTank?.value == 1312)
        #expect(stats.distanceToEmptyBattery?.value == 200)
        // Automatic-trip average consumption is now wired through to BatteryDiagnostics.
        #expect(stats.averageEnergyConsumptionAutomaticKwhPer100Km == 1.9)
    }

    @Test
    func testLocationFixtureDecodes() throws {
        let location = try loadFixture("volvo-location", as: VolvoLocationDTO.self)
        #expect(location.geometry?.coordinates?.count == 3)
        #expect(location.properties?.heading == "180")
        #expect(location.altitudeMeters == 42.5)
    }

    @Test
    func testTokenResponseFixtureDecodes() throws {
        let url = try #require(Bundle.module.url(forResource: "volvo-token-response", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let token = try JSONDecoder.volvo.decode(VolvoTokenResponseDTO.self, from: data)
        #expect(token.accessToken == "fixture-access-token-not-real")
        #expect(token.refreshToken == "fixture-refresh-token-not-real")
        #expect(token.expiresIn == 3600)
    }
    #endif


    @Test
    func testFieldDecodesWrappedValueShape() throws {
        let json = #"{"value": 72.5, "status": "OK", "updatedAt": "2026-08-15T10:00:00Z"}"#
        let field = try JSONDecoder.volvo.decode(VolvoField<Double>.self, from: Data(json.utf8))
        #expect(field.value == 72.5)
        #expect(field.status == "OK")
        #expect(field.updatedAt != nil)
    }

    @Test
    func testFieldFallsBackToBareScalar() throws {
        let json = "42"
        let field = try JSONDecoder.volvo.decode(VolvoField<Int>.self, from: Data(json.utf8))
        #expect(field.value == 42)
        #expect(field.status == nil)
    }

    @Test
    func testVolvoDistanceAndConsumptionUnitsNormalizeToDomainUnits() throws {
        let energyJSON = #"{"electricRange":{"value":100,"unit":"mi"},"chargingPower":{"value":7.4,"unit":"kW"}}"#
        let energy = try JSONDecoder.volvo.decode(VolvoEnergyStateDTO.self, from: Data(energyJSON.utf8))
        #expect(energy.rangeKm == 161)
        #expect(energy.chargingPowerWatts == 7_400)

        let statsJSON = #"{"tripMeterAutomatic":{"value":10,"unit":"mi"},"averageEnergyConsumption":{"value":200,"unit":"Wh/km"},"averageSpeed":{"value":50,"unit":"mph"}}"#
        let stats = try JSONDecoder.volvo.decode(VolvoStatisticsDTO.self, from: Data(statsJSON.utf8))
        #expect(stats.tripMeterAutomaticKm?.rounded() == 16)
        #expect(stats.averageEnergyConsumptionKwhPer100Km == 20)
        #expect(stats.averageSpeedKmH?.rounded() == 80)
    }

    @Test
    func testEnvelopeUnwrapsDataKey() throws {
        struct Payload: Decodable, Equatable { let vin: String }
        let json = #"{"data": {"vin": "FIXTURE"}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: Data(json.utf8))
        #expect(envelope.data == Payload(vin: "FIXTURE"))
    }

    @Test
    func testEnvelopeFallsBackToBareRoot() throws {
        struct Payload: Decodable, Equatable { let vin: String }
        let json = #"{"vin": "FIXTURE"}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<Payload>.self, from: Data(json.utf8))
        #expect(envelope.data == Payload(vin: "FIXTURE"))
    }

    @Test
    func testPowertrainClassification() {
        #expect(VolvoPowertrain.classify(fuelType: "NONE") == .unknown)
        #expect(VolvoPowertrain.classify(fuelType: "ELECTRIC") == .bev)
        #expect(VolvoPowertrain.classify(fuelType: "PETROL/ELECTRIC") == .phev)
        #expect(VolvoPowertrain.classify(fuelType: "PETROL") == .ice)
        #expect(VolvoPowertrain.classify(fuelType: "DIESEL") == .ice)
        #expect(VolvoPowertrain.classify(fuelType: nil) == .unknown)
        #expect(VolvoPowertrain.classify(fuelType: "PETROL MHEV") == .mildHybrid)
    }

    @Test
    func testChargingStateMapping() {
        #expect(ChargingState(volvoChargingStatus: "CHARGING") == .charging)
        #expect(ChargingState(volvoChargingStatus: "DONE") == .complete)
        #expect(ChargingState(volvoChargingStatus: "IDLE") == .idle)
        #expect(ChargingState(volvoChargingStatus: nil) == .unknown("UNSPECIFIED"))


        #expect(ChargingState(volvoChargingStatus: "SOME_NEW_STATE") == .unknown("SOME_NEW_STATE"))
    }

    @Test
    func testChargerConnectionMapping() {
        #expect(ChargerConnection(volvoConnectionStatus: "CONNECTED") == .connected)
        #expect(ChargerConnection(volvoConnectionStatus: "DISCONNECTED") == .disconnected)
        #expect(ChargerConnection(volvoConnectionStatus: nil) == .unknown)
    }

    @Test
    func testOpeningStateMapping() {
        #expect(OpeningState(volvoStatus: "OPEN") == .open)
        #expect(OpeningState(volvoStatus: "CLOSED") == .closed)
        #expect(OpeningState(volvoStatus: "AJAR") == .ajar)
        #expect(OpeningState(volvoStatus: nil) == nil)
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
        let warnings = try #require(envelope.data)
        #expect(warnings.activeWarnings.count == 4)
        #expect(warnings.activeWarnings.contains(where: { $0.contains("Left brake light") }))
        #expect(warnings.activeWarnings.contains(where: { $0.contains("Right high beam") }))
        #expect(warnings.activeWarnings.contains(where: { $0.contains("Hazard warning lights") }))
        #expect(warnings.activeWarnings.contains(where: { $0.contains("Reverse light") }))
        #expect(warnings.hasReportedLightStatus)
    }

    @Test
    func testEngineStatusPreservesUnknownInsteadOfAssumingStopped() throws {
        let running = try JSONDecoder.volvo.decode(VolvoEngineStatusDTO.self, from: Data(#"{"engineStatus":{"value":"RUNNING"}}"#.utf8))
        let stopped = try JSONDecoder.volvo.decode(VolvoEngineStatusDTO.self, from: Data(#"{"engineStatus":{"value":"STOPPED"}}"#.utf8))
        let unspecified = try JSONDecoder.volvo.decode(VolvoEngineStatusDTO.self, from: Data(#"{"engineStatus":{"value":"UNSPECIFIED"}}"#.utf8))
        #expect(running.isRunning == true)
        #expect(stopped.isRunning == false)
        #expect(unspecified.isRunning == nil)
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
        let dto = try #require(envelope.data)
        #expect(dto.brakeFluidLevelWarning?.value == "WARNING")
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
        let dto = try #require(envelope.data)
        #expect(dto.isRunning == true)
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
        let dto = try #require(envelope.data)
        #expect(dto.isAvailable)
    }

    @Test
    func testCommandAccessibilityPreservesUnavailableReason() throws {
        let json = #"{"data":{"availabilityStatus":{"value":"UNAVAILABLE","unavailableReason":"POWER_SAVING_MODE"}}}"#
        let envelope = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoCommandAccessibilityDTO>.self, from: Data(json.utf8))
        let dto = try #require(envelope.data)
        #expect(!(dto.isAvailable))
        #expect(dto.reason == L10n.text("Vehicle is in power-saving mode"))
    }

    @Test
    func testDocumentedCommandFailuresAreRejected() throws {
        // The full documented Connected Vehicle API v2 `invokeStatus` failure set.
        let failing = [
            "REJECTED", "TIMEOUT", "CONNECTION_FAILURE", "VEHICLE_IN_SLEEP", "CAR_ERROR",
            "NOT_ALLOWED_PRIVACY_ENABLED", "NOT_ALLOWED_WRONG_USAGE_MODE",
            "UNABLE_TO_LOCK_DOOR_OPEN", "UNLOCK_TIME_FRAME_PASSED"
        ]
        for status in failing {
            let response = try JSONDecoder.volvo.decode(
                VolvoCommandResponseDTO.self, from: Data("{\"invokeStatus\":\"\(status)\"}".utf8))
            #expect(response.isFailure, "\(status) should be a failure")
            #expect(response.failureReason != nil, "\(status) should carry a user-facing reason")
        }
    }

    @Test
    func testInProgressAndUnknownCommandStatusesAreNotFailures() throws {
        for status in ["RUNNING", "WAITING", "COMPLETED", "DELIVERED", "UNKNOWN"] {
            let response = try JSONDecoder.volvo.decode(
                VolvoCommandResponseDTO.self, from: Data("{\"invokeStatus\":\"\(status)\"}".utf8))
            #expect(!(response.isFailure), "\(status) must not be treated as a rejection")
            #expect(response.failureReason == nil)
        }
    }

    @Test
    func testSleepAndPrivacyStatusesGetSpecificMessages() throws {
        let sleep = try JSONDecoder.volvo.decode(
            VolvoCommandResponseDTO.self, from: Data(#"{"invokeStatus":"VEHICLE_IN_SLEEP"}"#.utf8))
        #expect(sleep.failureReason?.contains("sleep") == true)
        let privacy = try JSONDecoder.volvo.decode(
            VolvoCommandResponseDTO.self, from: Data(#"{"invokeStatus":"NOT_ALLOWED_PRIVACY_ENABLED"}"#.utf8))
        #expect(privacy.failureReason?.lowercased().contains("privacy") == true)
    }

    @Test
    func testVehicleDetailsAcceptsExternalColoursArray() throws {
        let json = #"""
        {"data":{"vin":"YV1TEST","modelYear":2024,
          "externalColours":[{"value":"Vapour Grey"},{"value":"Onyx Black"}]}}
        """#
        let envelope = try JSONDecoder.volvo.decode(
            VolvoEnvelope<VolvoVehicleDetailsDTO>.self, from: Data(json.utf8))
        #expect(envelope.data?.externalColour == "Vapour Grey")

        let flat = try JSONDecoder.volvo.decode(
            VolvoEnvelope<VolvoVehicleDetailsDTO>.self,
            from: Data(#"{"data":{"vin":"YV1TEST","externalColour":"Fjord Blue"}}"#.utf8))
        #expect(flat.data?.externalColour == "Fjord Blue")
    }

    @Test
    func testVolvoNullLiteralStringsAreTreatedAsAbsent() {
        // Volvo serialises `descriptions.upholstery` as the literal string "null" (live).
        #expect(Optional("null").volvoMeaningful == nil)
        #expect(Optional("NULL").volvoMeaningful == nil)
        #expect(Optional("  ").volvoMeaningful == nil)
        #expect(String?.none.volvoMeaningful == nil)
        #expect(Optional("Charcoal Nubuck").volvoMeaningful == "Charcoal Nubuck")
    }

    @Test
    func testCommandNamePrefersHrefEndpointSegment() throws {
        // Live: command list reports HONK_AND_FLASH but the real invocation path is honk-flash.
        let json = #"[{"command":"HONK_AND_FLASH","href":"/v2/vehicles/X/commands/honk-flash"}]"#
        let list = try JSONDecoder.volvo.decode([VolvoCommandDTO].self, from: Data(json.utf8))
        #expect(list.first?.normalizedName == "honk-flash")
        // No href → fall back to the (normalised) command label.
        let noHref = try JSONDecoder.volvo.decode(
            [VolvoCommandDTO].self, from: Data(#"[{"command":"LOCK_REDUCED_GUARD"}]"#.utf8))
        #expect(noHref.first?.normalizedName == "lock-reduced-guard")
    }

    @Test
    func testChargerPowerStateMapsNoPowerAvailable() {
        #expect(ChargerPowerState(volvoPowerStatus: "NO_POWER_AVAILABLE") == .noPower)
        #expect(ChargerPowerState(volvoPowerStatus: "PROVIDING_POWER") == .providingPower)
    }

    @Test
    func testTyreSensorFaultIsDistinctFromUnknown() throws {
        let json = #"""
        {"data":{"frontLeft":{"value":"NO_SENSOR"},"frontRight":{"value":"SYSTEM_FAULT"},
          "rearLeft":{"value":"NO_WARNING"},"rearRight":{"value":"LOW"}}}
        """#
        let tyres = try JSONDecoder.volvo.decode(VolvoEnvelope<VolvoTyresDTO>.self, from: Data(json.utf8))
        let readings = try #require(tyres.data).readings
        #expect(readings.first(where: { $0.position == .frontLeft })?.warning == .sensorFault)
        #expect(readings.first(where: { $0.position == .frontRight })?.warning == .sensorFault)
        #expect(readings.first(where: { $0.position == .rearLeft })?.warning == TyrePressureWarning.none)
        #expect(readings.first(where: { $0.position == .rearRight })?.warning == .low)
        #expect(!(TyrePressureWarning.sensorFault.needsAttention))
    }

    @Test
    func testStagedUnlockResponseDecodes() throws {
        let json = #"{"invokeStatus":"DELIVERED","readyToUnlock":true,"readyToUnlockUntil":120}"#
        let response = try JSONDecoder.volvo.decode(VolvoCommandResponseDTO.self, from: Data(json.utf8))
        #expect(response.outcome == .delivered)
        #expect(response.readyToUnlockUntil == 120)
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
        state.maintenance.service.trigger = "CALENDAR_TIME"
        state.identity.steeringOrientation = "Left"
        state.identity.upholstery = "Nordico"
        state.tripComputer.electricRangeKm = 310
        state.energy.currentLimitAmps = 32

        #expect(state.formattedServiceTrigger == "Time")
        #expect(state.formattedSteeringOrientation == "Left-hand drive")
        #expect(state.identity.upholstery == "Nordico")
        #expect(state.tripComputer.electricRangeKm == 310)
        #expect(state.energy.currentLimitAmps == 32)
    }
}
