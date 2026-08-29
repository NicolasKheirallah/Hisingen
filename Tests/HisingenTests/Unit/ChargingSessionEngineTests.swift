import Foundation
import Testing
@testable import Hisingen

@Suite("Charging session lifecycle engine")
struct ChargingSessionEngineTests {
    private let vin = "ENGINE-TEST-VIN"
    private let start = Date(timeIntervalSince1970: 1_780_100_000)
    private let configuration = ChargingSessionEngineConfiguration(
        usableCapacityKwh: 79, tariffPricePerKwh: 0.37,
        nightTariffEnabled: true, nightTariffPricePerKwh: 0.18,
        nightTariffStartHour: 22, nightTariffEndHour: 6,
        currencySymbol: "€", locationName: "Home"
    )

    @Test("Paused and scheduled states remain one physical session")
    func pauseResumeAndComplete() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)

        ingest(engine, minutes: 0, soc: 20, state: .charging, power: 11)
        let originalID = try #require(database.activeChargingSession(for: vin)?.id)
        ingest(engine, minutes: 30, soc: 30, state: .charging, power: 11)
        ingest(engine, minutes: 35, soc: 30, state: .paused, power: nil)
        #expect(database.activeChargingSession(for: vin)?.lifecycleState == .paused)
        ingest(engine, minutes: 40, soc: 30, state: .scheduled, power: nil)
        ingest(engine, minutes: 60, soc: 40, state: .charging, power: 11)
        #expect(database.activeChargingSession(for: vin)?.id == originalID)
        ingest(engine, minutes: 90, soc: 50, state: .complete, power: nil)

        let session = try #require(database.recentChargingSessions(for: vin).first)
        #expect(session.id == originalID)
        #expect(session.lifecycleState == .completed)
        #expect(session.completionReason == .targetReached)
        #expect(session.energySource == .socCapacityEstimate)
        #expect(session.confidence == .medium)
        #expect(abs(session.energyDeliveredKwh - 23.7) < 0.001)
        #expect(abs((session.estimatedCost ?? 0) - 4.266) < 0.001)
        #expect(session.tariffPricePerKwh == 0.37)
        #expect(session.nightTariffEnabled)
        #expect(session.nightTariffPricePerKwh == 0.18)
        #expect(session.nightTariffStartHour == 22)
        #expect(session.nightTariffEndHour == 6)
        #expect(session.currencySymbol == "€")
        #expect(session.targetSoc == 80)
        #expect(session.summaryVersion == 2)
    }

    @Test("One idle poll is debounced and active charging resumes the same session")
    func stopDebounceAndResume() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        ingest(engine, minutes: 0, soc: 40, state: .charging, power: nil)
        let id = try #require(database.activeChargingSession(for: vin)?.id)
        ingest(engine, minutes: 10, soc: 45, state: .idle, power: nil, connection: .disconnected)

        let pending = try #require(database.activeChargingSession(for: vin))
        #expect(pending.lifecycleState == .pendingCompletion)
        #expect(pending.pendingStopCount == 1)
        #expect(database.recentChargingSessions(for: vin).isEmpty)

        ingest(engine, minutes: 20, soc: 46, state: .charging, power: nil)
        #expect(database.activeChargingSession(for: vin)?.id == id)
        #expect(database.activeChargingSession(for: vin)?.pendingStopCount == 0)
        ingest(engine, minutes: 30, soc: 50, state: .idle, power: nil, connection: .disconnected)
        ingest(engine, minutes: 40, soc: 50, state: .idle, power: nil, connection: .disconnected)

        let completed = try #require(database.recentChargingSessions(for: vin).first)
        #expect(completed.id == id)
        #expect(completed.lifecycleState == .interrupted)
        #expect(completed.completionReason == .disconnected)
        #expect(completed.endSoc == 50)
    }

    @Test("Dense power observations use integration and report high confidence")
    func integratedObservedPower() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        for minute in stride(from: 0, through: 50, by: 10) {
            ingest(engine, minutes: minute, soc: 20 + Double(minute) / 3,
                   state: .charging, power: 6)
        }
        ingest(engine, minutes: 60, soc: 40, state: .complete, power: 6)

        let session = try #require(database.recentChargingSessions(for: vin).first)
        #expect(session.energySource == .observedPowerIntegration)
        #expect(session.confidence == .high)
        #expect(abs(session.energyDeliveredKwh - 6) < 0.001)
        #expect(abs((session.sampleCoverage ?? 0) - 1) < 0.001)
        #expect(session.peakPowerKw == 6)
    }

    @Test("A debounced stop at the saved target is completed, not interrupted")
    func idleAtTargetCompletes() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        ingest(engine, minutes: 0, soc: 70, state: .charging, power: nil)
        ingest(engine, minutes: 30, soc: 80, state: .idle, power: nil)
        ingest(engine, minutes: 31, soc: 80, state: .idle, power: nil)

        let session = try #require(database.recentChargingSessions(for: vin).first)
        #expect(session.lifecycleState == .completed)
        #expect(session.completionReason == .targetReached)
    }

    @Test("Fault finalizes a gained session as interrupted")
    func faultInterruption() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        ingest(engine, minutes: 0, soc: 20, state: .charging, power: 7)
        ingest(engine, minutes: 15, soc: 25, state: .idle, power: nil, connection: .fault)

        let session = try #require(database.recentChargingSessions(for: vin).first)
        #expect(session.lifecycleState == .interrupted)
        #expect(session.completionReason == .fault)
    }

    @Test("A stale open observation is abandoned before a new charge starts")
    func staleSessionBoundary() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        ingest(engine, minutes: 0, soc: 20, state: .charging, power: nil)
        let oldID = try #require(database.activeChargingSession(for: vin)?.id)
        ingest(engine, minutes: 49 * 60, soc: 55, state: .charging, power: nil)

        let newSession = try #require(database.activeChargingSession(for: vin))
        #expect(newSession.id != oldID)
        #expect(newSession.startSoc == 55)
        #expect(database.recordCounts().chargingSessions == 2)
    }

    @Test("Schema migration version and lifecycle columns are installed idempotently")
    func schemaVersionTwo() throws {
        let database = VehicleDatabase.inMemory()
        let version = try database.db.query(sql: "PRAGMA user_version;") { _ in } process: { statement in
            statement.step() ? Int(statement.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(version == 2)
        let columns = try database.db.query(sql: "PRAGMA table_info(charging_sessions);") { _ in } process: { statement in
            var names = Set<String>()
            while statement.step() {
                if let name = statement.columnText(at: 1) { names.insert(name) }
            }
            return names
        }
        #expect(columns.contains("lifecycle_state"))
        #expect(columns.contains("energy_source"))
        #expect(columns.contains("sample_coverage"))
        #expect(columns.contains("night_tariff_price_per_kwh"))
        #expect(columns.contains("summary_version"))
    }

    @Test("A version-one charging table upgrades before lifecycle indexes are created")
    func legacySchemaMigratesWithoutLaunchFailure() throws {
        let sqlite = try SQLiteDatabase.inMemory()
        try sqlite.execute(sql: """
            CREATE TABLE charging_sessions (
                id TEXT PRIMARY KEY NOT NULL, vin TEXT NOT NULL,
                started_at REAL NOT NULL, ended_at REAL, start_soc REAL NOT NULL,
                end_soc REAL, energy_delivered_kwh REAL DEFAULT 0.0,
                peak_power_kw REAL DEFAULT 0.0, average_power_kw REAL DEFAULT 0.0,
                location_name TEXT, created_at REAL NOT NULL
            );
            INSERT INTO charging_sessions (
                id, vin, started_at, ended_at, start_soc, end_soc,
                energy_delivered_kwh, created_at
            ) VALUES ('legacy', 'LEGACY-VIN', 100, 200, 20, 40, 15.8, 100);
            PRAGMA user_version = 1;
            """)

        let database = VehicleDatabase(database: sqlite)
        let migrated = try #require(database.recentChargingSessions(for: "LEGACY-VIN").first)
        #expect(migrated.lifecycleState == .completed)
        #expect(migrated.energySource == .legacyEstimate)
        #expect(migrated.summaryVersion == 1)
        let version = try sqlite.query(sql: "PRAGMA user_version;") { _ in } process: { statement in
            statement.step() ? Int(statement.columnInt64(at: 0) ?? 0) : 0
        }
        #expect(version == 2)
    }

    @Test("A stale open session observed idle is abandoned, not completed")
    func staleIdleDoesNotCreateMultiDayCharge() throws {
        let database = VehicleDatabase.inMemory()
        let engine = ChargingSessionEngine(database: database)
        ingest(engine, minutes: 0, soc: 20, state: .charging, power: nil)
        ingest(engine, minutes: 49 * 60, soc: 60, state: .idle, power: nil)

        #expect(database.activeChargingSession(for: vin) == nil)
        #expect(database.recentChargingSessions(for: vin).isEmpty)
        #expect(database.recordCounts().chargingSessions == 1)
        let abandonedAt = try database.db.query(
            sql: "SELECT ended_at FROM charging_sessions WHERE vin = ?;",
            bindings: { statement in try statement.bindText(vin, at: 1) },
            process: { statement in statement.step() ? statement.columnDate(at: 0) : nil }
        )
        #expect(abandonedAt == start)
    }

    private func ingest(
        _ engine: ChargingSessionEngine, minutes: Int, soc: Double,
        state: ChargingState, power: Double?, connection: ChargerConnection = .connected
    ) {
        engine.ingest(
            ChargingSessionObservation(
                vin: vin, timestamp: start.addingTimeInterval(Double(minutes) * 60),
                soc: soc, chargingState: state, chargerConnection: connection,
                powerKw: power, voltageVolts: nil, currentAmps: nil,
                chargingType: .ac, targetSoc: 80
            ),
            configuration: configuration, recordingEnabled: true
        )
    }
}
