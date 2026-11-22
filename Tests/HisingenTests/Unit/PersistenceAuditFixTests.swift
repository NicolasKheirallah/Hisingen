import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PersistenceAuditFixTests {
    /// A scoped Keychain service beside the scoped defaults domain. A full-fleet erase asks
    /// the account store for stored secrets, and the real app service would prompt in a test
    /// process; a throwaway service has no item to protect.
    private func scopedPreferences(_ defaults: UserDefaults) -> PreferencesStore {
        PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"))
    }

    @Test
    func activationDeletesLegacyPlistCachesWithoutImportingThem() throws {
        let suite = "HisingenTests.LegacyMirrors.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let vin = "YSM-LEGACY-A"
        let snapshotKey = "cached_vehicle_snapshots_v1"
        let baselineKey = "charging_baselines_v1"
        let receiptKey = "command_receipts_v1"
        let receipt = StoredCommandReceipts(records: [StoredCommandReceipt(
            receipt: CommandReceipt(commandIdentifier: "lock", issuedAt: Date()), confirmationDeadline: nil)])
        defaults.set(try JSONEncoder().encode([vin: vehicle(vin: vin, battery: 42, brand: .polestar)]), forKey: snapshotKey)
        defaults.set(try JSONEncoder().encode([vin: receipt]), forKey: receiptKey)
        // An unreadable payload must go too: a snapshot can hold a location or an owner name.
        defaults.set(Data("not json".utf8), forKey: baselineKey)

        let db = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: defaults, database: db)
        store.activate()

        for key in [snapshotKey, baselineKey, receiptKey] { #expect(defaults.data(forKey: key) == nil) }
        #expect(store.snapshot(for: vin) == nil)
        #expect(store.baseline(for: vin) == nil)
        #expect(db.commandReceipts.loadCommandReceipts(for: vin) == nil)
    }

    @Test
    func cachedSnapshotAnswersUntilTheRetentionHorizon() throws {
        let db = VehicleDatabase.inMemory()
        var young = vehicle(vin: "YSM-AGE-YOUNG", battery: 50, brand: .polestar)
        young.freshness.fetchedAt = Date().addingTimeInterval(-(VehicleDatabase.cacheRetention - 60))
        var old = vehicle(vin: "YSM-AGE-OLD", battery: 50, brand: .polestar)
        old.freshness.fetchedAt = Date().addingTimeInterval(-(VehicleDatabase.cacheRetention + 60))
        db.snapshots.saveSnapshot(young)
        db.snapshots.saveSnapshot(old)

        #expect(db.snapshots.loadSnapshot(for: "YSM-AGE-YOUNG") != nil)
        #expect(db.snapshots.loadSnapshot(for: "YSM-AGE-OLD") == nil)
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
        let eraser = LocalDataEraser(database: db, preferences: scopedPreferences(defaults), imageCache: CarImageCache())
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
        let prefs = scopedPreferences(defaults)
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
        let eraser = LocalDataEraser(database: db, preferences: prefs, imageCache: CarImageCache())
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
        let prefs = scopedPreferences(defaults)
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
        let eraser = LocalDataEraser(
            database: db, preferences: prefs, imageCache: CarImageCache(), clearAccounts: {})
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
    func fullFleetEraseCallsTheInjectedAccountClearHookOnly() throws {
        let suite = "HisingenTests.AccountHook.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var clears = 0
        let eraser = LocalDataEraser(
            database: VehicleDatabase.inMemory(), preferences: scopedPreferences(defaults),
            imageCache: CarImageCache(), clearAccounts: { clears += 1 })

        try eraser.perform(.everything(.all))
        #expect(clears == 1, "a full-fleet erase must clear the accounts")

        try eraser.perform(.everything(.vehicle("YSM-HOOK-VIN")))
        #expect(clears == 1, "a per-vehicle erase must leave the accounts alone")
    }

    @Test
    func admissionFenceRejectsObservationsDuringBackgroundErase() async throws {
        let suite = "HisingenTests.AdmissionFence.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = VehicleDatabase.inMemory()
        let prefs = scopedPreferences(defaults)
        let entered = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        defer { resume.signal() }
        let eraser = LocalDataEraser(database: db, preferences: prefs, imageCache: CarImageCache(), beforeSQL: {
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
        let preferences = scopedPreferences(defaults)
        preferences.persistLocationHistory = true
        try database.db.execute(sql: "DROP TABLE telemetry_logs;")
        let eraser = LocalDataEraser(database: database, preferences: preferences, imageCache: CarImageCache())
        do {
            try await eraser.performInBackground(.locations(.vehicle("VIN-FAIL")))
            Issue.record("Expected the missing telemetry table to make erasure fail")
        } catch {
            #expect(database.historyToken(for: "VIN-FAIL") != nil)
            #expect(preferences.persistLocationHistory == false)
        }
    }

}
