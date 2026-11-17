import Foundation
import OSLog

struct StoredCommandReceipt: Codable, Equatable, Sendable {
    var receipt: CommandReceipt
    var confirmationDeadline: Date?
}

struct StoredCommandReceipts: Codable, Equatable, Sendable {
    var records: [StoredCommandReceipt]
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
    /// Where releases up to 2.0.1 kept their caches. Nothing writes these any more, and a copy
    /// is never carried forward: every one of them is past the seven-day retention below, so
    /// `activate()` only deletes the keys. A payload that held a location, an owner name or a
    /// registration must not sit in `UserDefaults` once nothing can read it.
    private let legacySnapshotsKey = "cached_vehicle_snapshots_v1"
    private let legacyBaselinesKey = "charging_baselines_v1"
    private let legacyCommandReceiptsKey = "command_receipts_v1"
    private let logger = AppLog.logger("state-store")

    let database: VehicleDatabase
    private let preferences: PreferencesStore
    private let historyRecorder: VehicleHistoryRecorder
    /// Owns the cross-mechanism maintenance sequences. This store supplies the pieces; the
    /// ordering lives in one place instead of once per caller.
    private let eraser: LocalDataEraser

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
        discardLegacyMirrors()
        let now = Date()
        database.baselines.deleteBaselines(olderThan: now.addingTimeInterval(-VehicleDatabase.cacheRetention))
        // Stand-downs are the database's other expiring tier: a closed window answers nil on read,
        // so the launch pass is where the row goes away instead of accumulating in the file.
        database.providerBackoffs.deleteExpiredProviderBackoffs(now: now)
        reconcileLegacyChargingSummaries()
    }

    /// The authoritative snapshot read: SQLite, or nothing. It never migrates, never erases a
    /// vehicle's other tiers and never writes the plist; an expired row is dropped by the
    /// database's own expiry rule, which is the database's business rather than this read's.
    func snapshot(for vin: String) -> VehicleState? {
        database.snapshots.loadSnapshot(for: vin)
    }

    /// Deletes the plist caches older releases wrote. Nothing is decoded, so a payload this build
    /// can no longer read is removed too instead of staying behind with its location, owner name
    /// and registration.
    private func discardLegacyMirrors() {
        for key in [legacySnapshotsKey, legacyBaselinesKey, legacyCommandReceiptsKey] {
            defaults.removeObject(forKey: key)
        }
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
        historyRecorder.save(state)

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
        guard let baseline = database.baselines.loadBaseline(for: vin) else { return nil }
        guard let timestamp = baseline.sampledAt ?? baseline.vehicleReportedAt,
              Date().timeIntervalSince(timestamp) <= VehicleDatabase.cacheRetention else { return nil }
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
        database.baselines.saveBaseline(baseline)
    }

    func commandReceipts(for vin: String) -> [StoredCommandReceipt] {
        database.commandReceipts.loadCommandReceipts(for: vin)?.records ?? []
    }

    func saveCommandReceipts(_ records: [StoredCommandReceipt], for vin: String) {
        database.commandReceipts.saveCommandReceipts(StoredCommandReceipts(records: records), for: vin)
    }

    func clearCommandReceipts(for vin: String) {
        database.commandReceipts.deleteCommandReceipts(for: vin)
    }

    /// Forgets a vehicle's cached snapshot and charging baseline. Durable SQLite history
    /// (charging sessions, telemetry, battery health, fuel entries…) is kept unless
    /// `eraseHistory` is set: the sign-out path passes the user's Settings → Privacy & Data
    /// choice, while the deliberate "Erase local vehicle data" action wipes directly.
    ///
    /// The image tier, the `UserDefaults` mirrors, the in-memory per-VIN caches and the
    /// ordering between them belong to `LocalDataEraser`; this only chooses the scope.
    @discardableResult
    func clear(vin: String, eraseHistory: Bool = false) -> Bool {
        historyRecorder.resetTransientState(vin: vin)
        do {
            try eraser.perform(eraseHistory ? .everything(.vehicle(vin)) : .session(.vehicle(vin)))
            return true
        } catch {
            logger.error("Could not erase local data for vehicle: \(error, privacy: .public)")
            return false
        }
    }

    /// The fleet-wide counterpart, for a sign-out that no longer knows any vehicle. Its own
    /// member because a caller holding one vehicle must not be able to erase the rest by
    /// leaving the VIN out, and its `eraseHistory` choice also picks the breadth of the
    /// `UserDefaults` erase: a plain sign-out keeps the stores the reader authored, the
    /// deliberate action takes them with the vehicle.
    @discardableResult
    func clearAll(eraseHistory: Bool = false) -> Bool {
        historyRecorder.resetTransientState()
        do {
            try eraser.perform(eraseHistory ? .everything(.all) : .session(.all))
            return true
        } catch {
            logger.error("Could not erase local data on sign-out: \(error, privacy: .public)")
            return false
        }
    }
}
