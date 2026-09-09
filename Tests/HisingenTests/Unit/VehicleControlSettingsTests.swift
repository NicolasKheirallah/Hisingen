import Foundation
import Testing
@testable import Hisingen

struct VehicleControlSettingsTests {
    @Test func rearSeatSupportDoesNotDependOnFrontSeatSupport() throws {
        let climate = Protobuf.intField(8, 0) + Protobuf.intField(9, 1)
        let car = Protobuf.stringField(1, "VIN") + Protobuf.messageField(37, climate)
        let response = Protobuf.messageField(1, Protobuf.messageField(1, car))
        let caps = try #require(PolestarGRPC.parseMyCars(response, vin: "VIN"))
        #expect(caps.advertisedCapabilities?[.seatHeating] == true)
        #expect(caps.controlSettings?.frontSeatSettings == false)
        #expect(caps.controlSettings?.rearSeatSettings == true)
    }
    @Test func diagnosticGroupsPreserveDistinctActionsAndDiscardOtherVehicles() {
        let first = VehicleChronosError(service: .chargeLocation, errorCode: .timeout, actionCode: 1, recordID: "one", vin: "VIN")
        let second = VehicleChronosError(service: .chargeLocation, errorCode: .timeout, actionCode: 1, recordID: "two", vin: "VIN")
        let differentAction = VehicleChronosError(service: .chargeLocation, errorCode: .timeout, actionCode: 2, recordID: "three", vin: "VIN")
        let other = VehicleChronosError(service: .chargeLocation, errorCode: .timeout, actionCode: 1, recordID: "four", vin: "OTHER")
        let groups = VehicleDiagnosticGroup.grouped([first, first, second, differentAction, other], vin: "VIN")
        #expect(groups.count == 2)
        #expect(groups.first { $0.action == 1 }?.records.count == 2)
        #expect(groups.flatMap(\.records).count == 3)
    }
    @Test func scheduleValidationRejectsInvalidTimesAndAllowsOvernightWindows() throws {
        let overnight = VehicleSchedule(kind: .globalCharging, startHour: 22, startMinute: 0,
                                         endHour: 6, endMinute: 30, isActive: true)
        #expect(VehicleControlSettings().rejection(for: .setGlobalChargeTimer(overnight)) == nil)
        #expect(!((try PolestarGRPC.globalChargeTimer(overnight)).isEmpty))
        let invalid = VehicleSchedule(kind: .climate, startHour: 24, startMinute: 0,
                                      endHour: nil, endMinute: nil, isActive: true)
        #expect(VehicleControlSettings().rejection(for: .setClimateTimer(invalid)) != nil)
        let valid = VehicleSchedule(kind: .climate, startHour: 7, startMinute: 30,
                                    endHour: nil, endMinute: nil, isActive: true)
        #expect(VehicleControlSettings(singleClimateTimers: false).rejection(for: .setClimateTimer(valid)) != nil)
        #expect(VehicleControlSettings().rejection(for: .setClimateTimer(valid)) == nil)
    }

    @Test func locationSettingsUseAdvertisedAmperageBoundsAndAllowOmittedLimit() {
        let caps = VehicleOTACapabilities(chargeAmperageMinLimit: 8, chargeAmperageMaxLimit: 16)
        let bounds = VehicleChargeBounds(capabilities: caps)
        let settings = VehicleControlSettings(locationAmperage: true)
        #expect(settings.rejection(for: .updateChargeLocationAmpLimit(id: "home", amps: 20), bounds: bounds) != nil)
        #expect(settings.rejection(for: .updateChargeLocationAmpLimit(id: "home", amps: 8), bounds: bounds) == nil)
        #expect(VehicleControlSettings(locationAmperage: false).rejection(for:
            .createChargeLocationAtCar(alias: "Home", ampLimit: 0, minimumSoc: 0, optimisedCharging: false)) == nil)
    }
    @Test func explicitAndObservedCapabilitiesOverrideModelDefaultsInOrder() {
        let probes = VehicleProbedCapabilities(results: [.honkAndFlash: .unavailable])
        let supported = VehicleCapabilityProfile(modelName: "Polestar 2", advertised: [.honkAndFlash: true])
        #expect(supported.permits(.honkAndFlash))
        #expect(supported.supportSource(for: .honkAndFlash) == L10n.text("Explicit vehicle capability"))
        let observed = VehicleCapabilityProfile(modelName: "Polestar 2", probed: probes, advertised: [.honkAndFlash: true])
        #expect(!observed.permits(.honkAndFlash))
        #expect(observed.supportSource(for: .honkAndFlash) == L10n.text("Recent service response"))
        let denied = VehicleCapabilityProfile(modelName: "Polestar 3",
            probed: VehicleProbedCapabilities(results: [.seatHeating: .supported]), advertised: [.seatHeating: false])
        #expect(!denied.permits(.seatHeating))
        let stale = VehicleCapabilityProfile(modelName: "Polestar 2",
            probed: VehicleProbedCapabilities(results: [.honkAndFlash: .unavailable], probedAt: .distantPast),
            advertised: [.honkAndFlash: true])
        #expect(stale.permits(.honkAndFlash))
    }

    @Test func climateAdaptationOmitsUnsupportedSettingsAndPreservesSupportedOnes() {
        let command = RemoteCommand.startClimate(temperatureCelsius: 22, frontLeftSeat: .level2,
            frontRightSeat: .off, rearLeftSeat: .level3, rearRightSeat: .level1, steeringWheel: .level2)
        let settings = VehicleControlSettings(frontSeatSettings: true, rearSeatSettings: false, steeringWheelSettings: false)
        let profile = VehicleCapabilityProfile(modelName: "Polestar 3",
            advertised: [.climateStartStop: true, .climateTemperature: true, .seatHeating: true, .steeringWheelHeating: true])
        let adapted = command.adapted(to: profile, settings: settings)
        #expect(adapted == .startClimate(temperatureCelsius: 22, frontLeftSeat: .level2,
            frontRightSeat: .off, rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified))
        #expect(settings.rejection(for: adapted) == nil)
        let managed = command.adapted(to: VehicleCapabilityProfile(modelName: "Polestar 2"))
        #expect(managed == .startClimate(temperatureCelsius: 0, frontLeftSeat: .unspecified,
            frontRightSeat: .unspecified, rearLeftSeat: .unspecified, rearRightSeat: .unspecified, steeringWheel: .unspecified))
    }

    @Test func advertisedTemperatureBoundsConstrainSelectableRange() {
        let settings = VehicleControlSettings(temperatureMinimum: 18, temperatureMaximum: 26)
        #expect(settings.temperatureRange == 18...26)
        #expect(VehicleControlSettings().temperatureRange == 16...30)
        #expect(VehicleControlSettings(temperatureMinimum: 30, temperatureMaximum: 16).temperatureRange == 16...30)
    }
}
