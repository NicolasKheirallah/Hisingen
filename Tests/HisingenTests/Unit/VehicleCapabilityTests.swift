import Foundation
import Testing
@testable import Hisingen

struct VehicleCapabilityTests {
    @Test
    func modelNamesAreNormalized() {
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar 2"), .polestar2)
        XCTAssertEqual(VehicleModelFamily(modelName: "PS4"), .polestar4)
        XCTAssertEqual(VehicleModelFamily(modelName: "Polestar Four"), .polestar4)
        XCTAssertEqual(VehicleModelFamily(modelName: nil), .unknown(nil))
    }

    @Test
    func polestar2UsesVehicleManagedClimateTarget() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        XCTAssertEqual(profile.support(for: .climateStartStop), .supported)
        XCTAssertEqual(profile.support(for: .climateTemperature), .vehicleManaged)
        XCTAssertFalse(profile.hasSelectableClimateTemperature)

        let requested = RemoteCommand.startClimate(
            temperatureCelsius: 23,
            frontLeftSeat: .level3, frontRightSeat: .level2,
            rearLeftSeat: .level1, rearRightSeat: .off,
            steeringWheel: .level3
        )
        let adapted = requested.adapted(to: profile)
        guard case .startClimate(let temperature, let frontLeft, let frontRight,
                                 let rearLeft, let rearRight, let steering) = adapted else {
            return XCTFail("Expected climate command")
        }
        XCTAssertEqual(temperature, 0)
        XCTAssertEqual(frontLeft, .unspecified)
        XCTAssertEqual(frontRight, .unspecified)
        XCTAssertEqual(rearLeft, .unspecified)
        XCTAssertEqual(rearRight, .unspecified)
        XCTAssertEqual(steering, .unspecified)
    }

    @Test
    func polestar4SupportsSelectableClimateButNotAmpLimit() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        XCTAssertEqual(profile.support(for: .climateTemperature), .supported)
        XCTAssertEqual(profile.support(for: .seatHeating), .supported)
        XCTAssertEqual(profile.support(for: .chargingCurrentLimit), .unavailable)
        XCTAssertEqual(profile.support(for: .preCleaning), .unavailable)
        XCTAssertFalse(profile.permits(.chargingCurrentLimit))
    }

    @Test
    func automaticClimateWireRequestOmitsUnsupportedSelections() {
        let data = PolestarGRPC.climateStartRequest(
            vin: "TESTVIN", temperature: 0,
            frontLeft: .unspecified, frontRight: .unspecified,
            rearLeft: .unspecified, rearRight: .unspecified,
            steeringWheel: .unspecified
        )
        let fields = Protobuf.fields(data)
        XCTAssertEqual(fields.first { $0.number == 2 }?.varint, 1)
        for field in 3...8 {
            XCTAssertNil(fields.first { $0.number == field })
        }
    }

    @Test
    func unknownModelsRemainProbeable() {
        let profile = VehicleCapabilityProfile(modelName: "Future vehicle")
        XCTAssertEqual(profile.support(for: .climateTemperature), .backendDependent)
        XCTAssertTrue(profile.permits(.climateTemperature))
    }

    @Test
    func unknownModelPreservesOriginalName() {
        let model = VehicleModelFamily(modelName: "Polestar 7 Synergy")
        guard case .unknown(let name) = model else {
            return XCTFail("Expected unknown model")
        }
        XCTAssertEqual(name, "Polestar 7 Synergy")
        XCTAssertEqual(model.displayName, "Polestar 7 Synergy")
        XCTAssertFalse(model.isKnown)
    }

    @Test
    func polestar2DoesNotShowClimateTemperatureControl() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        XCTAssertTrue(profile.permits(.climateStartStop))
        XCTAssertFalse(profile.hasSelectableClimateTemperature)
    }

    @Test
    func polestar4ShowsClimateTemperatureControl() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        XCTAssertTrue(profile.permits(.climateStartStop))
        XCTAssertTrue(profile.hasSelectableClimateTemperature)
        XCTAssertTrue(profile.hasSelectableSeatHeating)
    }

    @Test
    func polestar4HidesChargingCurrentLimitAndPreCleaning() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        XCTAssertFalse(profile.permits(.chargingCurrentLimit))
        XCTAssertFalse(profile.permits(.preCleaning))
        XCTAssertFalse(profile.permits(.connectivity))
        XCTAssertFalse(profile.permits(.softwareInstallControl))
    }

    @Test
    func polestar2TyrePressureValuesAreProbedNotAssumed() {
        // The MY23 reference car reported warning level only, but that is a backend fact for
        // one car — the profile must not hard-block numeric pressures for every Polestar 2.
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        XCTAssertEqual(profile.support(for: .tyrePressureValues), .backendDependent)
        XCTAssertTrue(profile.permits(.tyrePressureValues))
    }

    @Test
    func featureStatusDistinguishesCapabilityFromAvailability() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        let onlineState = vehicle(vin: "VIN-P4")
        let status = profile.featureStatus(for: .climateStartStop, in: onlineState)
        XCTAssertTrue(status.isVisible)
        XCTAssertTrue(status.isUsable)
    }

    @Test
    func featureStatusReportsOfflineWhenVehicleUnavailable() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        var offlineState = vehicle(vin: "VIN-P4")
        offlineState = VehicleState(
            batteryPercentage: offlineState.batteryPercentage, rangeKm: offlineState.rangeKm,
            chargingState: offlineState.chargingState,
            estimatedChargingTimeToFullMinutes: offlineState.estimatedChargingTimeToFullMinutes,
            chargeTargetPercentage: offlineState.chargeTargetPercentage,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .unknown,
            availability: .unavailable(reason: "Power saving"),
            modelName: "Polestar 4", modelYear: nil, registrationNo: nil,
            vin: "VIN-P4", ownerFirstName: nil, odometerKm: nil,
            daysToService: nil, distanceToServiceKm: nil, serviceWarning: false,
            fluidWarnings: [], imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )
        let status = profile.featureStatus(for: .climateStartStop, in: offlineState)
        XCTAssertTrue(status.isVisible)
        XCTAssertFalse(status.isUsable)
        XCTAssertEqual(status.availability, .vehicleOffline)
    }

    @Test
    func unsupportedCapabilityIsNeverUsable() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        let state = vehicle(vin: "VIN-P4")
        let status = profile.featureStatus(for: .chargingCurrentLimit, in: state)
        XCTAssertFalse(status.isVisible)
        XCTAssertFalse(status.isUsable)
    }

    @Test
    func volvoXC40AndEX40HideSelectableTemperatureAndSeatHeating() {
        let xc40Profile = VehicleCapabilityProfile(modelName: "XC40 Recharge")
        XCTAssertFalse(xc40Profile.hasSelectableClimateTemperature)
        XCTAssertFalse(xc40Profile.hasSelectableSeatHeating)
        XCTAssertFalse(xc40Profile.hasSelectableSteeringWheelHeating)
        XCTAssertTrue(xc40Profile.permits(.climateStartStop))
        XCTAssertTrue(xc40Profile.permits(.locks))
        XCTAssertTrue(xc40Profile.permits(.honkAndFlash))
        XCTAssertFalse(xc40Profile.permits(.chargeTarget))
        XCTAssertFalse(xc40Profile.permits(.chargingCurrentLimit))

        let ex40Profile = VehicleCapabilityProfile(modelName: "EX40 Single Motor")
        XCTAssertFalse(ex40Profile.hasSelectableClimateTemperature)
        XCTAssertFalse(ex40Profile.hasSelectableSeatHeating)
        XCTAssertFalse(ex40Profile.hasSelectableSteeringWheelHeating)
        XCTAssertTrue(ex40Profile.permits(.climateStartStop))
    }

    @Test
    func volvoEX30AndEX90ShowSelectableTemperatureAndSeatHeating() {
        let ex30Profile = VehicleCapabilityProfile(modelName: "EX30 Ultra")
        XCTAssertTrue(ex30Profile.hasSelectableClimateTemperature)
        XCTAssertTrue(ex30Profile.hasSelectableSeatHeating)
        XCTAssertTrue(ex30Profile.hasSelectableSteeringWheelHeating)
        XCTAssertTrue(ex30Profile.permits(.climateStartStop))

        let ex90Profile = VehicleCapabilityProfile(modelName: "EX90 Twin Motor")
        XCTAssertTrue(ex90Profile.hasSelectableClimateTemperature)
        XCTAssertTrue(ex90Profile.hasSelectableSeatHeating)
        XCTAssertTrue(ex90Profile.hasSelectableSteeringWheelHeating)
        XCTAssertTrue(ex90Profile.permits(.climateStartStop))
    }
}


