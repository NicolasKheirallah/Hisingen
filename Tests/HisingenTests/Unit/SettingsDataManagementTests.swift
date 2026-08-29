import Foundation
import Testing
@testable import Hisingen

struct SettingsDataManagementTests {
    @Test
    func maintenanceOperationsCompleteBeforeReturning() throws {
        let database = VehicleDatabase.inMemory()
        let vin = "SETTINGS_DATA_TEST"
        database.recordCommandAudit(vin: vin, command: "lock", status: "success")
        #expect(database.addFuelEntry(vin: vin, date: Date(), liters: 20, pricePerLiter: 2, odometerKm: 1_000))
        database.saveVehicleImage(vin: vin, angle: 0, data: Data([1, 2, 3]))
        #expect(database.recordCounts().commands == 1)
        #expect(database.recentFuelEntries(for: vin).count == 1)
        #expect(database.loadVehicleImage(for: vin, angle: 0) != nil)

        try database.vacuumOrThrow()
        #expect(database.recordCounts().commands == 1)

        try database.wipeAllOrThrow(for: vin)
        #expect(database.recordCounts().commands == 0)
        #expect(database.recentFuelEntries(for: vin).isEmpty)
        #expect(database.loadVehicleImage(for: vin, angle: 0) == nil)
    }

    @Test
    func configurablePruneEntryPointPreservesRecentData() throws {
        let database = VehicleDatabase.inMemory()
        #expect(database.recordTelemetry(
            vin: "SETTINGS_RETENTION_TEST", odometerKm: 1, tripManualKm: nil,
            tripAutoKm: nil, avgConsumption: nil, ambientTempC: nil,
            latitude: nil, longitude: nil
        ))
        try database.pruneHistoricalSamplesOrThrow(olderThanDays: 30)
        #expect(database.recordCounts().telemetry == 1)
    }

    @Test
    func historyBackupHasAnExplicitReadOnlySchema() throws {
        let database = VehicleDatabase.inMemory()
        let vin = "SETTINGS_BACKUP_TEST"
        let sessionID = database.startChargingSession(vin: vin, startSoc: 30)
        database.recordChargingSample(
            sessionId: sessionID, vin: vin, soc: 31, powerKw: 11,
            voltage: 230, current: 16
        )
        #expect(database.recordConnectivity(vin: vin, networkType: "LTE", signalBars: 4, wakeReason: "app"))
        #expect(database.recordCabinClimate(vin: vin, interiorCelsius: 20, requestedCelsius: 21))
        #expect(database.addFuelEntry(vin: vin, date: Date(), liters: 10, pricePerLiter: 2, odometerKm: 500))
        let data = try database.exportBackupJSON(includeCoordinates: false)
        let payload = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(payload["schema"] as? String == "hisingen-backup-v1")
        #expect(payload["includesCoordinates"] as? Bool == false)
        #expect((payload["chargingSamples"] as? [[String: Any]])?.count == 1)
        #expect((payload["connectivity"] as? [[String: Any]])?.count == 1)
        #expect((payload["cabinClimate"] as? [[String: Any]])?.count == 1)
        #expect((payload["fuelEntries"] as? [[String: Any]])?.count == 1)
    }
}
