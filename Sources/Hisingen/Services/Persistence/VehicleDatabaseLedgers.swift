import Foundation
import OSLog

// Storage ledgers extracted from `VehicleDatabase`. Each owns one family's SQL so the
// repository's own interface stays lifecycle-shaped: schema, migrations, wipe, prune,
// backup, counts. They share the database's SQLite handle and its recursive lock; like the
// repository, they are `@unchecked Sendable` and their methods run on many threads, so
// coders are created per operation rather than shared.

/// Owns the `vehicle_snapshots` table: the persisted last-known state per VIN.
final class VehicleSnapshotLedger: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    func saveSnapshot(_ state: VehicleState) {
        let data: Data
        do {
            data = try JSONEncoder().encode(state.cacheableCopy)
        } catch {
            logger.error("Could not encode vehicle snapshot for persistence: \(error, privacy: .public)")
            return
        }
        let brandName = state.isVolvo ? "volvo" : "polestar"
        let sql = """
        INSERT INTO vehicle_snapshots (vin, brand, model_name, fetched_at, vehicle_reported_at, is_cached_snapshot, payload)
        VALUES (?, ?, ?, ?, ?, 1, ?)
        ON CONFLICT(vin) DO UPDATE SET
            brand=excluded.brand,
            model_name=excluded.model_name,
            fetched_at=excluded.fetched_at,
            vehicle_reported_at=excluded.vehicle_reported_at,
            is_cached_snapshot=1,
            payload=excluded.payload;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(state.identity.vin, at: 1)
            try stmt.bindText(brandName, at: 2)
            try stmt.bindText(state.identity.modelName, at: 3)
            try stmt.bindDate(state.freshness.fetchedAt, at: 4)
            try stmt.bindDate(state.freshness.vehicleReportedAt, at: 5)
            try stmt.bindBlob(data, at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func loadSnapshot(for vin: String) -> VehicleState? {
        let sql = "SELECT payload, fetched_at FROM vehicle_snapshots WHERE vin = ? LIMIT 1;"
        // `query` runs `process` while holding the database's recursive lock; nothing in the
        // closure may call back into the repository. Record that the row expired and delete
        // it after the query returns, once the lock is released.
        var snapshotExpired = false
        let state = try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> VehicleState? in
            guard stmt.step(), let blob = stmt.columnBlob(at: 0) else { return nil }
            guard var state = try? JSONDecoder().decode(VehicleState.self, from: blob) else { return nil }
            if let fetchedAt = stmt.columnDate(at: 1) {
                // Drop expired snapshots older than 7 days
                if Date().timeIntervalSince(fetchedAt) > 7 * 24 * 60 * 60 {
                    snapshotExpired = true
                    return nil
                }
            }
            state.freshness.isCached = true
            return state
        }
        if snapshotExpired {
            deleteSnapshot(for: vin)
            return nil
        }
        return state
    }

    func deleteSnapshot(for vin: String) {
        let sql = "DELETE FROM vehicle_snapshots WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    /// Drops every cached snapshot without touching durable history. Used by the sign-out
    /// path when the user has chosen to keep local history: the snapshot holds live-ish
    /// fields (location, owner name) that should not linger after sign-out, but charging
    /// sessions, telemetry and the rest are kept.
    func deleteAllSnapshots() {
        try? db.execute(sql: "DELETE FROM vehicle_snapshots;")
    }
}


/// Owns the `charging_baselines` table: one per-VIN charging baseline, replaced in place.
final class ChargingBaselineLedger: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    /// One vehicle's baseline, replaced in place. The plist this replaced re-encoded every
    /// vehicle's baseline on every save; the row is also why the erase regimes can name it.
    func saveBaseline(_ baseline: ChargingBaseline) {
        let payload: Data
        do {
            payload = try JSONEncoder().encode(baseline)
        } catch {
            logger.error("Could not encode charging baseline for persistence: \(error, privacy: .public)")
            return
        }
        let sql = """
        INSERT INTO charging_baselines (vin, sampled_at, vehicle_reported_at, payload)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(vin) DO UPDATE SET
            sampled_at=excluded.sampled_at,
            vehicle_reported_at=excluded.vehicle_reported_at,
            payload=excluded.payload;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(baseline.vin, at: 1)
            try stmt.bindDate(baseline.sampledAt, at: 2)
            try stmt.bindDate(baseline.vehicleReportedAt, at: 3)
            try stmt.bindBlob(payload, at: 4)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func loadBaseline(for vin: String) -> ChargingBaseline? {
        let sql = "SELECT payload FROM charging_baselines WHERE vin = ? LIMIT 1;"
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> ChargingBaseline? in
            guard stmt.step(), let blob = stmt.columnBlob(at: 0) else { return nil }
            return try? JSONDecoder().decode(ChargingBaseline.self, from: blob)
        }
    }

    func deleteBaseline(for vin: String) {
        let sql = "DELETE FROM charging_baselines WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func deleteAllBaselines() {
        try? db.execute(sql: "DELETE FROM charging_baselines;")
    }

    /// The 7-day lifetime is a property of the baseline, not of the reader that noticed it.
    func deleteBaselines(olderThan cutoff: Date) {
        let sql = "DELETE FROM charging_baselines WHERE COALESCE(sampled_at, vehicle_reported_at, 0) < ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindDate(cutoff, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }
}


/// Owns the `vehicle_images` table: rendered car artwork and thumbnails per VIN/angle.
final class VehicleImageLedger: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    func saveVehicleImage(
        vin: String, angle: Int, data: Data,
        thumbnailData: Data? = nil, pixelBudget: Int? = nil
    ) -> Bool {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty, !data.isEmpty else { return false }
        let sql = """
        INSERT INTO vehicle_images (vin, angle, image_data, thumbnail_data, pixel_budget, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(vin, angle) DO UPDATE SET
            image_data=excluded.image_data,
            thumbnail_data=excluded.thumbnail_data,
            pixel_budget=excluded.pixel_budget,
            updated_at=excluded.updated_at;
        """
        let saved: Void? = try? db.query(sql: sql) { stmt in
            try stmt.bindText(cleanVIN, at: 1)
            try stmt.bindInt64(Int64(angle), at: 2)
            try stmt.bindBlob(data, at: 3)
            try stmt.bindBlob(thumbnailData, at: 4)
            try stmt.bindInt64(pixelBudget.map(Int64.init), at: 5)
            try stmt.bindDate(Date(), at: 6)
            try stmt.executeUpdate()
        } process: { _ in }
        return saved != nil
    }

    func loadVehicleImage(for vin: String, angle: Int) -> (data: Data, thumbnailData: Data?)? {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return nil }
        let sql = "SELECT image_data, thumbnail_data FROM vehicle_images WHERE vin = ? AND angle = ? LIMIT 1;"
        return try? db.readQuery(sql: sql) { stmt in
            try stmt.bindText(cleanVIN, at: 1)
            try stmt.bindInt64(Int64(angle), at: 2)
        } process: { stmt -> (data: Data, thumbnailData: Data?)? in
            guard stmt.step(), let data = stmt.columnBlob(at: 0) else { return nil }
            let thumb = stmt.columnBlob(at: 1)
            return (data: data, thumbnailData: thumb)
        }
    }

    func hasVehicleImage(for vin: String, angle: Int) -> Bool {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !cleanVIN.isEmpty else { return false }
        return (try? db.readQuery(
            sql: "SELECT 1 FROM vehicle_images WHERE vin = ? AND angle = ? LIMIT 1;",
            bindings: { stmt in
                try stmt.bindText(cleanVIN, at: 1)
                try stmt.bindInt64(Int64(angle), at: 2)
            },
            process: { $0.step() }
        )) ?? false
    }
}


/// Owns the `command_receipts` table: the durable copy of the receipt ledger per VIN.
final class CommandReceiptStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    /// One vehicle's visible receipts. Durable rather than mirrored: the plist rewrite this
    /// replaces re-encoded every vehicle's receipts on every command, and a receipt that
    /// outlived a sign-out could reappear in the Controls tab.
    func saveCommandReceipts(_ receipts: StoredCommandReceipts, for vin: String) {
        guard !receipts.records.isEmpty else {
            deleteCommandReceipts(for: vin)
            return
        }
        let payload: Data
        do {
            payload = try JSONEncoder().encode(receipts)
        } catch {
            logger.error("Could not encode command receipts for persistence: \(error, privacy: .public)")
            return
        }
        let sql = """
        INSERT INTO command_receipts (vin, payload)
        VALUES (?, ?)
        ON CONFLICT(vin) DO UPDATE SET payload=excluded.payload;
        """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindBlob(payload, at: 2)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func loadCommandReceipts(for vin: String) -> StoredCommandReceipts? {
        let sql = "SELECT payload FROM command_receipts WHERE vin = ? LIMIT 1;"
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> StoredCommandReceipts? in
            guard stmt.step(), let blob = stmt.columnBlob(at: 0) else { return nil }
            return try? JSONDecoder().decode(StoredCommandReceipts.self, from: blob)
        }
    }

    func deleteCommandReceipts(for vin: String) {
        let sql = "DELETE FROM command_receipts WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func deleteAllCommandReceipts() {
        try? db.execute(sql: "DELETE FROM command_receipts;")
    }
}


/// Owns the `provider_backoff` table: durable provider stand-downs shared with
/// `ProviderBackoffStore`.
final class ProviderBackoffLedger: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    /// Reads one stand-down. Returns the instant it blocks until and the recorded reason.
    func providerBackoff(for subject: String) -> (blockedUntil: Date, reason: String?)? {
        let query = "SELECT blocked_until, reason FROM provider_backoff WHERE subject = ? LIMIT 1;"
        return try? db.query(sql: query) { stmt in
            try stmt.bindText(subject, at: 1)
        } process: { stmt -> (blockedUntil: Date, reason: String?)? in
            guard stmt.step(), let epoch = stmt.columnDouble(at: 0) else { return nil }
            return (Date(timeIntervalSince1970: epoch), stmt.columnText(at: 1))
        }
    }

    func deleteProviderBackoff(subject: String) {
        let query = "DELETE FROM provider_backoff WHERE subject = ?;"
        try? db.query(sql: query) { stmt in
            try stmt.bindText(subject, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    /// The stand-downs that name a vehicle, dropped by a fleet-wide sign-out. The provider-wide
    /// ones stay: a client-version rejection is not something a sign-out answers.
    func deleteVehicleScopedProviderBackoffs() {
        try? db.execute(sql: "DELETE FROM provider_backoff WHERE vin IS NOT NULL;")
    }

    /// Drops stand-downs whose window has closed. Reading one already answers nil, so keeping the
    /// row only grows the file.
    func deleteExpiredProviderBackoffs(now: Date) {
        let sql = "DELETE FROM provider_backoff WHERE blocked_until <= ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindDate(now, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func saveProviderBackoff(subject: String, vin: String?, blockedUntil: Date, reason: String?) {
        let sql = """
            INSERT INTO provider_backoff (subject, vin, blocked_until, reason)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(subject) DO UPDATE SET
                vin = excluded.vin,
                blocked_until = excluded.blocked_until,
                reason = excluded.reason;
            """
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(subject, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDouble(blockedUntil.timeIntervalSince1970, at: 3)
            try stmt.bindText(reason, at: 4)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func deleteProviderBackoffs(for vin: String) {
        let sql = "DELETE FROM provider_backoff WHERE vin = ?;"
        try? db.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }
}
