import Foundation

/// What a destructive action is aimed at. The fleet-wide case is a case of its own rather
/// than the meaning of an omitted argument: `nil` and `""` used to widen a per-vehicle erase
/// to every vehicle, and the storage tiers disagreed about which of them meant it.
enum VehicleScope: Equatable {
    case vehicle(String)
    case all

    /// Whether state filed under `vin` belongs to this target. Matching is normalized because
    /// every writer normalizes before storing while a caller's VIN may not be; an empty VIN
    /// matches nothing rather than everything.
    func covers(_ vin: String) -> Bool {
        switch self {
        case .all:
            return true
        case .vehicle(let target):
            let provided = vin.normalizedVIN
            guard !provided.isEmpty else { return false }
            return provided == target.normalizedVIN
        }
    }
}

/// Owns every maintenance sequence that spans more than one storage mechanism.
///
/// The individual `DELETE` and `PRAGMA` statements stay on `VehicleDatabase`; what lives here is
/// the order they run in and the tiers SQL cannot reach – the `UserDefaults` mirrors, the image
/// cache, the in-memory per-VIN caches, and the preference flags that describe what is still on
/// disk. Callers used to reassemble that sequence themselves, in two different orders, from two
/// different files.
@MainActor
final class LocalDataEraser {
    /// The maintenance cases, `samples` and `compact`, are inherently fleet-wide: sample pruning
    /// and SQLite's `PRAGMA` have no per-vehicle form, so they carry no `VehicleScope` and never
    /// touch a per-VIN tier.
    enum Scope: Equatable {
        /// What an account sign-out or an account change drops: the cached snapshot, the
        /// mirrors, the command receipts, the in-memory image tier and the in-memory per-VIN
        /// caches. Durable history survives.
        ///
        /// The fleet-wide form is the narrower case of the two: knowing no vehicle, a sign-out
        /// takes only the stores the vehicles reported, so a name or a colour the reader chose
        /// for a vehicle of an untouched brand is not a session casualty.
        case session(VehicleScope)
        /// One vehicle signed out of an account that stays connected. The vehicle-derived
        /// stores go, so no stale snapshot, receipt, baseline or planner latch survives; the
        /// reader-authored nickname, theme, mute and related stores stay for Bring Back, and
        /// so does the artwork the garage will draw again.
        case detach(VehicleScope)
        /// Coordinates and charging-location labels only.
        case locations(VehicleScope)
        /// High-volume samples older than the retention window.
        case samples(olderThanDays: Int)
        /// Reclaim space without deleting rows.
        case compact
        /// Everything, for the scope's VIN or the whole database.
        case everything(VehicleScope)
    }

    private let database: VehicleDatabase
    private let preferences: PreferencesStore
    private let imageCache: CarImageCache
    private let memoryCaches: VehicleMemoryCacheRegistry
    private let beforeSQL: (@Sendable () -> Void)?
    /// Removes the desktop widget's App Group mirror. Injectable so a test can assert the erase
    /// reaches it without touching the real container.
    private let clearWidgetSnapshot: @Sendable () -> Void

    init(database: VehicleDatabase, preferences: PreferencesStore, imageCache: CarImageCache,
         memoryCaches: VehicleMemoryCacheRegistry = .shared, beforeSQL: (@Sendable () -> Void)? = nil,
         clearWidgetSnapshot: @escaping @Sendable () -> Void = { WidgetSnapshotWriter.remove() }) {
        self.database = database
        self.preferences = preferences
        self.imageCache = imageCache
        self.memoryCaches = memoryCaches
        self.beforeSQL = beforeSQL
        self.clearWidgetSnapshot = clearWidgetSnapshot
    }

    /// The complete sequence on the calling actor. The session teardown path uses this: it must
    /// finish before the provider sign-out that follows it.
    func perform(_ scope: Scope) throws {
        let lease = database.beginHistoryErase(scope: scope)
        defer { database.endHistoryErase(lease) }
        beforeSQL?()
        try database.eraseWithHistoryBarrier { try Self.runSQL(scope, database: database) }
        applyLocalTiers(scope)
    }

    /// The same sequence with the SQL half on a utility task. The Settings actions use this
    /// because `compact` and `everything` rewrite the whole file.
    func performInBackground(_ scope: Scope) async throws {
        let lease = database.beginHistoryErase(scope: scope)
        defer { database.endHistoryErase(lease) }
        if case .locations = scope { preferences.persistLocationHistory = false }
        let database = database
        let beforeSQL = beforeSQL
        try await Task.detached(priority: .utility) {
            beforeSQL?()
            try database.eraseWithHistoryBarrier { try Self.runSQL(scope, database: database) }
        }.value
        applyLocalTiers(scope)
    }

    /// SQL only, so it can run on any thread. Ordered before `applyLocalTiers` everywhere: the
    /// mirrors must not be dropped before the delete they mirror has committed.
    private nonisolated static func runSQL(_ scope: Scope, database: VehicleDatabase) throws {
        switch scope {
        case .session(let vehicles), .detach(let vehicles):
            try database.db.withTransaction {
                let tables = ["vehicle_snapshots", "charging_baselines", "command_receipts", "provider_backoff"]
                for table in tables {
                    switch vehicles {
                    case .vehicle(let vin):
                        try database.db.query(sql: "DELETE FROM \(table) WHERE vin = ?;") { stmt in
                            try stmt.bindText(vin, at: 1)
                            try stmt.executeUpdate()
                        } process: { _ in }
                    case .all:
                        let predicate = table == "provider_backoff" ? " WHERE vin IS NOT NULL" : ""
                        try database.db.execute(sql: "DELETE FROM \(table)\(predicate);")
                    }
                }
            }
        case .locations(.vehicle(let vin)):
            try database.clearStoredLocationsOrThrow(for: vin)
        case .locations(.all):
            try database.clearAllStoredLocationsOrThrow()
        case .samples(let olderThanDays):
            try database.pruneHistoricalSamplesOrThrow(olderThanDays: olderThanDays)
        case .compact:
            try database.vacuumOrThrow()
        case .everything(.vehicle(let vin)):
            try database.wipeVehicleOrThrow(for: vin)
        case .everything(.all):
            try database.wipeFleetOrThrow()
        }
    }

    private func applyLocalTiers(_ scope: Scope) {
        // The widget mirrors the active car from an App Group file the database never touches.
        // A wipe that covers that car, or the whole fleet, has to take it too: otherwise
        // "erase local data" leaves the VIN, nickname, charge level and next departure readable
        // in the container. A sign-out already clears it on its own path; this covers the
        // Settings wipe, which never signs out.
        switch scope {
        case .session(let vehicles), .detach(let vehicles), .everything(let vehicles):
            if vehicles.covers(preferences.vin) { clearWidgetSnapshot() }
        case .locations, .samples, .compact:
            break
        }
        // Both full erases below move the mirror with the row it mirrors: an old snapshot or
        // command receipt reappears after relaunch if the mirror is left behind, and the
        // in-memory tiers have to move with the mirror or the erased snapshot keeps answering
        // from RAM.
        switch scope {
        case .session(let vehicles):
            clearSessionDefaults(vehicles)
            memoryCaches.drop(vehicles)
            dropImageTier(vehicles)
        case .detach(let vehicles):
            clearVehicleDerivedDefaults(vehicles)
            memoryCaches.drop(vehicles)
        case .everything(let vehicles):
            clearLocalDefaults(vehicles)
            memoryCaches.drop(vehicles)
            dropImageTier(vehicles)
            eraseHomeCharging(vehicles)
        case .locations(let vehicles):
            // Turning the preference off is what keeps the cleared coordinates cleared. The
            // snapshot mirror goes with them: it still carries the coordinates that were just
            // deleted from every durable tier, while a baseline, a receipt, a notification latch
            // and a name the reader chose were never locations and stay.
            preferences.persistLocationHistory = false
            clearSnapshotMirror(vehicles)
            memoryCaches.dropSnapshots(vehicles)
        case .samples, .compact:
            break
        }
    }

    /// The `UserDefaults` half of a session teardown. A known vehicle loses all twelve stores,
    /// reader-authored ones included: that vehicle's session genuinely ended and it is the vehicle
    /// the reader acted on. A fleet-wide sign-out knows no such vehicle, so it takes only what the
    /// vehicles reported – a name or a colour is the reader's, not the vehicle's.
    private func clearSessionDefaults(_ vehicles: VehicleScope) {
        switch vehicles {
        case .vehicle(let vin):
            preferences.clearLocalVehicleDefaults(for: vin)
        case .all:
            preferences.clearAllVehicleDerivedDefaults()
        }
    }

    /// The vehicle-derived half for a vehicle that stays on its account. The reader-authored
    /// stores stay: Bring Back should return the name and colour the reader gave the car.
    private func clearVehicleDerivedDefaults(_ vehicles: VehicleScope) {
        switch vehicles {
        case .vehicle(let vin):
            preferences.clearVehicleDerivedDefaults(for: vin)
        case .all:
            preferences.clearAllVehicleDerivedDefaults()
        }
    }

    /// The `UserDefaults` half of the reader-chosen wipe: every store for its scope, the
    /// reader-authored ones included, because a name or a colour that outlives its vehicle is the
    /// half-erase that action rules out.
    private func clearLocalDefaults(_ vehicles: VehicleScope) {
        switch vehicles {
        case .vehicle(let vin):
            preferences.clearLocalVehicleDefaults(for: vin)
        case .all:
            preferences.clearAllLocalVehicleDefaults()
        }
    }

    /// The one store a location erase invalidates. The scope names it rather than inheriting the
    /// table with two exclusions, so nothing the table later grows can be taken by a location
    /// change that cannot invalidate it.
    private func clearSnapshotMirror(_ vehicles: VehicleScope) {
        switch vehicles {
        case .vehicle(let vin):
            preferences.clearSnapshotMirror(for: vin)
        case .all:
            preferences.clearAllSnapshotMirrors()
        }
    }

    /// The Home Assistant pairing is the reader's, tied to one vehicle. Erasing that vehicle removes
    /// the pairing; erasing everything also removes the access token from the Keychain. A sign-out
    /// touches neither: Home Assistant is a separate account. The running model is told to let go.
    private func eraseHomeCharging(_ vehicles: VehicleScope) {
        let store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        switch vehicles {
        case .all:
            store.eraseAll()
        case .vehicle:
            guard let pairing = store.pairing, vehicles.covers(pairing.vin) else { return }
            store.clearPairing()
        }
        NotificationCenter.default.post(name: .homeChargingDataErased, object: nil)
    }

    private func dropImageTier(_ vehicles: VehicleScope) {
        switch vehicles {
        case .vehicle(let vin):
            imageCache.forget(vin: vin)
        case .all:
            imageCache.forgetAll()
        }
    }
}
