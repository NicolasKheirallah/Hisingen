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
        state.identity.externalColour = "Midnight"
        state.energy.currentLimitAmps = 20
        return state
    }

    @Test("Round trip through the clustered snapshot encoding preserves every field")
    func testClusteredRoundTrip() throws {
        let original = fullyPopulated()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: data)
        #expect(decoded == original)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["energy", "identity", "maintenance", "freshness", "commandState"] {
            #expect(object[key] != nil)
        }
        for key in ["batteryPercentage", "vin", "odometerKm", "fetchedAt", "pendingCommand"] {
            #expect(object[key] == nil)
        }
    }

    @Test("Service and trip-computer clusters survive a round trip")
    func testServiceAndTripClustersRoundTrip() throws {
        var state = fullyPopulated()
        state.maintenance.service = ServiceSnapshot(
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
        object.removeValue(forKey: "maintenance")
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
        #expect(decoded.maintenance.service.daysToService == 17)
        #expect(decoded.maintenance.service.distanceToServiceKm == 900)
        #expect(decoded.tripComputer.manualTripKm == 64.5)
        #expect(decoded.tripComputer.averageSpeedKmH == 48.25)
        #expect(decoded.tripComputer.electricRangeKm == 33)
    }

    @Test("A fully flat snapshot decodes and re-encodes only as nested clusters")
    func testLegacyFlatSnapshotMigration() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fullyPopulated())) as? [String: Any])

        let energy = try #require(object.removeValue(forKey: "energy") as? [String: Any])
        let identity = try #require(object.removeValue(forKey: "identity") as? [String: Any])
        let maintenance = try #require(object.removeValue(forKey: "maintenance") as? [String: Any])
        let freshness = try #require(object.removeValue(forKey: "freshness") as? [String: Any])
        let command = try #require(object.removeValue(forKey: "commandState") as? [String: Any])

        let energyKeys = [
            "batteryPercentage": "batteryPercentage", "rangeKm": "rangeKm",
            "chargingState": "chargingState", "estimatedTimeToFullMinutes": "estimatedChargingTimeToFullMinutes",
            "estimatedTimeToTargetMinutes": "estimatedChargingTimeToTargetMinutes",
            "targetPercentage": "chargeTargetPercentage", "powerWatts": "chargingPowerWatts",
            "currentAmps": "chargingCurrentAmps", "voltageVolts": "chargingVoltageVolts",
            "type": "chargingType", "connection": "chargerConnection",
            "currentLimitAmps": "chargingCurrentLimitAmps",
            "reportedBatteryCapacityKwh": "reportedBatteryCapacityKwh", "diagnostics": "batteryDiagnostics",
            "schedules": "chargingSchedules", "locations": "chargeLocations",
            "samples": "chargingSamples", "sessions": "chargingSessions"
        ]
        for (nested, flat) in energyKeys { object[flat] = energy[nested] }
        for key in ["availability", "modelName", "modelYear", "registrationNo", "vin", "ownerFirstName",
                    "externalColour", "gearbox", "structureWeek", "internalVehicleIdentifier", "pno34",
                    "accountMarket", "upholstery", "wheels", "packages", "steeringOrientation",
                    "imageData", "interiorImageData"] {
            object[key] = identity[key]
        }
        object["odometerKm"] = maintenance["odometerKm"]
        object["healthDetails"] = maintenance["details"]
        object["serviceInfo"] = maintenance["service"]
        object["warrantyInfo"] = maintenance["warranty"]
        object["frontBrakePadStatus"] = maintenance["frontBrakePadStatus"]
        object["rearBrakePadStatus"] = maintenance["rearBrakePadStatus"]
        object["isCachedSnapshot"] = freshness["isCached"]
        object["fetchedAt"] = freshness["fetchedAt"]
        object["vehicleReportedAt"] = freshness["vehicleReportedAt"]
        object["readingDates"] = freshness["readingDates"]
        object["dataWarnings"] = freshness["dataWarnings"]
        object["unavailableFeatures"] = freshness["unavailableFeatures"]
        object["retainedDataCategories"] = freshness["retainedDataCategories"]
        object["retainedDataAt"] = freshness["retainedDataAt"]
        object["pendingCommand"] = command["receipt"]

        let decoded = try JSONDecoder().decode(
            VehicleState.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded == fullyPopulated())

        let migrated = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)) as? [String: Any])
        #expect(migrated["energy"] != nil)
        #expect(migrated["identity"] != nil)
        #expect(migrated["maintenance"] != nil)
        #expect(migrated["freshness"] != nil)
        #expect(migrated["commandState"] != nil)
        #expect(migrated["batteryPercentage"] == nil)
        #expect(migrated["vin"] == nil)
        #expect(migrated["odometerKm"] == nil)
        #expect(migrated["fetchedAt"] == nil)
        #expect(migrated["pendingCommand"] == nil)
    }

    @Test("Command receipt survives Codable round-trip but is absent when unset")
    func commandReceiptCodableRoundTrip() throws {
        var state = fullyPopulated()
        state.commandState.receipts = [
            CommandReceipt(
                commandIdentifier: "lock",
                issuedAt: Date(timeIntervalSince1970: 1_750_000_100),
                status: .confirmed(at: Date(timeIntervalSince1970: 1_750_000_110))
            ),
            CommandReceipt(
                commandIdentifier: "start-climate",
                issuedAt: Date(timeIntervalSince1970: 1_750_000_120)
            )
        ]
        let decoded = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(state))
        #expect(decoded.commandState.receipts == state.commandState.receipts)
        #expect(decoded.commandState.receipt == state.commandState.receipts.last)

        let bare = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(fullyPopulated()))
        #expect(bare.commandState.receipt == nil)
    }

    @Test("Legacy commandState.pending decodes as the renamed receipt")
    func legacyPendingReceiptKeyMigration() throws {
        let receipt = CommandReceipt(
            commandIdentifier: "lock",
            issuedAt: Date(timeIntervalSince1970: 1_750_000_100),
            status: .timedOut(at: Date(timeIntervalSince1970: 1_750_000_200))
        )
        let receiptObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
        let legacy = try JSONSerialization.data(withJSONObject: ["pending": receiptObject])

        let decoded = try JSONDecoder().decode(CommandPresentationState.self, from: legacy)
        #expect(decoded.receipt == receipt)
        let migrated = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(decoded)
        ) as? [String: Any])
        #expect(migrated["receipts"] != nil)
        #expect(migrated["receipt"] == nil)
        #expect(migrated["pending"] == nil)
    }

    @Test("Legacy confirmedAt receipts migrate to the unified terminal status")
    func legacyConfirmedAtStatusMigration() throws {
        struct LegacyReceipt: Encodable {
            let commandIdentifier: String
            let issuedAt: Date
            let command: RemoteCommand
            let confirmedAt: Date
        }
        let confirmedAt = Date(timeIntervalSince1970: 1_750_000_200)
        let data = try JSONEncoder().encode(LegacyReceipt(
            commandIdentifier: "lock",
            issuedAt: Date(timeIntervalSince1970: 1_750_000_100),
            command: .lock,
            confirmedAt: confirmedAt
        ))

        let decoded = try JSONDecoder().decode(CommandReceipt.self, from: data)
        #expect(decoded.status == .confirmed(at: confirmedAt))
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
