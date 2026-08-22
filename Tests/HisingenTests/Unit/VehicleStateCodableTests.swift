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

    @Test("Service and trip-computer clusters survive a round trip")
    func testServiceAndTripClustersRoundTrip() throws {
        var state = fullyPopulated()
        state.serviceInfo = ServiceSnapshot(
            daysToService: 21, distanceToServiceKm: 1_400, serviceWarning: true,
            fluidWarnings: ["Brake fluid"], engineHoursToService: 512,
            trigger: "MILEAGE", preferredWorkshopID: "VSC-042", preferredWorkshopName: "Gothenburg")
        state.tripComputer = TripComputerSnapshot(
            manualTripKm: 120.5, automaticTripKm: 310.2, averageSpeedKmH: 62.0,
            electricRangeKm: 41, electricDistanceKm: 88.4,
            fuelDistanceKm: 210.0, regeneratedEnergyKwh: 3.7)

        let roundTripped = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(state))
        #expect(roundTripped == state)
    }

    @Test("Flat pre-cluster service and trip fields still decode into the clusters")
    func testLegacyServiceAndTripDecode() throws {
        var object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fullyPopulated())) as! [String: Any]
        // Strip clustered encodings, inject the flat shapes older builds wrote.
        object.removeValue(forKey: "serviceInfo")
        object.removeValue(forKey: "tripComputer")
        object["daysToService"] = 17
        object["distanceToServiceKm"] = 900
        object["serviceWarning"] = false
        object["fluidWarnings"] = [String]()
        object["tripMeterManualKm"] = 64.5
        object["averageSpeedKmH"] = 48.25
        object["tripComputerElectricRangeKm"] = 33

        let decoded = try JSONDecoder().decode(
            VehicleState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.serviceInfo.daysToService == 17)
        #expect(decoded.serviceInfo.distanceToServiceKm == 900)
        #expect(decoded.tripComputer.manualTripKm == 64.5)
        #expect(decoded.tripComputer.averageSpeedKmH == 48.25)
        #expect(decoded.tripComputer.electricRangeKm == 33)
    }

    @Test("Pending-command marker survives persistence but is absent when unset")
    func testPendingCommandCodable() throws {
        var state = fullyPopulated()
        state.pendingCommand = PendingCommandSummary(
            commandIdentifier: "lock", issuedAt: Date(timeIntervalSince1970: 1_750_000_100))
        let decoded = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(state))
        #expect(decoded.pendingCommand == state.pendingCommand)

        let bare = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(fullyPopulated()))
        #expect(bare.pendingCommand == nil)
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
