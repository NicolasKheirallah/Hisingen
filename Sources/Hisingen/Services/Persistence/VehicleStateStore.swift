import Foundation
import OSLog

struct StoredCommandReceipt: Codable, Equatable, Sendable {
    var receipt: CommandReceipt
    var confirmationDeadline: Date?
}

struct StoredCommandReceipts: Codable, Equatable, Sendable {
    var records: [StoredCommandReceipt]

    init(records: [StoredCommandReceipt]) {
        self.records = records
    }

    private enum CodingKeys: String, CodingKey {
        case records, receipt, confirmationDeadline
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let records = try values.decodeIfPresent([StoredCommandReceipt].self, forKey: .records) {
            self.records = records
        } else {
            self.records = [StoredCommandReceipt(
                receipt: try values.decode(CommandReceipt.self, forKey: .receipt),
                confirmationDeadline: try values.decodeIfPresent(Date.self, forKey: .confirmationDeadline)
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(records, forKey: .records)
    }
}

/// Main-actor isolated because it holds no lock of its own: every mutation is a
/// read-modify-write over a `UserDefaults`-backed dictionary, which two concurrent callers
/// would interleave and lose writes from. Both real callers (`RefreshCoordinator`, `Notifier`)
/// are already `@MainActor`; this makes the requirement compiler-enforced rather than assumed.
@MainActor
final class VehicleStateStore {
    private let defaults: UserDefaults
    private let snapshotsKey = "cached_vehicle_snapshots_v1"
    private let baselinesKey = "charging_baselines_v1"
    private let commandReceiptsKey = "command_receipts_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = AppLog.logger("state-store")

    let database: VehicleDatabase
    private let historyRecorder: VehicleHistoryRecorder

    init(defaults: UserDefaults = .standard, database: VehicleDatabase,
         preferences: PreferencesStore? = nil) {
        self.defaults = defaults
        self.database = database
        let preferences = preferences ?? PreferencesStore(defaults: defaults)
        self.historyRecorder = VehicleHistoryRecorder(database: database, preferences: preferences)

        // Legacy-summary reconciliation runs once per launch, not per snapshot: the repair
        // is idempotent, so re-filtering every stored session on every refresh only burned
        // time. Rows keep the usable capacity they were written with; the current preference
        // override is the fallback for rows that never stored one.
        if preferences.storeChargingHistory {
            for vin in database.charging.legacySummaryVINs() {
                database.charging.reconcileLegacySummaries(
                    for: vin,
                    usableCapacityKwh: preferences.vehicleSpecificationOverride(for: vin)?
                        .usableBatteryCapacityKwh)
            }
        }
    }

    func snapshot(for vin: String) -> VehicleState? {
        if let sqliteSnapshot = database.loadSnapshot(for: vin) {
            return sqliteSnapshot
        }
        guard let snapshot = load([String: VehicleState].self, key: snapshotsKey)?[vin] else { return nil }
        guard Date().timeIntervalSince(snapshot.freshness.fetchedAt) <= 7 * 24 * 60 * 60 else {
            clear(vin: vin)
            return nil
        }
        // Legacy installations stored complete snapshots in UserDefaults. Migrate the entry
        // once into SQLite, which is now authoritative, but never carry forward sensitive
        // live fields (location, owner name, registration) from that older representation.
        // This is both a schema migration and a privacy boundary for caches written by older
        // versions of the app.
        let sanitized = snapshot.cacheableCopy
        database.saveSnapshot(sanitized)
        var legacySnapshots = load([String: VehicleState].self, key: snapshotsKey) ?? [:]
        legacySnapshots.removeValue(forKey: vin)
        store(legacySnapshots, key: snapshotsKey)
        var migrated = sanitized
        migrated.freshness.isCached = true
        return migrated
    }

    func save(_ state: VehicleState) {
        historyRecorder.record(state)

        // SQLite is the authoritative snapshot store (`database.saveSnapshot` above). The
        // UserDefaults mirror is no longer written: it previously re-encoded the entire
        // per-VIN dictionary on every save — an O(all-vehicles) plist rewrite per refresh —
        // and was only ever a legacy fallback for installs predating SQLite.
    }

    func baseline(for vin: String) -> ChargingBaseline? {
        guard let baseline = load([String: ChargingBaseline].self, key: baselinesKey)?[vin] else { return nil }
        guard let timestamp = baseline.sampledAt ?? baseline.vehicleReportedAt,
              Date().timeIntervalSince(timestamp) <= 7 * 24 * 60 * 60 else {
            var values = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
            values.removeValue(forKey: vin)
            store(values, key: baselinesKey)
            return nil
        }
        return baseline
    }

    func save(_ baseline: ChargingBaseline) {
        var values = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
        values[baseline.vin] = baseline
        store(values, key: baselinesKey)
    }

    func commandReceipts(for vin: String) -> [StoredCommandReceipt] {
        load([String: StoredCommandReceipts].self, key: commandReceiptsKey)?[vin]?.records ?? []
    }

    func commandReceipt(for vin: String) -> StoredCommandReceipt? {
        commandReceipts(for: vin).last
    }

    func saveCommandReceipts(_ records: [StoredCommandReceipt], for vin: String) {
        var values = load([String: StoredCommandReceipts].self, key: commandReceiptsKey) ?? [:]
        values[vin] = StoredCommandReceipts(records: records)
        store(values, key: commandReceiptsKey)
    }

    func saveCommandReceipt(_ record: StoredCommandReceipt, for vin: String) {
        saveCommandReceipts([record], for: vin)
    }

    func clearCommandReceipts(for vin: String? = nil) {
        guard let vin else {
            defaults.removeObject(forKey: commandReceiptsKey)
            return
        }
        var values = load([String: StoredCommandReceipts].self, key: commandReceiptsKey) ?? [:]
        values.removeValue(forKey: vin)
        store(values, key: commandReceiptsKey)
    }

    func clearCommandReceipt(for vin: String? = nil) {
        clearCommandReceipts(for: vin)
    }

    /// Forgets a vehicle's cached snapshot and charging baseline. Durable SQLite history
    /// (charging sessions, telemetry, battery health, fuel entries…) is kept unless
    /// `eraseHistory` is set: the sign-out path passes the user's Settings → Privacy & Data
    /// choice, while the deliberate "Erase local vehicle data" action wipes directly.
    func clear(vin: String? = nil, eraseHistory: Bool = false) {
        historyRecorder.resetTransientState(vin: vin)
        if eraseHistory {
            database.wipeAll(for: vin)
        } else if let vin {
            database.deleteSnapshot(for: vin)
        } else {
            database.deleteAllSnapshots()
        }
        if let vin {
            var snapshots = load([String: VehicleState].self, key: snapshotsKey) ?? [:]
            var baselines = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
            snapshots.removeValue(forKey: vin)
            baselines.removeValue(forKey: vin)
            store(snapshots, key: snapshotsKey)
            store(baselines, key: baselinesKey)
            clearCommandReceipts(for: vin)
        } else {
            defaults.removeObject(forKey: snapshotsKey)
            defaults.removeObject(forKey: baselinesKey)
            clearCommandReceipts()
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("Could not decode persisted state for key \(key, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func store<T: Encodable>(_ value: T, key: String) {
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            logger.error("Could not encode persisted state for key \(key, privacy: .public): \(error, privacy: .public)")
        }
    }
}
