import Testing
import Foundation
@testable import Hisingen

@Suite("SQLite Database & Vehicle Telemetry Tests")
struct SQLiteDatabaseTests {

    @Test("In-memory SQLite database initializes and executes table creations")
    func testInMemoryDatabaseInit() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT);")
        try db.query(sql: "INSERT INTO test (id, name) VALUES (?, ?);") { stmt in
            try stmt.bindInt64(1, at: 1)
            try stmt.bindText("Polestar", at: 2)
            try stmt.executeUpdate()
        } process: { _ in }

        let name = try db.query(sql: "SELECT name FROM test WHERE id = 1;") { _ in } process: { stmt -> String? in
            guard stmt.step() else { return nil }
            return stmt.columnText(at: 0)
        }
        #expect(name == "Polestar")
    }

    @Test("Transactions commit on success and rollback on failure")
    func testTransactionsAndRollback() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute(sql: "CREATE TABLE items (id INTEGER PRIMARY KEY, val TEXT);")

        // Successful transaction
        try db.withTransaction {
            try db.query(sql: "INSERT INTO items (id, val) VALUES (1, 'One');") { _ in } process: { try $0.executeUpdate() }
            try db.query(sql: "INSERT INTO items (id, val) VALUES (2, 'Two');") { _ in } process: { try $0.executeUpdate() }
        }

        let count = try db.query(sql: "SELECT COUNT(*) FROM items;") { _ in } process: { stmt -> Int64 in
            stmt.step() ? (stmt.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(count == 2)

        // Failed transaction should rollback
        do {
            try db.withTransaction {
                try db.query(sql: "INSERT INTO items (id, val) VALUES (3, 'Three');") { _ in } process: { try $0.executeUpdate() }
                throw SQLiteError.stepExecution("Simulated error")
            }
        } catch {
            // expected
        }

        let countAfterRollback = try db.query(sql: "SELECT COUNT(*) FROM items;") { _ in } process: { stmt -> Int64 in
            stmt.step() ? (stmt.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(countAfterRollback == 2)
    }

    @Test("VehicleDatabase saves and restores snapshots with full isolation")
    func testVehicleDatabaseSnapshots() {
        let vdb = VehicleDatabase.inMemory()
        let state = VehicleState(
            batteryPercentage: 82.5,
            rangeKm: 340,
            chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 90,
            chargingPowerWatts: nil,
            chargingCurrentAmps: nil,
            chargingVoltageVolts: nil,
            chargingType: .none,
            chargerConnection: .disconnected,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2023",
            registrationNo: "ABC123",
            vin: "TESTVIN1234567890",
            ownerFirstName: "Nico",
            odometerKm: 45000,
            daysToService: 340,
            distanceToServiceKm: 5000,
            serviceWarning: false,
            fluidWarnings: [],
            exteriorStatus: nil,
            healthDetails: nil,
            softwareInfo: nil,
            chargingSchedules: [],
            climateStatus: nil,
            climateTimers: [],
            tripMeterManualKm: 1200,
            tripMeterAutomaticKm: 450,
            connectivity: nil,
            airQuality: nil,
            batteryDiagnostics: nil,
            weather: nil,
            location: nil,
            unavailableFeatures: [],
            probedCapabilities: nil,
            chargingSamples: [],
            chargingSessions: [],
            powertrain: .bev,
            fuelLevelPercent: nil,
            fuelRangeKm: nil,
            reportedBatteryCapacityKwh: 78.0,
            imageData: nil,
            fetchedAt: Date(),
            vehicleReportedAt: Date(),
            dataWarnings: []
        )

        vdb.saveSnapshot(state)
        let loaded = vdb.loadSnapshot(for: "TESTVIN1234567890")

        #expect(loaded != nil)
        #expect(loaded?.vin == "TESTVIN1234567890")
        #expect(loaded?.modelName == "Polestar 2")
        #expect(loaded?.batteryPercentage == 82.5)
        #expect(loaded?.isCachedSnapshot == true)

        vdb.deleteSnapshot(for: "TESTVIN1234567890")
        #expect(vdb.loadSnapshot(for: "TESTVIN1234567890") == nil)
    }

    @Test("VehicleDatabase logs and retrieves charging sessions & samples")
    func testChargingSessionsLifecycle() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "CHARGING_VIN_001"

        let sessionId = vdb.startChargingSession(vin: vin, startSoc: 20.0, location: "Home Wallbox")
        #expect(!sessionId.isEmpty)

        vdb.recordChargingSample(
            sessionId: sessionId, vin: vin, soc: 25.0,
            powerKw: 11.0, voltage: 230.0, current: 16.0
        )
        vdb.recordChargingSample(
            sessionId: sessionId, vin: vin, soc: 50.0,
            powerKw: 11.0, voltage: 230.0, current: 16.0
        )

        vdb.completeChargingSession(
            id: sessionId, endSoc: 80.0, energyDeliveredKwh: 45.2,
            peakPowerKw: 11.2, averagePowerKw: 10.8
        )

        let sessions = vdb.recentChargingSessions(for: vin, limit: 5)
        #expect(sessions.count == 1)
        #expect(sessions.first?.id == sessionId)
        #expect(sessions.first?.startSoc == 20.0)
        #expect(sessions.first?.endSoc == 80.0)
        #expect(sessions.first?.energyDeliveredKwh == 45.2)
        #expect(sessions.first?.locationName == "Home Wallbox")
    }

    @Test("VehicleDatabase tracks battery health SoH milestones")
    func testBatteryHealthMilestones() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "BATTERY_VIN_002"

        vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 10000, sohPct: 98.5, degPct: 1.5, usableKwh: 76.8
        )
        vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 50000, sohPct: 95.0, degPct: 5.0, usableKwh: 74.1
        )

        let history = vdb.batteryHealthHistory(for: vin, limit: 10)
        #expect(history.count == 2)
        #expect(history.first?.odometerKm == 50000)
        #expect(history.first?.stateOfHealthPct == 95.0)
        #expect(history.last?.odometerKm == 10000)
    }

    @Test("VehicleDatabase audit logs remote commands")
    func testRemoteCommandAuditLogging() throws {
        let vdb = VehicleDatabase.inMemory()
        let vin = "AUDIT_VIN_003"

        vdb.recordCommandAudit(
            id: "cmd-1", vin: vin, command: "lock", status: "success",
            durationMs: 1420, error: nil
        )

        let count = try vdb.db.query(sql: "SELECT COUNT(*) FROM remote_commands_log WHERE vin = ?;") { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> Int64 in
            stmt.step() ? (stmt.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(count == 1)
    }
}
