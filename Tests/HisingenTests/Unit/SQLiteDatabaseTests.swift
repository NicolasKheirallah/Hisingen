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

    @Test("Bound text and blob payloads survive until step (SQLITE_TRANSIENT contract)")
    func testBlobAndTextBindRoundTrip() throws {
        let db = try SQLiteDatabase.inMemory()
        try db.execute(sql: "CREATE TABLE payloads (id INTEGER PRIMARY KEY, text_value TEXT, blob_value BLOB);")

        // Large enough that a dangling-pointer bind would almost certainly read freed memory
        // rather than accidentally-valid bytes.
        let blob = Data((0..<256_000).map { UInt8(truncatingIfNeeded: $0 &+ 0x5A) })
        let text = String(repeating: "Hisingen-持久化-", count: 4_000)

        for id in 1...3 {
            // Force allocations between the bind and the step: the temporary string/buffer
            // lifetimes must not matter (this is what SQLITE_STATIC got wrong).
            try autoreleasepool {
                try db.query(sql: "INSERT INTO payloads (id, text_value, blob_value) VALUES (?, ?, ?);") { stmt in
                    try stmt.bindInt64(Int64(id), at: 1)
                    try stmt.bindText(text + String(id), at: 2)
                    try stmt.bindBlob(blob, at: 3)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        }

        for id in 1...3 {
            let row = try db.query(sql: "SELECT text_value, blob_value FROM payloads WHERE id = ?;") { stmt in
                try stmt.bindInt64(Int64(id), at: 1)
            } process: { stmt -> (String, Data)? in
                guard stmt.step(),
                      let t = stmt.columnText(at: 0),
                      let b = stmt.columnBlob(at: 1) else { return nil }
                return (t, b)
            }
            #expect(row?.0 == text + String(id))
            #expect(row?.1 == blob)
        }
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
        #expect(vdb.storageAvailable)
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
        #expect(history.first?.measurementSource == "calculated-v2")
        #expect(history.last?.odometerKm == 10000)
    }

    @Test("Battery health skips readings that duplicate the last milestone")
    func testBatteryHealthSkipsUnchangedReadings() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "BATTERY_VIN_DEDUP"

        // First reading always lands — there is no history to compare against.
        #expect(vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 10_000, sohPct: 98.5, degPct: 1.5, usableKwh: 76.8
        ))

        // A refresh minutes later reporting the same figures carries no new information.
        for _ in 0..<20 {
            #expect(vdb.recordBatteryHealthMilestone(
                vin: vin, odometerKm: 10_000, sohPct: 98.5, degPct: 1.5, usableKwh: 76.8
            ) == false)
        }
        #expect(vdb.batteryHealthHistory(for: vin, limit: 50).count == 1)

        // Noise below the threshold is still noise.
        #expect(vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 10_050, sohPct: 98.6, degPct: 1.4, usableKwh: 76.8
        ) == false)

        // Real SoH movement earns a row.
        #expect(vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 10_060, sohPct: 97.9, degPct: 2.1, usableKwh: 76.2
        ))

        // So does meaningful distance, even at an unchanged SoH.
        #expect(vdb.recordBatteryHealthMilestone(
            vin: vin, odometerKm: 10_600, sohPct: 97.9, degPct: 2.1, usableKwh: 76.2
        ))
        #expect(vdb.batteryHealthHistory(for: vin, limit: 50).count == 3)
    }

    @Test("Battery health records a heartbeat row once the interval elapses")
    func testBatteryHealthHeartbeatAfterInterval() {
        let vdb = VehicleDatabase.inMemory()
        let previous = BatteryHealthRecord(
            id: 1, vin: "HEARTBEAT_VIN", timestamp: Date(), odometerKm: 10_000,
            stateOfHealthPct: 98.5, degradationPct: 1.5, effectiveUsableKwh: 76.8
        )
        let interval = VehicleDatabase.BatteryHealthMilestone.minimumInterval

        // Identical readings, one second short of the heartbeat: still redundant.
        #expect(vdb.isBatteryHealthMilestone(
            sohPct: 98.5, odometerKm: 10_000, since: previous,
            now: previous.timestamp.addingTimeInterval(interval - 1)
        ) == false)

        // Past the heartbeat, the same readings become a trend point worth keeping.
        #expect(vdb.isBatteryHealthMilestone(
            sohPct: 98.5, odometerKm: 10_000, since: previous,
            now: previous.timestamp.addingTimeInterval(interval)
        ))
    }

    @Test("Telemetry skips refreshes where the vehicle has not moved")
    func testTelemetrySkipsStationaryVehicle() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "TELEMETRY_VIN_DEDUP"

        #expect(vdb.recordTelemetry(
            vin: vin, odometerKm: 12_000, tripManualKm: 120, tripAutoKm: 40,
            avgConsumption: 18.2, ambientTempC: 14, latitude: 57.7, longitude: 11.9
        ))

        // Parked: odometer and both trip meters unchanged, so nothing new to log even
        // though ambient temperature drifts.
        for temp in [13.0, 12.5, 12.0] {
            #expect(vdb.recordTelemetry(
                vin: vin, odometerKm: 12_000, tripManualKm: 120, tripAutoKm: 40,
                avgConsumption: 18.2, ambientTempC: temp, latitude: 57.7, longitude: 11.9
            ) == false)
        }

        // Driving moves the odometer, which is exactly what this table is for.
        #expect(vdb.recordTelemetry(
            vin: vin, odometerKm: 12_014, tripManualKm: 134, tripAutoKm: 54,
            avgConsumption: 18.0, ambientTempC: 12, latitude: 57.8, longitude: 12.0
        ))

        // The first unchanged reading after movement marks the parked boundary;
        // subsequent parked polls are still deduplicated.
        #expect(vdb.recordTelemetry(
            vin: vin, odometerKm: 12_014, tripManualKm: 134, tripAutoKm: 54,
            avgConsumption: 18.0, ambientTempC: 12, latitude: 57.8, longitude: 12.0
        ))
        #expect(vdb.recordTelemetry(
            vin: vin, odometerKm: 12_014, tripManualKm: 134, tripAutoKm: 54,
            avgConsumption: 18.0, ambientTempC: 12, latitude: 57.8, longitude: 12.0
        ) == false)
    }

    @Test("Derived trip history groups adjacent movement and separates parked periods")
    func testDerivedTripGrouping() throws {
        let vdb = VehicleDatabase.inMemory()
        let vin = "TRIP_GROUPING_VIN"
        let start = Date(timeIntervalSince1970: 2_000_000_000)

        func insert(_ minute: Int, odometer: Double) throws {
            try vdb.db.query(sql: """
                INSERT INTO telemetry_logs
                (vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c)
                VALUES (?, ?, ?, NULL, NULL, 18.0, 12.0);
                """) { statement in
                try statement.bindText(vin, at: 1)
                try statement.bindDate(start.addingTimeInterval(Double(minute * 60)), at: 2)
                try statement.bindDouble(odometer, at: 3)
                try statement.executeUpdate()
            } process: { _ in }
        }

        try insert(0, odometer: 100)
        try insert(5, odometer: 110)
        try insert(10, odometer: 120)
        try insert(15, odometer: 120)
        try insert(25, odometer: 125)

        let trips = vdb.derivedTrips(for: vin)
        #expect(trips.count == 2)
        #expect(trips[0].distanceKm == 5)
        #expect(trips[1].distanceKm == 20)
        #expect(vdb.exportTripsCSV(for: vin).contains("Duration (min)"))
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
        let audit = try #require(vdb.recentCommandAudits(for: vin).first)
        #expect(audit.command == "lock")
        #expect(audit.status == "success")
        #expect(audit.durationMs == 1420)
        #expect(vdb.exportCommandAuditsCSV(for: vin).contains("lock"))
    }

    @Test("VehicleDatabase computes record counts and diagnostic metrics")
    func testRecordCountsAndDiagnostics() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "DIAG_VIN_004"

        vdb.recordBatteryHealthMilestone(vin: vin, odometerKm: 12000, sohPct: 98.0, degPct: 2.0, usableKwh: 76.0)
        let sId = vdb.startChargingSession(vin: vin, startSoc: 30.0)
        vdb.recordChargingSample(sessionId: sId, vin: vin, soc: 35.0, powerKw: 11.0, voltage: 230.0, current: 16.0)
        vdb.recordTelemetry(vin: vin, odometerKm: 12000, tripManualKm: 250, tripAutoKm: 45, avgConsumption: 18.5, ambientTempC: 18.0, latitude: 57.7, longitude: 11.9)
        vdb.recordCommandAudit(vin: vin, command: "climate", status: "success")

        let counts = vdb.recordCounts()
        #expect(counts.batteryHealth == 1)
        #expect(counts.chargingSessions == 1)
        #expect(counts.chargingSamples == 1)
        #expect(counts.telemetry == 1)
        #expect(counts.commands == 1)

        vdb.vacuum()
    }

    @Test("VehicleDatabase exposes typed telemetry history without requiring coordinates")
    func testTypedTelemetryHistory() throws {
        let vdb = VehicleDatabase.inMemory()
        let vin = "TELEMETRY_TYPED_HISTORY"
        #expect(vdb.recordTelemetry(
            vin: vin, odometerKm: 42_000, tripManualKm: 120.5, tripAutoKm: 18.2,
            avgConsumption: 17.4, ambientTempC: 9.0, latitude: nil, longitude: nil
        ))
        let record = try #require(vdb.recentTelemetry(for: vin).first)
        #expect(record.odometerKm == 42_000)
        #expect(record.tripAutomaticKm == 18.2)
        #expect(record.averageConsumption == 17.4)
        #expect(vdb.exportTelemetryCSV(for: vin).contains("42000.00"))
    }

    @Test("Disabling location history removes stored coordinates and charging labels")
    func testClearingStoredLocationHistory() throws {
        let vdb = VehicleDatabase.inMemory()
        let vin = "PRIVATE_LOCATION_HISTORY"
        #expect(vdb.recordTelemetry(vin: vin, odometerKm: 1, tripManualKm: nil, tripAutoKm: nil,
                                    avgConsumption: nil, ambientTempC: nil, latitude: 57.7, longitude: 11.9))
        _ = vdb.startChargingSession(vin: vin, startSoc: 20, location: "57.7000°, 11.9000°")
        vdb.clearStoredLocations(for: vin)
        let remaining = try vdb.db.query(sql: "SELECT latitude, longitude FROM telemetry_logs WHERE vin = ? LIMIT 1;") { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> (Double?, Double?) in
            guard stmt.step() else { return (nil, nil) }
            return (stmt.columnDouble(at: 0), stmt.columnDouble(at: 1))
        }
        #expect(remaining.0 == nil)
        #expect(remaining.1 == nil)
        #expect(vdb.activeChargingSession(for: vin)?.locationName == nil)
    }

    @Test("VehicleDatabase retrieves active charging session and samples")
    func testActiveChargingSessionRetrieval() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "ACTIVE_VIN_005"

        #expect(vdb.activeChargingSession(for: vin) == nil)

        let sessionId = vdb.startChargingSession(vin: vin, startSoc: 15.0, location: "Fast Charger 150kW")
        let active = vdb.activeChargingSession(for: vin)
        #expect(active != nil)
        #expect(active?.id == sessionId)
        #expect(active?.startSoc == 15.0)
        #expect(active?.endedAt == nil)

        vdb.recordChargingSample(sessionId: sessionId, vin: vin, soc: 20.0, powerKw: 145.0, voltage: 400.0, current: 362.5)
        vdb.recordChargingSample(sessionId: sessionId, vin: vin, soc: 40.0, powerKw: 110.0, voltage: 400.0, current: 275.0)

        let samples = vdb.chargingSamples(for: sessionId)
        #expect(samples.count == 2)
        #expect(samples.first?.powerKw == 145.0)

        let domainSession = active?.toDomainSession(database: vdb)
        #expect(domainSession?.samples.count == 2)
        #expect(domainSession?.startBatteryPercentage == 15.0)

        vdb.completeChargingSession(id: sessionId, endSoc: 80.0, energyDeliveredKwh: 52.0, peakPowerKw: 145.0, averagePowerKw: 95.0)
        #expect(vdb.activeChargingSession(for: vin) == nil)
    }

    @Test("VehicleDatabase generates valid CSV exports for charging and health")
    func testCSVExport() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "CSV_VIN_006"

        let sessionId = vdb.startChargingSession(vin: vin, startSoc: 20.0, location: "Gothenburg Supercharger")
        vdb.completeChargingSession(id: sessionId, endSoc: 80.0, energyDeliveredKwh: 46.8, peakPowerKw: 150.0, averagePowerKw: 85.0)

        vdb.recordBatteryHealthMilestone(vin: vin, odometerKm: 25000, sohPct: 97.2, degPct: 2.8, usableKwh: 75.8)

        let chargingCSV = vdb.exportChargingSessionsCSV(for: vin)
        #expect(chargingCSV.contains("Session ID,VIN,Started At,Ended At"))
        #expect(chargingCSV.contains("Gothenburg Supercharger"))
        #expect(chargingCSV.contains("46.80"))

        let healthCSV = vdb.exportBatteryHealthCSV(for: vin)
        #expect(healthCSV.contains("Record ID,VIN,Date,Odometer (km)"))
        #expect(healthCSV.contains("25000.0"))
        #expect(healthCSV.contains("97.20"))
    }

    @Test("VehicleDatabase prunes historical samples correctly")
    func testPruneSamples() {
        let vdb = VehicleDatabase.inMemory()
        let vin = "PRUNE_VIN_007"

        let sId = vdb.startChargingSession(vin: vin, startSoc: 10.0)
        vdb.recordChargingSample(sessionId: sId, vin: vin, soc: 20.0, powerKw: 10.0, voltage: 230.0, current: 16.0)

        // Pruning older than 90 days should keep recent samples
        vdb.pruneHistoricalSamples(olderThanDays: 90)
        let counts = vdb.recordCounts()
        #expect(counts.chargingSamples == 1)

        // Pruning older than 0 days (i.e. everything in past) should remove samples
        vdb.pruneHistoricalSamples(olderThanDays: 0)
        let prunedCounts = vdb.recordCounts()
        #expect(prunedCounts.chargingSamples == 0)
        #expect(prunedCounts.chargingSessions == 1) // Session header is preserved!
    }

    @Test("VehicleDatabase schema initialization and migrations are idempotent")
    func testSchemaMigrationIdempotence() {
        let vdb = VehicleDatabase.inMemory()
        #expect(vdb.storageAvailable)
        let counts = vdb.recordCounts()
        #expect(counts.snapshots == 0)
        #expect(counts.chargingSessions == 0)
        #expect(counts.chargingSamples == 0)
        #expect(counts.batteryHealth == 0)
    }
}
