import Foundation

/// Owns every maintenance sequence that spans more than one storage mechanism.
///
/// The individual `DELETE` and `PRAGMA` statements stay on `VehicleDatabase`; what lives here is
/// the order they run in and the tiers SQL cannot reach — the `UserDefaults` mirrors, the image
/// cache, and the preference flags that describe what is still on disk. Callers used to
/// reassemble that sequence themselves, in two different orders, from two different files.
@MainActor
final class LocalDataEraser {
    enum Scope: Equatable {
        /// What a sign-out or an account change drops: the cached snapshot, the mirrors, the
        /// command receipts and the in-memory image tier. Durable history survives.
        case session
        /// Coordinates and charging-location labels only.
        case locations
        /// High-volume samples older than the retention window.
        case samples(olderThanDays: Int)
        /// Age-based pruning across the low-volume history tables.
        case aged
        /// Reclaim space without deleting rows.
        case compact
        /// Everything, for the scope's VIN or the whole database.
        case everything
    }

    private let database: VehicleDatabase
    private let preferences: PreferencesStore
    private let imageCache: CarImageCache

    init(database: VehicleDatabase, preferences: PreferencesStore, imageCache: CarImageCache) {
        self.database = database
        self.preferences = preferences
        self.imageCache = imageCache
    }

    /// The complete sequence on the calling actor. The session teardown path uses this: it must
    /// finish before the provider sign-out that follows it.
    func perform(_ scope: Scope, vin: String?) throws {
        try Self.runSQL(scope, vin: vin, database: database)
        applyLocalTiers(scope, vin: vin)
    }

    /// The same sequence with the SQL half on a utility task. The Settings actions use this
    /// because `compact` and `everything` rewrite the whole file.
    func performInBackground(_ scope: Scope, vin: String?) async throws {
        let database = database
        try await Task.detached(priority: .utility) {
            try Self.runSQL(scope, vin: vin, database: database)
        }.value
        applyLocalTiers(scope, vin: vin)
    }

    /// SQL only, so it can run on any thread. Ordered before `applyLocalTiers` everywhere: the
    /// mirrors must not be dropped before the delete they mirror has committed.
    private nonisolated static func runSQL(_ scope: Scope, vin: String?, database: VehicleDatabase) throws {
        switch scope {
        case .session:
            if let vin {
                database.deleteSnapshot(for: vin)
            } else {
                database.deleteAllSnapshots()
            }
        case .locations:
            try database.clearStoredLocationsOrThrow(for: vin)
        case .samples(let olderThanDays):
            try database.pruneHistoricalSamplesOrThrow(olderThanDays: olderThanDays)
        case .aged:
            try database.pruneAgedHistoryOrThrow()
        case .compact:
            try database.vacuumOrThrow()
        case .everything:
            try database.wipeAllOrThrow(for: vin)
        }
    }

    private func applyLocalTiers(_ scope: Scope, vin: String?) {
        switch scope {
        case .session, .everything:
            // An old snapshot or command receipt reappears after relaunch if the mirror is left
            // behind, so the mirror always moves with the row it mirrors.
            preferences.clearLocalVehicleDefaults(for: vin)
            imageCache.dropMemoryCache(for: vin)
        case .locations:
            // Turning the preference off is what keeps the cleared coordinates cleared.
            preferences.persistLocationHistory = false
            preferences.clearLocalVehicleDefaults(
                for: vin, includeBaselines: false, includeCommandReceipts: false)
        case .samples, .aged, .compact:
            break
        }
    }
}
