import Foundation
import Testing
@testable import Hisingen

struct VolvoModelIdentificationTests {

    @Test
    func testVolvoModelNameIdentification() {
        XCTAssertEqual(VehicleModelFamily(modelName: "XC40"), .volvoXC40)
        XCTAssertEqual(VehicleModelFamily(modelName: "XC60"), .volvoXC60)
        XCTAssertEqual(VehicleModelFamily(modelName: "XC90"), .volvoXC90)
        XCTAssertEqual(VehicleModelFamily(modelName: "S60"), .volvoS60)
        XCTAssertEqual(VehicleModelFamily(modelName: "S90"), .volvoS90)
        XCTAssertEqual(VehicleModelFamily(modelName: "V60"), .volvoV60)
        XCTAssertEqual(VehicleModelFamily(modelName: "V90"), .volvoV90)
        XCTAssertEqual(VehicleModelFamily(modelName: "EX30"), .volvoEX30)
        XCTAssertEqual(VehicleModelFamily(modelName: "EX90"), .volvoEX90)
        XCTAssertEqual(VehicleModelFamily(modelName: "ES90"), .volvoES90)
    }

    @Test
    func testC40AndEX40NamingIdentification() {
        XCTAssertEqual(VehicleModelFamily(modelName: "C40 Recharge"), .volvoC40)
        XCTAssertEqual(VehicleModelFamily(modelName: "EX40"), .volvoEX40)
        XCTAssertEqual(VehicleModelFamily(modelName: "EC40"), .volvoEC40)
    }

    @Test
    func testXC40IsNeverMisidentifiedAsC40() {
        XCTAssertEqual(VehicleModelFamily(modelName: "XC40 Recharge Twin"), .volvoXC40)
        XCTAssertNotEqual(VehicleModelFamily(modelName: "XC40 Recharge Twin"), .volvoC40)
    }

    @Test
    func testVolvoModelsReportVolvoBrand() {
        XCTAssertEqual(VehicleModelFamily.volvoXC60.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoXC40.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoEX40.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoEX30.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoUnknown("Something New").brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.polestar2.brand, .polestar)
    }

    @Test
    func testModelReferenceSpecsAvailability() {
        // `hasModelReferenceSpecs` is model-driven (a non-zero WLTP/capacity table entry), not
        // brand-driven: Volvo BEVs with real reference numbers in the table resolve just like
        // Polestar, while Volvo models with no BEV specs (ICE/PHEV/unrecognized) still don't.
        XCTAssertTrue(VehicleModelFamily.volvoEX30.hasModelReferenceSpecs)
        XCTAssertTrue(VehicleModelFamily.volvoXC40.hasModelReferenceSpecs)
        XCTAssertTrue(VehicleModelFamily.polestar2.hasModelReferenceSpecs)
        XCTAssertFalse(VehicleModelFamily.volvoXC60.hasModelReferenceSpecs)
        XCTAssertFalse(VehicleModelFamily.volvoUnknown("Something New").hasModelReferenceSpecs)

        XCTAssertNotNil(VehicleModelFamily.volvoEX30.averageConsumptionWhPerKm)
        XCTAssertNotNil(VehicleModelFamily.polestar2.averageConsumptionWhPerKm)
        XCTAssertNil(VehicleModelFamily.volvoXC60.averageConsumptionWhPerKm)
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
            XCTAssertEqual(decoded, model)
        }
    }

    @Test
    func testVolvoXC40AndEX40DoNotSupportRemoteTemperatureOrSeatHeating() {
        let xc40Profile = VehicleCapabilityProfile(modelName: "XC40")
        XCTAssertFalse(xc40Profile.hasSelectableClimateTemperature)
        XCTAssertFalse(xc40Profile.hasSelectableSeatHeating)
        XCTAssertFalse(xc40Profile.hasSelectableSteeringWheelHeating)
        XCTAssertEqual(xc40Profile.support(for: .climateStartStop), .supported)
        XCTAssertEqual(xc40Profile.support(for: .locks), .supported)
        XCTAssertEqual(xc40Profile.support(for: .honkAndFlash), .supported)
        XCTAssertEqual(xc40Profile.support(for: .climateTemperature), .unavailable)
        XCTAssertEqual(xc40Profile.support(for: .seatHeating), .unavailable)
        XCTAssertEqual(xc40Profile.support(for: .steeringWheelHeating), .unavailable)

        let ex40Profile = VehicleCapabilityProfile(modelName: "EX40")
        XCTAssertFalse(ex40Profile.hasSelectableClimateTemperature)
        XCTAssertFalse(ex40Profile.hasSelectableSeatHeating)
        XCTAssertFalse(ex40Profile.hasSelectableSteeringWheelHeating)
        XCTAssertEqual(ex40Profile.support(for: .climateStartStop), .supported)
    }

    @Test
    func testVolvoNextGenEX30AndEX90SupportRemoteClimateSettings() {
        let ex30Profile = VehicleCapabilityProfile(modelName: "EX30")
        XCTAssertTrue(ex30Profile.hasSelectableClimateTemperature)
        XCTAssertTrue(ex30Profile.hasSelectableSeatHeating)
        XCTAssertTrue(ex30Profile.hasSelectableSteeringWheelHeating)
        XCTAssertEqual(ex30Profile.support(for: .climateStartStop), .supported)
    }

    @Test
    func testVolvoRuntimeProbeOverridesStaticDefault() {
        var probed = VehicleProbedCapabilities()
        probed.record(.chargeTarget, as: .supported)
        let profile = VehicleCapabilityProfile(modelName: "EX30", probed: probed)
        XCTAssertEqual(profile.support(for: .chargeTarget), .supported)
        XCTAssertEqual(profile.support(for: .locks), .supported)
    }
}

