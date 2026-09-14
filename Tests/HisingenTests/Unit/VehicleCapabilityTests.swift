import Foundation
import Testing
@testable import Hisingen

struct VehicleCapabilityTests {
    @Test
    func modelNamesAreNormalized() {
        #expect(VehicleModelFamily(modelName: "Polestar 2") == .polestar2)
        #expect(VehicleModelFamily(modelName: "PS4") == .polestar4)
        #expect(VehicleModelFamily(modelName: "Polestar Four") == .polestar4)
        #expect(VehicleModelFamily(modelName: nil) == .unknown(nil))
    }

    @Test
    func polestar2UsesVehicleManagedClimateTarget() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        #expect(profile.support(for: .climateStartStop) == .supported)
        #expect(profile.support(for: .climateTemperature) == .vehicleManaged)
        #expect(!(profile.hasSelectableClimateTemperature))

        let requested = RemoteCommand.startClimate(
            temperatureCelsius: 23,
            frontLeftSeat: .level3, frontRightSeat: .level2,
            rearLeftSeat: .level1, rearRightSeat: .off,
            steeringWheel: .level3
        )
        let adapted = requested.adapted(to: profile)
        guard case .startClimate(let temperature, let frontLeft, let frontRight,
                                 let rearLeft, let rearRight, let steering) = adapted else {
            Issue.record("Expected climate command")
            return
        }
        #expect(temperature == 0)
        #expect(frontLeft == .unspecified)
        #expect(frontRight == .unspecified)
        #expect(rearLeft == .unspecified)
        #expect(rearRight == .unspecified)
        #expect(steering == .unspecified)
    }

    @Test
    func polestar4SupportsSelectableClimateButNotAmpLimit() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        #expect(profile.support(for: .climateTemperature) == .supported)
        #expect(profile.support(for: .seatHeating) == .supported)
        #expect(profile.support(for: .chargingCurrentLimit) == .unavailable)
        #expect(profile.support(for: .preCleaning) == .unavailable)
        #expect(!(profile.permits(.chargingCurrentLimit)))
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
        #expect(fields.first { $0.number == 2 }?.varint == 1)
        for field in 3...8 {
            #expect(fields.first { $0.number == field } == nil)
        }
    }

    @Test
    func unknownModelsRemainProbeable() {
        let profile = VehicleCapabilityProfile(modelName: "Future vehicle")
        #expect(profile.support(for: .climateTemperature) == .backendDependent)
        #expect(profile.permits(.climateTemperature))
    }

    @Test
    func unknownModelPreservesOriginalName() {
        let model = VehicleModelFamily(modelName: "Polestar 7 Synergy")
        guard case .unknown(let name) = model else {
            Issue.record("Expected unknown model")
            return
        }
        #expect(name == "Polestar 7 Synergy")
        #expect(model.displayName == "Polestar 7 Synergy")
        #expect(!(model.isKnown))
    }

    @Test
    func polestar2DoesNotShowClimateTemperatureControl() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        #expect(profile.permits(.climateStartStop))
        #expect(!(profile.hasSelectableClimateTemperature))
    }

    @Test
    func polestar4ShowsClimateTemperatureControl() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        #expect(profile.permits(.climateStartStop))
        #expect(profile.hasSelectableClimateTemperature)
        #expect(profile.hasSelectableSeatHeating)
    }

    @Test
    func polestar4HidesChargingCurrentLimitAndPreCleaning() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        #expect(!(profile.permits(.chargingCurrentLimit)))
        #expect(!(profile.permits(.preCleaning)))
        #expect(!(profile.permits(.connectivity)))
        #expect(!(profile.permits(.softwareInstallControl)))
    }

    @Test
    func polestar2TyrePressureValuesAreProbedNotAssumed() {
        // The MY23 reference car reported warning level only, but that is a backend fact for
        // one car — the profile must not hard-block numeric pressures for every Polestar 2.
        let profile = VehicleCapabilityProfile(modelName: "Polestar 2")
        #expect(profile.support(for: .tyrePressureValues) == .backendDependent)
        #expect(profile.permits(.tyrePressureValues))
    }

    @Test
    func featureStatusDistinguishesCapabilityFromAvailability() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        let onlineState = vehicle(vin: "VIN-P4")
        let status = profile.featureStatus(for: .climateStartStop, in: onlineState)
        #expect(status.isVisible)
        #expect(status.isUsable)
    }

    @Test
    func featureStatusReportsOfflineWhenVehicleUnavailable() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        var offlineState = vehicle(vin: "VIN-P4")
        offlineState = VehicleState(
            batteryPercentage: offlineState.energy.batteryPercentage, rangeKm: offlineState.energy.rangeKm,
            chargingState: offlineState.energy.chargingState,
            estimatedChargingTimeToFullMinutes: offlineState.energy.estimatedTimeToFullMinutes,
            chargeTargetPercentage: offlineState.energy.targetPercentage,
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
        #expect(status.isVisible)
        #expect(!(status.isUsable))
        #expect(status.availability == .vehicleOffline)
    }

    @Test
    func unsupportedCapabilityIsNeverUsable() {
        let profile = VehicleCapabilityProfile(modelName: "Polestar 4")
        let state = vehicle(vin: "VIN-P4")
        let status = profile.featureStatus(for: .chargingCurrentLimit, in: state)
        #expect(!(status.isVisible))
        #expect(!(status.isUsable))
    }

    @Test
    func volvoXC40AndEX40HideSelectableTemperatureAndSeatHeating() {
        let xc40Profile = VehicleCapabilityProfile(modelName: "XC40 Recharge")
        #expect(!(xc40Profile.hasSelectableClimateTemperature))
        #expect(!(xc40Profile.hasSelectableSeatHeating))
        #expect(!(xc40Profile.hasSelectableSteeringWheelHeating))
        #expect(xc40Profile.permits(.climateStartStop))
        #expect(xc40Profile.permits(.locks))
        #expect(xc40Profile.permits(.honkAndFlash))
        #expect(!(xc40Profile.permits(.chargeTarget)))
        #expect(!(xc40Profile.permits(.chargingCurrentLimit)))

        let ex40Profile = VehicleCapabilityProfile(modelName: "EX40 Single Motor")
        #expect(!(ex40Profile.hasSelectableClimateTemperature))
        #expect(!(ex40Profile.hasSelectableSeatHeating))
        #expect(!(ex40Profile.hasSelectableSteeringWheelHeating))
        #expect(ex40Profile.permits(.climateStartStop))
    }

    @Test
    func volvoEX30AndEX90ShowSelectableTemperatureAndSeatHeating() {
        let ex30Profile = VehicleCapabilityProfile(modelName: "EX30 Ultra")
        #expect(ex30Profile.hasSelectableClimateTemperature)
        #expect(ex30Profile.hasSelectableSeatHeating)
        #expect(ex30Profile.hasSelectableSteeringWheelHeating)
        #expect(ex30Profile.permits(.climateStartStop))

        let ex90Profile = VehicleCapabilityProfile(modelName: "EX90 Twin Motor")
        #expect(ex90Profile.hasSelectableClimateTemperature)
        #expect(ex90Profile.hasSelectableSeatHeating)
        #expect(ex90Profile.hasSelectableSteeringWheelHeating)
        #expect(ex90Profile.permits(.climateStartStop))
    }
}


