import Foundation
import Testing
@testable import Hisingen

@Suite("VehicleState Snapshot Codability")
struct VehicleStateCodableTests {
    /// Fully-populated state used to prove no field is silently dropped by the encoder.
    private func fullyPopulated() -> VehicleState {
        var state = VehicleState(
            batteryPercentage: 71.5, rangeKm: 302, chargingState: .charging,
            estimatedChargingTimeToFullMinutes: 42, chargeTargetPercentage: 90,
            chargingPowerWatts: 11_000, chargingCurrentAmps: 16, chargingVoltageVolts: 230,
            chargingType: .ac, chargerConnection: .connected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: "ABC 123", vin: "YSMTEST0000000001", ownerFirstName: "Test",
            odometerKm: 12_345, daysToService: 30, distanceToServiceKm: 2_000,
            serviceWarning: false, fluidWarnings: [], imageData: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            vehicleReportedAt: Date(timeIntervalSince1970: 1_749_999_900),
            dataWarnings: []
        )
        state.fuelSystem = FuelSystemSnapshot(
            levelPercent: 55, rangeKm: 90, amountLiters: 12.5,
            averageConsumptionLPer100Km: 6.4, isEngineRunning: false, type: "DIESEL"
        )
        state.externalColour = "Midnight"
        state.chargingCurrentLimitAmps = 20
        return state
    }

    @Test("Round trip through the clustered snapshot encoding preserves fuel fields")
    func testClusteredRoundTrip() throws {
        let original = fullyPopulated()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: data)
        #expect(decoded == original)
    }

    /// Builds a pre-cluster snapshot payload: takes a genuine modern encoding, removes the
    /// nested `fuelSystem` object and re-injects its fields under the flat legacy keys.
    private func legacyPayload(fuel: FuelSystemSnapshot) throws -> Data {
        var base = fullyPopulated()
        base.fuelSystem = FuelSystemSnapshot()
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as! [String: Any]
        object.removeValue(forKey: "fuelSystem")
        object["fuelLevelPercent"] = fuel.levelPercent
        object["fuelRangeKm"] = fuel.rangeKm
        object["fuelAmountLiters"] = fuel.amountLiters
        object["averageFuelConsumptionLPer100Km"] = fuel.averageConsumptionLPer100Km
        object["isEngineRunning"] = fuel.isEngineRunning
        object["fuelType"] = fuel.type
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test("Snapshots written before the fuel cluster migration still decode")
    func testLegacyFlatFuelDecode() throws {
        let fuel = FuelSystemSnapshot(
            levelPercent: 48, rangeKm: 77, amountLiters: 9.5,
            averageConsumptionLPer100Km: 5.9, isEngineRunning: false, type: "PETROL"
        )
        let decoded = try JSONDecoder().decode(VehicleState.self, from: legacyPayload(fuel: fuel))
        #expect(decoded.fuelSystem == fuel)
    }

    @Test("Re-encoding a legacy-decoded state migrates it to the clustered format")
    func testLegacyStateReencodesAsCluster() throws {
        let fuel = FuelSystemSnapshot(levelPercent: 33, rangeKm: nil, amountLiters: nil,
                                      averageConsumptionLPer100Km: nil, isEngineRunning: nil,
                                      type: nil)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: legacyPayload(fuel: fuel))
        let reencoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        let object = try JSONSerialization.jsonObject(with: Data(reencoded.utf8)) as! [String: Any]
        #expect(object["fuelSystem"] != nil, "re-encoding must use the clustered key")
        #expect(object["fuelLevelPercent"] == nil, "flat keys must not be written")
    }
}
