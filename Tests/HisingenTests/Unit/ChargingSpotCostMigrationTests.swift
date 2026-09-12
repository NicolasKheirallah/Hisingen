import Foundation
import Testing
@testable import Hisingen

/// Pins schema migration v5: the spot-cost column appears on legacy databases, old rows
/// read as uncosted, and the writer round-trips.
struct ChargingSpotCostMigrationTests {
    private static let v4Columns = """
        id TEXT PRIMARY KEY NOT NULL,
        vin TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        start_soc REAL NOT NULL,
        end_soc REAL,
        energy_delivered_kwh REAL DEFAULT 0.0,
        peak_power_kw REAL DEFAULT 0.0,
        average_power_kw REAL DEFAULT 0.0,
        location_name TEXT,
        created_at REAL NOT NULL,
        lifecycle_state TEXT NOT NULL DEFAULT 'active',
        completion_reason TEXT,
        energy_source TEXT NOT NULL DEFAULT 'soc_capacity_estimate',
        confidence TEXT NOT NULL DEFAULT 'low',
        sample_coverage REAL,
        usable_capacity_kwh REAL,
        tariff_price_per_kwh REAL,
        night_tariff_enabled INTEGER NOT NULL DEFAULT 0,
        night_tariff_price_per_kwh REAL,
        night_tariff_start_hour INTEGER,
        night_tariff_end_hour INTEGER,
        currency_symbol TEXT,
        target_soc REAL,
        last_observed_at REAL,
        summary_version INTEGER NOT NULL DEFAULT 2,
        pending_stop_count INTEGER NOT NULL DEFAULT 0,
        estimated_cost REAL
        """

    @Test func freshDatabaseHasSpotColumnAtLatestVersion() throws {
        let database = VehicleDatabase.inMemory()
        let ledger = database.charging
        let id = ledger.startChargingSession(vin: "MIG-VIN", startSoc: 20, startedAt: Date())
        ledger.completeChargingSession(id: id, endSoc: 40, energyDeliveredKwh: 15,
                                       peakPowerKw: 11, averagePowerKw: 11,
                                       endedAt: Date().addingTimeInterval(3_600),
                                       lifecycleState: .completed, completionReason: .targetReached,
                                       energySource: .observedPowerIntegration, confidence: .high)
        let session = try #require(ledger.recentChargingSessions(for: "MIG-VIN").first)
        #expect(session.spotEstimatedCost == nil)
    }

    @Test func legacyV4DatabaseMigratesAndOldRowsReadUncosted() throws {
        let raw = try SQLiteDatabase.inMemory()
        try raw.execute(sql: """
            CREATE TABLE charging_sessions (\(Self.v4Columns));
            PRAGMA user_version = 4;
            """)
        let started = Date(timeIntervalSince1970: 1_789_100_000)
        try raw.query(sql: """
            INSERT INTO charging_sessions (
                id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
                lifecycle_state, created_at, estimated_cost
            ) VALUES ('legacy-1', 'OLD-VIN', ?, ?, 20, 50, 20, 'completed', ?, 7.4);
            """) { stmt in
            try stmt.bindDate(started, at: 1)
            try stmt.bindDate(started.addingTimeInterval(7_200), at: 2)
            try stmt.bindDate(started, at: 3)
            // `query` only prepares and binds; a write must step explicitly.
            try stmt.executeUpdate()
        } process: { _ in }

        let database = VehicleDatabase(database: raw)
        #expect(database.charging.recentChargingSessions(for: "OLD-VIN").count == 1)
        let session = try #require(database.charging.recentChargingSessions(for: "OLD-VIN").first)
        #expect(session.spotEstimatedCost == nil, "pre-migration rows must read as uncosted")

        database.charging.updateSpotEstimatedCost(id: "legacy-1", cost: 21.5)
        #expect(abs((database.charging.recentChargingSessions(for: "OLD-VIN").first?.spotEstimatedCost ?? 0) - 21.5) < 0.001)
    }
}
