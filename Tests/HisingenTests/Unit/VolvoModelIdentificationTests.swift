import Foundation
import Testing
@testable import Hisingen

struct VolvoModelIdentificationTests {

    @Test
    func testVolvoModelNameIdentification() {
        #expect(VehicleModelFamily(modelName: "XC40") == .volvoXC40)
        #expect(VehicleModelFamily(modelName: "XC60") == .volvoXC60)
        #expect(VehicleModelFamily(modelName: "XC90") == .volvoXC90)
        #expect(VehicleModelFamily(modelName: "S60") == .volvoS60)
        #expect(VehicleModelFamily(modelName: "S90") == .volvoS90)
        #expect(VehicleModelFamily(modelName: "V60") == .volvoV60)
        #expect(VehicleModelFamily(modelName: "V90") == .volvoV90)
        #expect(VehicleModelFamily(modelName: "EX30") == .volvoEX30)
        #expect(VehicleModelFamily(modelName: "EX90") == .volvoEX90)
        #expect(VehicleModelFamily(modelName: "ES90") == .volvoES90)
    }

    @Test
    func testC40AndEX40NamingIdentification() {
        #expect(VehicleModelFamily(modelName: "C40 Recharge") == .volvoC40)
        #expect(VehicleModelFamily(modelName: "EX40") == .volvoEX40)
        #expect(VehicleModelFamily(modelName: "EC40") == .volvoEC40)
    }

    @Test
    func testXC40IsNeverMisidentifiedAsC40() {
        #expect(VehicleModelFamily(modelName: "XC40 Recharge Twin") == .volvoXC40)
        #expect(VehicleModelFamily(modelName: "XC40 Recharge Twin") != .volvoC40)
    }

    @Test
    func testVolvoModelsReportVolvoBrand() {
        #expect(VehicleModelFamily.volvoXC60.brand == .volvo)
        #expect(VehicleModelFamily.volvoXC40.brand == .volvo)
        #expect(VehicleModelFamily.volvoEX40.brand == .volvo)
        #expect(VehicleModelFamily.volvoEX30.brand == .volvo)
        #expect(VehicleModelFamily.volvoUnknown("Something New").brand == .volvo)
        #expect(VehicleModelFamily.polestar2.brand == .polestar)
    }

    @Test
    func testModelReferenceSpecsAvailability() {
        // `hasModelReferenceSpecs` is model-driven (a non-zero WLTP/capacity table entry), not
        // brand-driven: Volvo BEVs with real reference numbers in the table resolve just like
        // Polestar, while Volvo models with no BEV specs (ICE/PHEV/unrecognized) still don't.
        #expect(VehicleModelFamily.volvoEX30.hasModelReferenceSpecs)
        #expect(VehicleModelFamily.volvoXC40.hasModelReferenceSpecs)
        #expect(VehicleModelFamily.polestar2.hasModelReferenceSpecs)
        #expect(!(VehicleModelFamily.volvoXC60.hasModelReferenceSpecs))
        #expect(!(VehicleModelFamily.volvoUnknown("Something New").hasModelReferenceSpecs))

        #expect(VehicleModelFamily.volvoEX30.averageConsumptionWhPerKm != nil)
        #expect(VehicleModelFamily.polestar2.averageConsumptionWhPerKm != nil)
        #expect(VehicleModelFamily.volvoXC60.averageConsumptionWhPerKm == nil)
    }

    @Test
    func testVolvoModelFamilyRoundTripsThroughCodable() throws {
        let models: [VehicleModelFamily] = [
            .volvoXC40, .volvoEX40, .volvoC40, .volvoEC40, .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90,
            .volvoEX30, .volvoEX90, .volvoES90, .volvoUnknown("Volvo Concept X")
        ]
        for model in models {
            let data = try JSONEncoder().encode(model)
            let decoded = try JSONDecoder().decode(VehicleModelFamily.self, from: data)
            #expect(decoded == model)
        }
    }

    @Test
    func testVolvoXC40AndEX40DoNotSupportRemoteTemperatureOrSeatHeating() {
        let xc40Profile = VehicleCapabilityProfile(modelName: "XC40")
        #expect(!(xc40Profile.hasSelectableClimateTemperature))
        #expect(!(xc40Profile.hasSelectableSeatHeating))
        #expect(!(xc40Profile.hasSelectableSteeringWheelHeating))
        #expect(xc40Profile.support(for: .climateStartStop) == .supported)
        #expect(xc40Profile.support(for: .locks) == .supported)
        #expect(xc40Profile.support(for: .honkAndFlash) == .supported)
        #expect(xc40Profile.support(for: .climateTemperature) == .unavailable)
        #expect(xc40Profile.support(for: .seatHeating) == .unavailable)
        #expect(xc40Profile.support(for: .steeringWheelHeating) == .unavailable)

        let ex40Profile = VehicleCapabilityProfile(modelName: "EX40")
        #expect(!(ex40Profile.hasSelectableClimateTemperature))
        #expect(!(ex40Profile.hasSelectableSeatHeating))
        #expect(!(ex40Profile.hasSelectableSteeringWheelHeating))
        #expect(ex40Profile.support(for: .climateStartStop) == .supported)
    }

    @Test
    func testVolvoNextGenEX30AndEX90SupportRemoteClimateSettings() {
        let ex30Profile = VehicleCapabilityProfile(modelName: "EX30")
        #expect(ex30Profile.hasSelectableClimateTemperature)
        #expect(ex30Profile.hasSelectableSeatHeating)
        #expect(ex30Profile.hasSelectableSteeringWheelHeating)
        #expect(ex30Profile.support(for: .climateStartStop) == .supported)
    }

    @Test
    func testVolvoRuntimeProbeOverridesStaticDefault() {
        var probed = VehicleProbedCapabilities()
        probed.record(.chargeTarget, as: .supported)
        let profile = VehicleCapabilityProfile(modelName: "EX30", probed: probed)
        #expect(profile.support(for: .chargeTarget) == .supported)
        #expect(profile.support(for: .locks) == .supported)
    }
}

