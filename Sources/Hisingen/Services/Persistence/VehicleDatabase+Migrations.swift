import Foundation
import OSLog

extension VehicleDatabase {
    /// Removes old `*.pre-vN.bak` snapshots once the schema has fully reached the latest version,
    /// while retaining the backup created for the current schema migration.
    /// `backupBeforeMigration` writes one (a full-size `VACUUM INTO` copy) before each schema
    /// bump and nothing ever deleted them, so a few version bumps left several ~20 MB copies
    /// beside the live database. A failed migration leaves `user_version` below target, so the
    /// backup is only eligible for rotation after the migration it guards has actually landed.
    /// Keeping the newest one matters: a migration can complete successfully yet still reveal
    /// a semantic data problem later, and deleting its just-created backup made that unrecoverable.
    func pruneMigrationBackups() {
        guard schemaVersion() >= Self.latestSchemaVersion,
              db.path != ":memory:", db.path != ":unavailable:", !db.path.isEmpty else { return }
        let directory = (db.path as NSString).deletingLastPathComponent
        let prefix = (db.path as NSString).lastPathComponent + ".pre-v"
        let retainedName = "\(prefix)\(Self.latestSchemaVersion).bak"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(".bak")
            && entry != retainedName {
            try? FileManager.default.removeItem(atPath: (directory as NSString).appendingPathComponent(entry))
        }
    }

    func schemaVersion() -> Int {
        (try? db.query(sql: "PRAGMA user_version;") { _ in } process: { stmt -> Int in
            try stmt.stepOrThrow() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }) ?? 0
    }

    /// One-shot copy of the database taken immediately before a schema migration, so a bad
    /// migration or a mid-upgrade crash leaves a recoverable "before" file. Skipped for fresh
    /// installs (nothing to lose) and in-memory databases; never overwrites an existing
    /// backup for the same target version. Returns `false` only when a needed backup could not
    /// be written, so the caller can flag the migration that follows as unprotected.
    func backupBeforeMigration(from currentVersion: Int) -> Bool {
        guard databaseFilePreexisted,
              currentVersion < Self.latestSchemaVersion,
              db.path != ":memory:", db.path != ":unavailable:", !db.path.isEmpty else { return true }
        let backupPath = db.path + ".pre-v\(Self.latestSchemaVersion).bak"
        guard !FileManager.default.fileExists(atPath: backupPath) else { return true }
        guard isSafeBackupPath(backupPath, basePath: db.path) else {
            logger.error("Refusing pre-migration backup to unsafe path")
            return false
        }
        let escaped = backupPath.replacingOccurrences(of: "'", with: "''")
        do {
            try db.execute(sql: "VACUUM INTO '\(escaped)';")
            logger.notice("Wrote pre-migration database backup to \(backupPath, privacy: .public)")
            applyRestrictivePermissions(at: backupPath)
            return true
        } catch {
            logger.error("Pre-migration database backup failed: \(error, privacy: .public)")
            return false
        }
    }

    private func isSafeBackupPath(_ backupPath: String, basePath: String) -> Bool {
        guard !backupPath.isEmpty, !backupPath.contains("\0"),
              !backupPath.contains(";"), !backupPath.contains("--") else { return false }
        let baseDir = (basePath as NSString).deletingLastPathComponent
        let backupDir = (backupPath as NSString).deletingLastPathComponent
        guard backupDir == baseDir else { return false }
        let baseURL = URL(fileURLWithPath: baseDir).standardizedFileURL
        let backupURL = URL(fileURLWithPath: backupPath).standardizedFileURL
        return backupURL.path.hasPrefix(baseURL.path)
    }

    private func applyRestrictivePermissions(at path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }

    /// Adds a column unless it already exists. A failed ALTER is logged with its statement; the
    /// callers re-check `columnExists` before advancing `user_version`, so a failure retries.
    private func addColumnIfMissing(table: String, column: String, declaration: String) {
        guard !columnExists(table: table, column: column) else { return }
        let sql = "ALTER TABLE \(table) ADD COLUMN \(column) \(declaration);"
        do {
            try db.execute(sql: sql)
        } catch {
            logger.error("Migration statement failed: \(sql, privacy: .public) – \(error, privacy: .public)")
        }
    }

    private func columnExists(table: String, column: String) -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        let columns = (try? db.query(sql: sql) { _ in } process: { stmt -> Set<String> in
            var names = Set<String>()
            while try stmt.stepOrThrow() {
                if let name = stmt.columnText(at: 1) { names.insert(name.lowercased()) }
            }
            return names
        }) ?? []
        return columns.contains(column.lowercased())
    }

    /// Ordered, version-gated schema migrations tracked by `PRAGMA user_version`.
    ///
    /// The baseline DDL above stays idempotent and runs on every launch; anything that
    /// rewrites data or must run exactly once belongs here instead of being re-executed with
    /// `try?` every start-up (which made a failed migration indistinguishable from success).
    /// Version 1 reproduces the pre-`user_version` ad-hoc ALTERs for existing installs.
    ///
    /// Additive only: `ALTER TABLE ADD COLUMN`, `CREATE TABLE/INDEX IF NOT EXISTS`, and
    /// in-place `UPDATE`s. A migration must never `DROP` or recreate a table that can hold
    /// user history – `VehicleDatabaseMigrationTests` guards that rows survive an upgrade.
    /// Internal (not private) so the migration round-trip test can drive the machinery
    /// directly: open a store, re-run the migrator, assert the version holds steady.
    func runMigrations(from currentVersion: Int) {
        // Local version cursor: a block only advances it after its statements succeeded, and
        // each block only runs when the previous one completed, so a failed migration can
        // never be skipped by a later block bumping `user_version` past it – it retries on
        // the next launch instead.
        var version = currentVersion

        // v1: quarantine legacy battery-health rows + add the disambiguation columns the
        // baseline now creates for new installs. Idempotent per table.
        if version < 1 {
            addColumnIfMissing(table: "battery_health_history", column: "measurement_source",
                               declaration: "TEXT NOT NULL DEFAULT 'legacy'")
            addColumnIfMissing(table: "telemetry_logs", column: "avg_consumption_unit", declaration: "TEXT")
            addColumnIfMissing(table: "charging_samples", column: "charging_type", declaration: "TEXT")
            let v1ColumnsReady = columnExists(table: "battery_health_history", column: "measurement_source")
                && columnExists(table: "telemetry_logs", column: "avg_consumption_unit")
                && columnExists(table: "charging_samples", column: "charging_type")
            if v1ColumnsReady {
                // Quarantine rows from the old inferred/Volvo-capacity implementation, then
                // record the version – in one statement group so a failed UPDATE (`sqlite3_exec`
                // stops at the first error) never lets `user_version` advance past the
                // quarantine. Previously the bump ran unconditionally and a transient failure
                // skipped the quarantine forever. Mirrors the v2 block below.
                do {
                    try db.execute(sql: """
                        UPDATE battery_health_history SET measurement_source = '\(BatteryHealthRecord.legacyEstimateSource)' WHERE measurement_source = 'measured';
                        PRAGMA user_version = 1;
                        """)
                    version = 1
                } catch {
                    logger.error("Battery-health quarantine migration failed; it will retry next launch: \(error, privacy: .public)")
                }
            } else {
                logger.error("Battery-health schema migration remains incomplete; it will retry next launch")
            }
        }

        // v2: explicit charging-session lifecycle and versioned summary provenance.
        if version == 1 {
            let additions: [(String, String)] = [
                ("lifecycle_state", "TEXT NOT NULL DEFAULT 'active'"),
                ("completion_reason", "TEXT"),
                ("energy_source", "TEXT NOT NULL DEFAULT 'soc_capacity_estimate'"),
                ("confidence", "TEXT NOT NULL DEFAULT 'low'"),
                ("sample_coverage", "REAL"),
                ("usable_capacity_kwh", "REAL"),
                ("tariff_price_per_kwh", "REAL"),
                ("night_tariff_enabled", "INTEGER NOT NULL DEFAULT 0"),
                ("night_tariff_price_per_kwh", "REAL"),
                ("night_tariff_start_hour", "INTEGER"),
                ("night_tariff_end_hour", "INTEGER"),
                ("currency_symbol", "TEXT"),
                ("target_soc", "REAL"),
                ("last_observed_at", "REAL"),
                ("summary_version", "INTEGER NOT NULL DEFAULT 2"),
                ("pending_stop_count", "INTEGER NOT NULL DEFAULT 0"),
                ("estimated_cost", "REAL")
            ]
            for (column, declaration) in additions {
                addColumnIfMissing(table: "charging_sessions", column: column, declaration: declaration)
            }
            if additions.allSatisfy({ columnExists(table: "charging_sessions", column: $0.0) }) {
                do {
                    try db.execute(sql: """
                        UPDATE charging_sessions SET
                            lifecycle_state = CASE WHEN ended_at IS NULL THEN 'active' ELSE 'completed' END,
                            completion_reason = CASE WHEN ended_at IS NULL THEN NULL ELSE 'legacy' END,
                            energy_source = 'legacy_estimate', confidence = 'low', summary_version = 1,
                            last_observed_at = COALESCE(ended_at, started_at);
                        CREATE INDEX IF NOT EXISTS idx_charging_sessions_active
                            ON charging_sessions(vin, lifecycle_state, ended_at);
                        PRAGMA user_version = 2;
                        """)
                    version = 2
                } catch {
                    logger.error("Charging-session data migration failed; it will retry next launch: \(error, privacy: .public)")
                }
            } else {
                logger.error("Charging-session schema migration remains incomplete; it will retry next launch")
            }
        }

        // v3: durable business/private classification for locally-derived trips.
        if version == 2 {
            do {
                try db.execute(sql: """
                    CREATE TABLE IF NOT EXISTS trip_tags (
                        trip_id TEXT NOT NULL,
                        vin TEXT NOT NULL,
                        purpose TEXT NOT NULL,
                        updated_at REAL NOT NULL,
                        PRIMARY KEY (trip_id, vin)
                    );
                    CREATE INDEX IF NOT EXISTS idx_trip_tags_vin
                        ON trip_tags(vin, updated_at DESC);
                    PRAGMA user_version = 3;
                    """)
                version = 3
            } catch {
                logger.error("Trip-classification schema migration remains incomplete: \(error, privacy: .public)")
            }
        }
        if version == 3 {
            do {
                try db.withTransaction {
                    try db.execute(sql: """
                        CREATE TABLE IF NOT EXISTS vehicle_activity (
                            id TEXT PRIMARY KEY, vin TEXT NOT NULL,
                            timestamp REAL NOT NULL, payload BLOB NOT NULL
                        );
                        CREATE INDEX IF NOT EXISTS idx_vehicle_activity_vin
                            ON vehicle_activity(vin, timestamp DESC);
                        PRAGMA user_version = 4;
                        """)
                }
                version = 4
            } catch {
                logger.error("Vehicle activity migration remains incomplete: \(error, privacy: .public)")
            }
        }

        // v5: market-price charging cost per session, backfilled from recorded samples.
        if version == 4 {
            do {
                // A previous launch may have applied the ALTER but failed before the version
                // bump; guard the ALTER so the retry completes instead of erroring forever.
                if !columnExists(table: "charging_sessions", column: "spot_estimated_cost") {
                    try db.execute(sql: "ALTER TABLE charging_sessions ADD COLUMN spot_estimated_cost REAL;")
                }
                try db.execute(sql: "PRAGMA user_version = 5;")
                version = 5
            } catch {
                logger.error("Spot-cost schema migration remains incomplete: \(error, privacy: .public)")
            }
        }

        // v6: tyre-pressure history and the warning timeline. The same DDL sits in the baseline
        // above for fresh installs; `VehicleDatabaseSchemaParityTests` keeps the two in step.
        if version == 5 {
            do {
                try db.withTransaction {
                    try db.execute(sql: """
                        CREATE TABLE IF NOT EXISTS tyre_pressure_history (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            vin TEXT NOT NULL,
                            timestamp REAL NOT NULL,
                            position TEXT NOT NULL,
                            kilopascals REAL NOT NULL,
                            reference_kpa REAL
                        );
                        CREATE INDEX IF NOT EXISTS idx_tyre_pressure_vin ON tyre_pressure_history(vin, position, timestamp DESC);
                        CREATE TABLE IF NOT EXISTS vehicle_warning_events (
                            id INTEGER PRIMARY KEY AUTOINCREMENT,
                            vin TEXT NOT NULL,
                            warning TEXT NOT NULL,
                            first_seen REAL NOT NULL,
                            cleared_at REAL
                        );
                        CREATE INDEX IF NOT EXISTS idx_warning_events_vin ON vehicle_warning_events(vin, first_seen DESC);
                        CREATE INDEX IF NOT EXISTS idx_warning_events_open ON vehicle_warning_events(vin, warning) WHERE cleared_at IS NULL;
                        PRAGMA user_version = 6;
                        """)
                }
                version = 6
            } catch {
                logger.error("Tyre-pressure and warning-event migration remains incomplete: \(error, privacy: .public)")
            }
        }
    }
}
