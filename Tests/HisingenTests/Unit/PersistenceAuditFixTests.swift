import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PersistenceAuditFixTests {
    @Test
    func failedMigrationsKeepLegacyDataAndRollBack() throws {
        let suite = "HisingenTests.MigrationFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = "YSM-MIGRATION-A"
        let second = "YSM-MIGRATION-B"
        let snapshotKey = "cached_vehicle_snapshots_v1"
        let baselineKey = "charging_baselines_v1"
        let receiptKey = "command_receipts_v1"
        let baseline: (String, Double) -> ChargingBaseline = { vin, battery in
            ChargingBaseline(vin: vin, state: .charging, connection: .connected,
                batteryPercentage: battery, targetPercentage: 80, vehicleReportedAt: Date(),
                sampledAt: Date(), chargingSessionActive: true, interruptionSamples: 0, lowBatteryNotified: false)
        }
        let receipt = StoredCommandReceipts(records: [StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "lock", issuedAt: Date()), confirmationDeadline: nil)])
        let legacyState = vehicle(vin: first, battery: 42, brand: .polestar)
        let secondState = vehicle(vin: second, battery: 42, brand: .polestar)
        defaults.set(try JSONEncoder().encode([first: legacyState, second: secondState]), forKey: snapshotKey)
        defaults.set(try JSONEncoder().encode([first: baseline(first, 42), second: baseline(second, 42)]), forKey: baselineKey)
        defaults.set(try JSONEncoder().encode([first: receipt, second: receipt]), forKey: receiptKey)
        let unavailable = VehicleDatabase(database: .unavailable(path: ":unavailable:"))
        VehicleStateStore(defaults: defaults, database: unavailable).activate()
        for key in [snapshotKey, baselineKey, receiptKey] { #expect(defaults.data(forKey: key) != nil) }

        let db = VehicleDatabase.inMemory()
        let currentState = vehicle(vin: first, battery: 91, brand: .polestar)
        db.snapshots.saveSnapshot(currentState)
        db.baselines.saveBaseline(baseline(first, 91))
        let currentReceipt = StoredCommandReceipts(records: [StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "unlock", issuedAt: Date()), confirmationDeadline: nil)])
        db.commandReceipts.saveCommandReceipts(currentReceipt, for: first)
        for table in ["vehicle_snapshots", "charging_baselines", "command_receipts"] {
            try db.db.execute(sql: "CREATE TRIGGER fail_\(table) BEFORE INSERT ON \(table) WHEN NEW.vin = 'YSM-MIGRATION-B' BEGIN SELECT RAISE(ABORT, 'injected failure'); END;")
        }
        let store = VehicleStateStore(defaults: defaults, database: db)
        store.activate()
        for key in [snapshotKey, baselineKey, receiptKey] { #expect(defaults.data(forKey: key) != nil) }
        #expect(db.snapshots.loadSnapshot(for: second) == nil)
        #expect(db.baselines.loadBaseline(for: second) == nil)
        #expect(db.commandReceipts.loadCommandReceipts(for: second) == nil)
        for table in ["vehicle_snapshots", "charging_baselines", "command_receipts"] {
            try db.db.execute(sql: "DROP TRIGGER fail_\(table);")
        }
        store.activate()
        for key in [snapshotKey, baselineKey, receiptKey] { #expect(defaults.data(forKey: key) == nil) }
        #expect(store.snapshot(for: first)?.energy.batteryPercentage == 91)
        #expect(store.baseline(for: first)?.batteryPercentage == 91)
        #expect(db.commandReceipts.loadCommandReceipts(for: first) == currentReceipt)
        #expect(store.snapshot(for: second) != nil)
        #expect(store.baseline(for: second) != nil)
        #expect(db.commandReceipts.loadCommandReceipts(for: second) == receipt)
    }

    @Test
    func sessionErasePropagatesDatabaseFailure() throws {
        let suite = "HisingenTests.EraseFailure.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = VehicleDatabase.inMemory()
        let state = vehicle(vin: "YSM-TEST", battery: 72, brand: .polestar)
        db.snapshots.saveSnapshot(state)
        try db.db.execute(sql: "DROP TABLE command_receipts;")
        let eraser = LocalDataEraser(database: db, preferences: PreferencesStore(defaults: defaults), imageCache: .shared)
        #expect(throws: (any Error).self) { try eraser.perform(.session(.vehicle("YSM-TEST"))) }
        #expect(db.snapshots.loadSnapshot(for: "YSM-TEST") != nil)
    }

    @Test
    func failedReadStepDoesNotReturnPartialResults() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(throws: (any Error).self) {
            try db.query(sql: "SELECT 1 UNION ALL SELECT abs(-9223372036854775808)") { _ in } process: { statement in
                var rows: [Int64] = []
                while try statement.stepOrThrow() { rows.append(statement.columnInt64(at: 0) ?? 0) }
                return rows
            }
        }
    }

    @Test
    func expiredCleanupKeepsANewerReplacement() throws {
        let database = VehicleDatabase.inMemory()
        let state = vehicle(vin: "YSM-REPLACED", battery: 72, brand: .polestar)
        database.snapshots.saveSnapshot(state)
        database.snapshots.deleteExpiredSnapshot(for: state.identity.vin, cutoff: Date().addingTimeInterval(-60))
        #expect(database.snapshots.loadSnapshot(for: state.identity.vin) != nil)
    }

    @Test
    func queuedHistoryCannotRepopulateAfterErase() async throws {
        let suite = "HisingenTests.HistoryErase.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = VehicleDatabase.inMemory()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let prefs = PreferencesStore(defaults: defaults)
        let recorder = VehicleHistoryRecorder(database: db, preferences: prefs, beforePersist: {
            entered.signal()
            _ = resume.wait(timeout: .now() + 5)
        })
        var state = vehicle(vin: "YSM-ERASE", battery: 72, brand: .polestar)
        state.maintenance.odometerKm = 1234
        recorder.record(state)
        defer { resume.signal() }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        try #require(didEnter)
        let eraser = LocalDataEraser(database: db, preferences: prefs, imageCache: .shared)
        try eraser.perform(.everything(.vehicle(state.identity.vin)))
        resume.signal()
        await recorder.drain()
        #expect(db.history.recentTelemetry(for: state.identity.vin).isEmpty)
    }
    @Test(arguments: ["locationsVehicle", "sessionVehicle", "locationsAll", "sessionAll", "everythingAll"])
    func scopedEraseInvalidatesOnlyAffectedQueuedHistory(scope: String) async throws {
        let suite = "HisingenTests.ScopedHistoryErase.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = VehicleDatabase.inMemory()
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal(); resume.signal() }
        let prefs = PreferencesStore(defaults: defaults)
        let recorder = VehicleHistoryRecorder(database: db, preferences: prefs, beforePersist: {
            entered.signal()
            _ = resume.wait(timeout: .now() + 5)
        })
        let vinA = "YSM-SCOPED-A"
        let vinB = "YSM-SCOPED-B"
        for vin in [vinA, vinB] {
            try db.db.query(sql: "INSERT INTO telemetry_logs (vin, timestamp, odometer_km, latitude, longitude) VALUES (?, 1, 1, 57, 11)") { stmt in
                try stmt.bindText(vin, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        var a = vehicle(vin: vinA, battery: 72, brand: .polestar)
        var b = vehicle(vin: vinB, battery: 72, brand: .polestar)
        a.maintenance.odometerKm = 1234
        b.maintenance.odometerKm = 5678
        recorder.record(a)
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        try #require(didEnter)
        recorder.record(b)
        let eraser = LocalDataEraser(database: db, preferences: prefs, imageCache: .shared)
        switch scope {
        case "locationsVehicle": try await eraser.performInBackground(.locations(.vehicle(vinA)))
        case "sessionVehicle": try eraser.perform(.session(.vehicle(vinA)))
        case "locationsAll": try await eraser.performInBackground(.locations(.all))
        case "sessionAll": try eraser.perform(.session(.all))
        default: try await eraser.performInBackground(.everything(.all))
        }
        resume.signal()
        resume.signal()
        await recorder.drain()
        let rowsA = db.history.recentTelemetry(for: vinA)
        let rowsB = db.history.recentTelemetry(for: vinB)
        if scope == "everythingAll" {
            #expect(rowsA.isEmpty && rowsB.isEmpty)
        } else {
            #expect(rowsA.count == 1)
            #expect(rowsB.count == (scope.hasSuffix("Vehicle") ? 2 : 1))
            if scope.hasPrefix("locations") {
                #expect(rowsA.first?.latitude == nil)
                let originalB = rowsB.first { $0.odometerKm == 1 }
                #expect(originalB?.latitude == (scope == "locationsVehicle" ? 57 : nil))
            }
        }
    }

    @Test
    func admissionFenceRejectsObservationsDuringBackgroundErase() async throws {
        let suite = "HisingenTests.AdmissionFence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = VehicleDatabase.inMemory()
        let prefs = PreferencesStore(defaults: defaults)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let eraser = LocalDataEraser(database: db, preferences: prefs, imageCache: .shared, beforeSQL: {
            entered.signal()
            _ = resume.wait(timeout: .now() + 5)
        })
        let store = VehicleStateStore(defaults: defaults, database: db, preferences: prefs)
        let task = Task { try await eraser.performInBackground(.everything(.vehicle("YSM-FENCED"))) }
        let didEnter = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success)
            }
        }
        try #require(didEnter)
        var blocked = vehicle(vin: "YSM-FENCED", battery: 72, brand: .polestar)
        blocked.maintenance.odometerKm = 1234
        var allowed = vehicle(vin: "YSM-OTHER", battery: 72, brand: .polestar)
        allowed.maintenance.odometerKm = 5678
        store.save(blocked)
        store.save(allowed)
        resume.signal()
        try await task.value
        await store.drainHistory()
        #expect(store.snapshot(for: blocked.identity.vin) == nil)
        #expect(db.history.recentTelemetry(for: blocked.identity.vin).isEmpty)
        #expect(store.snapshot(for: allowed.identity.vin) != nil)
        #expect(!db.history.recentTelemetry(for: allowed.identity.vin).isEmpty)
    }

    @Test
    func overlappingEraseLeasesKeepAdmissionClosedUntilAllEnd() {
        let db = VehicleDatabase.inMemory()
        let first = db.beginHistoryErase(scope: .everything(.vehicle("VIN-A")))
        let second = db.beginHistoryErase(scope: .locations(.vehicle("VIN-A")))
        #expect(db.historyToken(for: "VIN-A") == nil)
        #expect(db.historyToken(for: "VIN-B") != nil)
        db.endHistoryErase(first)
        #expect(db.historyToken(for: "VIN-A") == nil)
        db.endHistoryErase(second)
        #expect(db.historyToken(for: "VIN-A") != nil)
    }

    @Test
    func failedLocationEraseReopensAdmissionAndKeepsLocationRecordingDisabled() async throws {
        let suite = "HisingenTests.FailedLocationErase.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let preferences = PreferencesStore(defaults: defaults)
        preferences.persistLocationHistory = true
        try database.db.execute(sql: "DROP TABLE telemetry_logs;")
        let eraser = LocalDataEraser(database: database, preferences: preferences, imageCache: .shared)
        do {
            try await eraser.performInBackground(.locations(.vehicle("VIN-FAIL")))
            Issue.record("Expected the missing telemetry table to make erasure fail")
        } catch {
            #expect(database.historyToken(for: "VIN-FAIL") != nil)
            #expect(preferences.persistLocationHistory == false)
        }
    }

}
