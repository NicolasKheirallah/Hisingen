import Foundation
import Testing
@testable import Hisingen

struct VehicleCrossModelTests {

    @Test
    func testModelFamilyIdentification() {
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 2"), .polestar2)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 2 Long Range Dual Motor"), .polestar2)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 2 BST edition 270"), .polestar2)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 3"), .polestar3)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 4"), .polestar4)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 4 Long Range"), .polestar4)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 1"), .polestar1)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 5"), .polestar5)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 6"), .polestar6)
        XCTAssertEqual(VehicleModelFamily(modelName: "Unknown Prototype"), .unknown("Unknown Prototype"))
        XCTAssertEqual(VehicleModelFamily(modelName: nil), .unknown(nil))
    }

    @Test
    func testPolestar2CapabilityProfile() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        XCTAssertFalse(profile.hasSelectableClimateTemperature)
        XCTAssertFalse(profile.hasSelectableSeatHeating)
        XCTAssertEqual(profile.support(for: .climateTemperature), .vehicleManaged)
        XCTAssertEqual(profile.support(for: .seatHeating), .vehicleManaged)
        XCTAssertEqual(profile.support(for: .steeringWheelHeating), .vehicleManaged)
        XCTAssertEqual(profile.support(for: .chargingCurrentLimit), .supported)
        XCTAssertEqual(profile.support(for: .preCleaning), .supported)
        XCTAssertEqual(profile.support(for: .tyrePressureValues), .unavailable)
        XCTAssertEqual(profile.support(for: .climateStartStop), .supported)
        XCTAssertEqual(profile.support(for: .locks), .supported)
        XCTAssertEqual(profile.support(for: .windows), .supported)
        XCTAssertEqual(profile.support(for: .honkAndFlash), .unavailable)
    }

    @Test
    func testPolestar4CapabilityProfile() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        XCTAssertTrue(profile.hasSelectableClimateTemperature)
        XCTAssertTrue(profile.hasSelectableSeatHeating)
        XCTAssertEqual(profile.support(for: .climateTemperature), .supported)
        XCTAssertEqual(profile.support(for: .seatHeating), .supported)
        XCTAssertEqual(profile.support(for: .steeringWheelHeating), .supported)
        XCTAssertEqual(profile.support(for: .chargingCurrentLimit), .unavailable)
        XCTAssertEqual(profile.support(for: .preCleaning), .unavailable)
        XCTAssertEqual(profile.support(for: .connectivity), .unavailable)
        XCTAssertEqual(profile.support(for: .softwareInstallControl), .unavailable)
        XCTAssertEqual(profile.support(for: .tyrePressureValues), .supported)
        XCTAssertEqual(profile.support(for: .climateStartStop), .supported)
        XCTAssertEqual(profile.support(for: .locks), .supported)
    }

    @Test
    func testPolestar3CapabilityProfile() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 3")
        XCTAssertTrue(profile.hasSelectableClimateTemperature)
        XCTAssertTrue(profile.hasSelectableSeatHeating)
        XCTAssertEqual(profile.support(for: .climateTemperature), .supported)
        XCTAssertEqual(profile.support(for: .seatHeating), .supported)
        XCTAssertEqual(profile.support(for: .climateStartStop), .supported)
    }

    @Test
    func testCommandAdaptationForPolestar2StripsUnsupportedParameters() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        let richCommand = RemoteCommand.startClimate(
            temperatureCelsius: 21.5,
            frontLeftSeat: .level3,
            frontRightSeat: .level2,
            rearLeftSeat: .level1,
            rearRightSeat: .off,
            steeringWheel: .level2
        )
        let adapted = richCommand.adapted(to: profile)
        guard case .startClimate(let temp, let fl, let fr, let rl, let rr, let sw) = adapted else {
            return XCTFail("Expected startClimate command")
        }
        XCTAssertEqual(temp, 0.0)
        XCTAssertEqual(fl, HeatingLevel.unspecified)
        XCTAssertEqual(fr, HeatingLevel.unspecified)
        XCTAssertEqual(rl, HeatingLevel.unspecified)
        XCTAssertEqual(rr, HeatingLevel.unspecified)
        XCTAssertEqual(sw, HeatingLevel.unspecified)
        XCTAssertEqual(adapted.title, "Start climate (automatic)")
    }

    @Test
    func testCommandAdaptationForPolestar4PreservesAllParameters() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        let richCommand = RemoteCommand.startClimate(
            temperatureCelsius: 20.5,
            frontLeftSeat: .level3,
            frontRightSeat: .level2,
            rearLeftSeat: .level1,
            rearRightSeat: .off,
            steeringWheel: .level2
        )
        let adapted = richCommand.adapted(to: profile)
        guard case .startClimate(let temp, let fl, let fr, let rl, let rr, let sw) = adapted else {
            return XCTFail("Expected startClimate command")
        }
        XCTAssertEqual(temp, 20.5)
        XCTAssertEqual(fl, HeatingLevel.level3)
        XCTAssertEqual(fr, HeatingLevel.level2)
        XCTAssertEqual(rl, HeatingLevel.level1)
        XCTAssertEqual(rr, HeatingLevel.off)
        XCTAssertEqual(sw, HeatingLevel.level2)
        XCTAssertEqual(adapted.title, L10n.format("Start climate at %.1f °C", 20.5))
    }

    @Test
    func testCrossVehicleSwitchingIsolation() {
        let p4State = makeVehicleState(vin: "YS2P4000000000001", modelName: "Polestar 4", battery: 78.0)
        XCTAssertTrue(p4State.capabilityProfile.hasSelectableClimateTemperature)
        XCTAssertFalse(p4State.capabilityProfile.permits(VehicleCapability.chargingCurrentLimit))

        let p2State = makeVehicleState(vin: "YS2P2000000000002", modelName: "Polestar 2", battery: 55.0)
        XCTAssertFalse(p2State.capabilityProfile.hasSelectableClimateTemperature)
        XCTAssertTrue(p2State.capabilityProfile.permits(VehicleCapability.chargingCurrentLimit))


        let merged = p2State.mergingLastKnown(from: p4State, features: FeatureSelection.default)
        XCTAssertEqual(merged.vin, "YS2P2000000000002")
        XCTAssertEqual(merged.modelName, "Polestar 2")
        XCTAssertEqual(merged.batteryPercentage, 55.0)
        XCTAssertFalse(merged.capabilityProfile.hasSelectableClimateTemperature)
    }

    @Test
    func testVehicleBuildOptionsAndSpecs() {
        var state = makeVehicleState(vin: "YS2P2000000000001", modelName: "Polestar 2", battery: 78.0)
        state.externalColour = "Thunder Grey"
        state.upholstery = "WeaveTech Charcoal"
        state.wheels = "20\" 4-V Spoke"
        state.packages = ["Pilot", "Plus", "Performance"]
        state.structureWeek = "202342"
        state.gearbox = "1-speed automatic"
        state.reportedBatteryCapacityKwh = 78.0

        XCTAssertEqual(state.externalColour, "Thunder Grey")
        XCTAssertEqual(state.upholstery, "WeaveTech Charcoal")
        XCTAssertEqual(state.wheels, "20\" 4-V Spoke")
        XCTAssertEqual(state.packages.count, 3)
        XCTAssertEqual(state.formattedBuildWeek, "2023 · W42")
        XCTAssertEqual(state.reportedBatteryCapacityKwh, 78.0)
    }

    @Test
    func testVehicleInfoTabFieldCompleteness() {
        var state = makeVehicleState(vin: "YS2ED400000000002", modelName: "Polestar 2 Long Range Dual Motor", battery: 72.0)
        state.externalColour = "Thunder"
        state.upholstery = "Charcoal Embossed Textile"
        state.wheels = "19\" 5-Double Spoke Black Diamond Cut"
        state.packages = ["Pilot Pack", "Plus Pack"]
        state.structureWeek = "202401"
        state.pno34 = "P20412"
        state.internalVehicleIdentifier = "V-12345"
        state.accountMarket = "SE"
        state.gearbox = "automatic"
        state.steeringOrientation = "LEFT_HAND_DRIVE"
        state.reportedBatteryCapacityKwh = 78.0
        state.airQuality = VehicleAirQuality(
            cleaningState: .on,
            airQualityIndex: 12,
            particulateMatter25: 3,
            externalParticulateMatter25: 18,
            filterRemainingPercent: 94
        )
        state.location = VehicleLocation(
            latitude: 57.7089,
            longitude: 11.9746,
            altitudeMeters: 45.0,
            accuracyMeters: 3.5,
            parkingBrakeEngaged: true,
            gear: "P"
        )
        state.climateStatus = VehicleClimateStatus(
            activity: .heating,
            timeRemainingMinutes: 15,
            timerTriggered: false,
            interiorTemperatureCelsius: 19.5,
            requestedTemperatureCelsius: 21.0,
            driverSeatHeatingLevel: 2,
            passengerSeatHeatingLevel: 1,
            steeringWheelHeatingLevel: 1
        )

        XCTAssertEqual(state.externalColour, "Thunder")
        XCTAssertEqual(state.upholstery, "Charcoal Embossed Textile")
        XCTAssertEqual(state.wheels, "19\" 5-Double Spoke Black Diamond Cut")
        XCTAssertEqual(state.packages.count, 2)
        XCTAssertEqual(state.formattedBuildWeek, "2024 · W01")
        XCTAssertEqual(state.pno34, "P20412")
        XCTAssertEqual(state.formattedSteeringOrientation, "Left_Hand_Drive")
        XCTAssertEqual(state.airQuality?.airQualityIndex, 12)
        XCTAssertEqual(state.airQuality?.particulateMatter25, 3)
        XCTAssertEqual(state.airQuality?.externalParticulateMatter25, 18)
        XCTAssertEqual(state.airQuality?.filterRemainingPercent, 94)
        XCTAssertEqual(state.location?.parkingBrakeEngaged, true)
        XCTAssertEqual(state.climateStatus?.requestedTemperatureCelsius, 21.0)
        XCTAssertEqual(state.climateStatus?.driverSeatHeatingLevel, 2)
        XCTAssertEqual(state.model.nominalWltpRangeKm, 480.0)
        XCTAssertEqual(state.model.nominalBatteryCapacityKwh, 78.0)
    }

    @Test
    func testBatteryStateOfHealthAndDegradationCalculations() {
        var my23State = VehicleState(
            batteryPercentage: 85.0, rangeKm: 380, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 90,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "Polestar 2", modelYear: "2023", registrationNo: "ZCJ06G",
            vin: "YSMVSEDE6PL147228", ownerFirstName: "Nico", odometerKm: 35000,
            daysToService: 180, distanceToServiceKm: 15000, serviceWarning: false,
            fluidWarnings: [], powertrain: .bev, reportedBatteryCapacityKwh: nil,
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: []
        )
        my23State.structureWeek = "202240"

        XCTAssertEqual(my23State.factoryNominalBatteryCapacityKwh, 78.0)
        XCTAssertEqual(my23State.factoryUsableBatteryCapacityKwh, 75.0)
        XCTAssertTrue(my23State.batteryPackDescription.contains("78.0 kWh Long Range"))
        XCTAssertTrue(my23State.batteryDegradationPercent! >= 1.0 && my23State.batteryDegradationPercent! <= 10.0)
        XCTAssertTrue(my23State.batteryStateOfHealthPercent! >= 90.0 && my23State.batteryStateOfHealthPercent! < 100.0)
        XCTAssertEqual(my23State.batteryHealthStatus, "Optimal")
        XCTAssertTrue(my23State.effectiveUsableBatteryCapacityKwh > 70.0 && my23State.effectiveUsableBatteryCapacityKwh < 75.0)
    }

    @Test
    func testChargingSessionSynthesisWithEffectiveCapacity() {
        var startState = makeVehicleState(
            vin: "YSMVSEDE6PL147228",
            modelName: "Polestar 2",
            battery: 20.0,
            chargingState: .charging,
            chargerConnection: .connected,
            powerWatts: 11000
        )
        startState.chargingSamples = [
            ChargingSample(timestamp: Date().addingTimeInterval(-3600), batteryPercentage: 20.0, powerWatts: 11000),
            ChargingSample(timestamp: Date().addingTimeInterval(-1800), batteryPercentage: 50.0, powerWatts: 11000)
        ]

        let endState = makeVehicleState(
            vin: "YSMVSEDE6PL147228",
            modelName: "Polestar 2",
            battery: 80.0,
            chargingState: .idle,
            chargerConnection: .connected
        )

        let session = ChargingSession.completed(previous: startState, current: endState, pricePerKwh: 2.50)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.startBatteryPercentage, 20.0)
        XCTAssertEqual(session?.endBatteryPercentage, 80.0)
        // 60% of 75.0 kWh usable = 45.0 kWh
        XCTAssertEqual(session?.kwhDelivered, 45.0)
        XCTAssertEqual(session?.cost, 45.0 * 2.50)
    }

    @Test
    func testWorkshopIDAndPlugInReminder() {
        var state = makeVehicleState(vin: "YSMVSEDE6PL147228", modelName: "Polestar 2", battery: 35.0)
        state.preferredWorkshopId = "SE-GOT-001"
        state.preferredWorkshopName = "Bilia Sisjön"
        XCTAssertEqual(state.preferredWorkshopId, "SE-GOT-001")
        XCTAssertEqual(state.preferredWorkshopName, "Bilia Sisjön")

        XCTAssertTrue(Notifier.plugInReminderCondition(state))

        let pluggedIn = makeVehicleState(
            vin: "YSMVSEDE6PL147228",
            modelName: "Polestar 2",
            battery: 35.0,
            chargerConnection: .connected
        )
        XCTAssertFalse(Notifier.plugInReminderCondition(pluggedIn))

        let fullBattery = makeVehicleState(
            vin: "YSMVSEDE6PL147228",
            modelName: "Polestar 2",
            battery: 75.0,
            chargerConnection: .disconnected
        )
        XCTAssertFalse(Notifier.plugInReminderCondition(fullBattery))
    }

    private func makeVehicleState(
        vin: String,
        modelName: String,
        battery: Double,
        chargingState: ChargingState = .idle,
        chargerConnection: ChargerConnection = .disconnected,
        powerWatts: Int? = nil
    ) -> VehicleState {
        VehicleState(
            batteryPercentage: battery,
            rangeKm: 350,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: powerWatts,
            chargingCurrentAmps: 16,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: chargerConnection,
            availability: .available,
            modelName: modelName,
            modelYear: "2024",
            registrationNo: "TEST123",
            vin: vin,
            ownerFirstName: "Nico",
            odometerKm: 25000,
            daysToService: 120,
            distanceToServiceKm: 5000,
            serviceWarning: false,
            fluidWarnings: [],
            powertrain: .bev,
            reportedBatteryCapacityKwh: 75.0,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )
    }
}



