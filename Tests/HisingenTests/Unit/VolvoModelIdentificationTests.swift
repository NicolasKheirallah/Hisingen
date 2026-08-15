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
    func testC40AndEX40NamingBothMapToTheSameCase() {


        XCTAssertEqual(VehicleModelFamily(modelName: "C40 Recharge"), .volvoC40)
        XCTAssertEqual(VehicleModelFamily(modelName: "EX40"), .volvoC40)
        XCTAssertEqual(VehicleModelFamily(modelName: "EC40"), .volvoC40)
    }

    @Test
    func testXC40IsNeverMisidentifiedAsC40() {


        XCTAssertEqual(VehicleModelFamily(modelName: "XC40 Recharge Twin"), .volvoXC40)
        XCTAssertNotEqual(VehicleModelFamily(modelName: "XC40 Recharge Twin"), .volvoC40)
    }

    @Test
    func testVolvoModelsReportVolvoBrand() {
        XCTAssertEqual(VehicleModelFamily.volvoXC60.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoEX30.brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.volvoUnknown("Something New").brand, .volvo)
        XCTAssertEqual(VehicleModelFamily.polestar2.brand, .polestar)
    }

    @Test
    func testVolvoHasNoVerifiedNominalSpecs() {


        XCTAssertFalse(VehicleModelFamily.volvoEX30.hasVerifiedNominalSpecs)
        XCTAssertTrue(VehicleModelFamily.polestar2.hasVerifiedNominalSpecs)
        XCTAssertNil(VehicleModelFamily.volvoEX30.averageConsumptionWhPerKm)
        XCTAssertNotNil(VehicleModelFamily.polestar2.averageConsumptionWhPerKm)
    }

    @Test
    func testVolvoModelFamilyRoundTripsThroughCodable() throws {
        let models: [VehicleModelFamily] = [
            .volvoXC40, .volvoXC60, .volvoXC90, .volvoS60, .volvoS90, .volvoV60, .volvoV90,
            .volvoC40, .volvoEX30, .volvoEX90, .volvoES90, .volvoUnknown("Volvo Concept X")
        ]
        for model in models {
            let data = try JSONEncoder().encode(model)
            let decoded = try JSONDecoder().decode(VehicleModelFamily.self, from: data)
            XCTAssertEqual(decoded, model)
        }
    }

    @Test
    func testVolvoCapabilityProfileIsConservativeByDefault() {


        let profile = VehicleCapabilityProfile(modelName: "XC60")
        XCTAssertEqual(profile.support(for: .locks), .supported)
        XCTAssertEqual(profile.support(for: .honkAndFlash), .supported)
        XCTAssertEqual(profile.support(for: .exteriorStatus), .supported)
        XCTAssertEqual(profile.support(for: .climateStartStop), .supported)
        XCTAssertEqual(profile.support(for: .softwareInstallControl), .unavailable)
        XCTAssertEqual(profile.support(for: .chargeTarget), .backendDependent)
        XCTAssertEqual(profile.support(for: .chargingCurrentLimit), .backendDependent)
        XCTAssertEqual(profile.support(for: .tyrePressureValues), .backendDependent)
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

