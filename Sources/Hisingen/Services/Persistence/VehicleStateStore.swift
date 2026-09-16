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

/// The per-vehicle cache in front of SQLite: the cached snapshot, the charging baseline and the
/// visible command receipts, one row per VIN each.
///
/// Main-actor isolated because its callers are (`RefreshCoordinator`, `Notifier`, the launch
/// path) and because `activate()` resolves MainActor-backed preference lookups; the storage it
/// hands its rows to is `VehicleDatabase`, which serializes its own access.
@MainActor
final class VehicleStateStore {
    private let defaults: UserDefaults
    /// Where older releases kept their caches. Nothing writes these any more: `activate()` reads
    /// each once, moves what it finds into SQLite, and deletes the key so no stale payload can be
    /// read back by a later launch.
    private let legacySnapshotsKey = "cached_vehicle_snapshots_v1"
    private let legacyBaselinesKey = "charging_baselines_v1"
    private let legacyCommandReceiptsKey = "command_receipts_v1"
    private let decoder = JSONDecoder()
    private let logger = AppLog.logger("state-store")

    let database: VehicleDatabase
    private let preferences: PreferencesStore
    private let historyRecorder: VehicleHistoryRecorder
    /// Owns the cross-mechanism maintenance sequences. This store supplies the pieces; the
    /// ordering lives in one place instead of once per caller.
    private let eraser: LocalDataEraser

    /// How long a cached snapshot or charging baseline may answer. Named once because the legacy
    /// migration, the pruning pass and the reads all have to agree on it.
    private static let cacheRetention: TimeInterval = 7 * 24 * 60 * 60

    init(defaults: UserDefaults = .standard, database: VehicleDatabase,
         preferences: PreferencesStore? = nil, imageCache: CarImageCache = .shared) {
        self.defaults = defaults
        self.database = database
        let preferences = preferences ?? PreferencesStore(defaults: defaults)
        self.preferences = preferences
        self.historyRecorder = VehicleHistoryRecorder(database: database, preferences: preferences)
        self.eraser = LocalDataEraser(
            database: database, preferences: preferences, imageCache: imageCache)
        // Construction is deliberately side-effect-free. The legacy-summary repair that used to run
        // here was an N+1 over the charging table, repeated by every store instance the process
        // built – including the Shortcuts entry point's second one. `activate()` is where the
        // launch path asks for it, once.
    }

    /// The launch-time maintenance the store's owner runs once this store exists.
    ///
    /// Both halves used to run somewhere they did not belong: the migrations and expiry pruning
    /// inside `snapshot(for:)` and `baseline(for:)`, which made a read a writer that could erase a
    /// vehicle's tiers, and the legacy-summary repair inside `init`, which made construction
    /// side-effecting and ran it per instance. Reads are pure now, and this is idempotent: a
    /// relaunch with nothing to move costs one dictionary read.
    func activate() {
        migrateLegacySnapshots()
        migrateLegacyBaselines()
        migrateLegacyCommandReceipts()
        let now = Date()
        database.deleteBaselines(olderThan: now.addingTimeInterval(-Self.cacheRetention))
        // Stand-downs are the database's other expiring tier: a closed window answers nil on read,
        // so the launch pass is where the row goes away instead of accumulating in the file.
        database.deleteExpiredProviderBackoffs(now: now)
        reconcileLegacyChargingSummaries()
    }

    /// The authoritative snapshot read: SQLite, or nothing. It never migrates, never erases a
    /// vehicle's other tiers and never writes the plist; an expired row is dropped by the
    /// database's own expiry rule, which is the database's business rather than this read's.
    func snapshot(for vin: String) -> VehicleState? {
        database.loadSnapshot(for: vin)
    }

    /// Moves legacy plist snapshots into SQLite, which is authoritative, and drops the expired
    /// ones on the way. Older releases stored complete snapshots in `UserDefaults`. That
    /// representation must never carry sensitive live fields (location, owner name, registration)
    /// forward, so the sanitized copy is what lands in SQLite – a schema migration and a privacy
    /// seam for caches written by older versions of the app.
    private func migrateLegacySnapshots() {
        guard let legacy = load([String: VehicleState].self, key: legacySnapshotsKey) else { return }
        let now = Date()
        for (_, snapshot) in legacy where
            now.timeIntervalSince(snapshot.freshness.fetchedAt) <= Self.cacheRetention {
            database.saveSnapshot(snapshot.cacheableCopy)
        }
        defaults.removeObject(forKey: legacySnapshotsKey)
    }

    /// The baseline and receipt halves of the same move: one pass over each legacy key, the rows
    /// that land in SQLite, then the key is gone. Expired baselines are dropped rather than moved,
    /// because the retention rule says they must not answer again.
    private func migrateLegacyBaselines() {
        guard let legacy = load([String: ChargingBaseline].self, key: legacyBaselinesKey) else { return }
        let now = Date()
        for (_, baseline) in legacy {
            guard let timestamp = baseline.sampledAt ?? baseline.vehicleReportedAt,
                  now.timeIntervalSince(timestamp) <= Self.cacheRetention else { continue }
            database.saveBaseline(baseline)
        }
        defaults.removeObject(forKey: legacyBaselinesKey)
    }

    /// The receipt decoding is deliberately tolerant: older releases wrote one receipt where later
    /// ones wrote a list, and `StoredCommandReceipts` reads both shapes, so an install that skipped
    /// a version still comes forward.
    private func migrateLegacyCommandReceipts() {
        guard let legacy = load([String: StoredCommandReceipts].self, key: legacyCommandReceiptsKey)
        else { return }
        for (vin, receipts) in legacy {
            database.saveCommandReceipts(receipts, for: vin)
        }
        defaults.removeObject(forKey: legacyCommandReceiptsKey)
    }


    /// Persist one fresh observation.
    ///
    /// When this returns, `snapshot(for:)` reads back what was just saved: the authoritative
    /// row is written before the return. The derived history passes (air quality, telemetry,
    /// connectivity, cabin climate, charging ledger, battery health) are coalesced per VIN on
    /// a utility queue instead, because they are append-and-forget — nothing reads them back
    /// through this interface. Call `drainHistory()` before reading them.
    ///
    /// The inline half is one JSON encode and one upsert. It used to be queued with the rest,
    /// which made `save` then `snapshot(for:)` not a round trip: every read-after-write had to
    /// poll for up to five seconds instead of trusting the interface.
    func save(_ state: VehicleState) {
        historyRecorder.saveAuthoritative(state)
        historyRecorder.record(state)

        // SQLite is the authoritative snapshot store (`database.saveSnapshot` above). The
        // UserDefaults mirror is no longer written: it previously re-encoded the entire
        // per-VIN dictionary on every save – an O(all-vehicles) plist rewrite per refresh –
        // and was only ever a legacy fallback for installs predating SQLite.
    }

    /// Wait until every queued history pass for every vehicle has landed. Only callers that
    /// read the derived history tiers need this; the authoritative snapshot never does.
    func drainHistory() async { await historyRecorder.drain() }

    /// The baseline for `vin`, or nothing when it has aged out. The read stays pure: expiry is
    /// checked while answering, and the rows are swept by `activate()`.
    func baseline(for vin: String) -> ChargingBaseline? {
        guard let baseline = database.loadBaseline(for: vin) else { return nil }
        guard let timestamp = baseline.sampledAt ?? baseline.vehicleReportedAt,
              Date().timeIntervalSince(timestamp) <= Self.cacheRetention else { return nil }
        return baseline
    }

    /// The legacy-summary repair: rows keep the usable capacity they were written with, and the
    /// current preference override is the fallback for rows that never stored one. The
    /// MainActor-backed preference lookups resolve here; the repair itself is an N+1 over
    /// potentially hundreds of queries per VIN, so it runs off the launch thread once every
    /// caller's values have been handed over.
    private func reconcileLegacyChargingSummaries() {
        guard preferences.storeChargingHistory else { return }
        let capacities = Dictionary(uniqueKeysWithValues: database.charging.legacySummaryVINs().map { vin in
            (vin, preferences.vehicleSpecificationOverride(for: vin)?.usableBatteryCapacityKwh)
        })
        guard !capacities.isEmpty else { return }
        let database = database
        Task.detached(priority: .utility) {
            for (vin, usableCapacityKwh) in capacities {
                database.charging.reconcileLegacySummaries(for: vin, usableCapacityKwh: usableCapacityKwh)
            }
        }
    }

    func save(_ baseline: ChargingBaseline) {
        database.saveBaseline(baseline)
    }

    func commandReceipts(for vin: String) -> [StoredCommandReceipt] {
        database.loadCommandReceipts(for: vin)?.records ?? []
    }

    func commandReceipt(for vin: String) -> StoredCommandReceipt? {
        commandReceipts(for: vin).last
    }

    func saveCommandReceipts(_ records: [StoredCommandReceipt], for vin: String) {
        database.saveCommandReceipts(StoredCommandReceipts(records: records), for: vin)
    }

    func saveCommandReceipt(_ record: StoredCommandReceipt, for vin: String) {
        saveCommandReceipts([record], for: vin)
    }

    func clearCommandReceipts(for vin: String) {
        database.deleteCommandReceipts(for: vin)
    }

    func clearCommandReceipt(for vin: String) {
        clearCommandReceipts(for: vin)
    }

    /// Forgets a vehicle's cached snapshot and charging baseline. Durable SQLite history
    /// (charging sessions, telemetry, battery health, fuel entries…) is kept unless
    /// `eraseHistory` is set: the sign-out path passes the user's Settings → Privacy & Data
    /// choice, while the deliberate "Erase local vehicle data" action wipes directly.
    ///
    /// The image tier, the `UserDefaults` mirrors, the in-memory per-VIN caches and the
    /// ordering between them belong to `LocalDataEraser`; this only chooses the scope.
    func clear(vin: String, eraseHistory: Bool = false) {
        historyRecorder.resetTransientState(vin: vin)
        try? eraser.perform(eraseHistory ? .everything(.vehicle(vin)) : .session(.vehicle(vin)))
    }

    /// The fleet-wide counterpart, for a sign-out that no longer knows any vehicle. Its own
    /// member because a caller holding one vehicle must not be able to erase the rest by
    /// leaving the VIN out, and its `eraseHistory` choice also picks the breadth of the
    /// `UserDefaults` erase: a plain sign-out keeps the stores the reader authored, the
    /// deliberate action takes them with the vehicle.
    func clearAll(eraseHistory: Bool = false) {
        historyRecorder.resetTransientState()
        try? eraser.perform(eraseHistory ? .everything(.all) : .session(.all))
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
}
