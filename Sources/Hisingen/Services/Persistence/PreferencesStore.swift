import Foundation
import OSLog
import SwiftUI

typealias PolestarConnectionMode = PreferencesStore.PolestarConnectionMode

/// The single source of preference state for an application composition.
/// Storage intentionally uses the legacy keys so existing installations migrate in place.
@MainActor
final class PreferencesStore {
    /// Process-wide instance for call sites outside the view hierarchy (App Intents,
    /// service wiring) that previously constructed throwaway stores – each of which also
    /// opened its own Keychain handle set.
    static let shared = PreferencesStore()

    let d: UserDefaults
    let keychain: KeychainStore
    let logger = AppLog.logger("preferences")

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .app) {
        d = defaults
        self.keychain = keychain
    }
    var cachedEmail: String?
    /// One Keychain migration attempt per process. A failed attempt leaves the legacy value in
    /// UserDefaults, so without this flag every cache refill would retry the same failing write.
    var legacyEmailMigrationAttempted = false
    var cachedHasResumableSession: [VehicleBrand: Bool] = [:]

    func invalidateSessionCache() {
        cachedEmail = nil
        cachedHasResumableSession.removeAll()
    }

    /// Whose fact a store holds, which is what decides the fleet-wide erases that may take it.
    enum Ownership {
        /// Reported by the vehicle, so a session that ends discards it: a snapshot, a command
        /// receipt, a charging baseline, the planner's notification dedupe stamp.
        case vehicleDerived
        /// Authored by the reader about the vehicle: a name, a colour, a mute, a hidden trip.
        /// These are the reader's, not the vehicle's, so ending a session must not take them –
        /// only the reader asking for that vehicle to be gone may.
        case readerAuthored
    }

    /// The legacy pre-SQLite snapshot mirror, keyed by VIN. In the table because every per-vehicle
    /// erase reaches it; named here as well because the location erase invalidates this store
    /// *alone* – a held snapshot still carries the coordinates just deleted, while a baseline, a
    /// receipt and everything the reader authored are untouched by a location change.
    static let snapshotMirrorKey = "cached_vehicle_snapshots_v1"

    /// Every `UserDefaults` store keyed by VIN, each with the ownership that decides which
    /// fleet-wide erase may take it and the removal that matches the shape its accessors write:
    /// a JSON `Codable` payload, a property-list dictionary, or – for the mute list – a
    /// property-list array of VINs. One table, so the per-vehicle erase, both fleet-wide erases
    /// and the reader-facing accessors cannot drift apart.
    static let perVehicleStores: [(
        key: String, ownership: Ownership, remove: @Sendable (UserDefaults, String, String) -> Void
    )] = [
        (snapshotMirrorKey, .vehicleDerived, removeSnapshotMirrorEntry),
        ("command_receipts_v1", .vehicleDerived, { d, key, vin in
            removeJSONEntry(StoredCommandReceipts.self, key: key, vin: vin, from: d)
        }),
        ("charging_baselines_v1", .vehicleDerived, { d, key, vin in
            removeJSONEntry(ChargingBaseline.self, key: key, vin: vin, from: d)
        }),
        ("polestar_vehicle_nicknames_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("planner_notified_window_ends_v2", .vehicleDerived, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("history_selected_session_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("history_hidden_trips_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("vehicle_in_service_dates_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("vehicle_specification_overrides_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("dismissed_software_events_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("vehicle_themes_v1", .readerAuthored, { d, key, vin in
            removeDictionaryEntry(key, vin: vin, from: d)
        }),
        ("muted_vehicle_vins_v1", .readerAuthored, { d, key, vin in
            removeListEntry(key, vin: vin, from: d)
        })
    ]

    func boolDefaultTrue(_ key: String) -> Bool { d.object(forKey: key) == nil || d.bool(forKey: key) }

    static let tabCompositionKey = "tab_composition_v1"

    /// Bundle identifiers the app shipped with before `CFBundleIdentifier` was collapsed to
    /// `io.kheirallah.hisingen`. Each was a distinct `UserDefaults` domain.
    static let legacyDefaultsDomains = ["io.kheirallah.hisingen-cc97f41c-af39-4eb1-a7e6-0014f6e1c80f"]

}

private struct PreferencesStoreKey: EnvironmentKey {
    static let defaultValue: PreferencesStore? = nil
}

@MainActor
extension EnvironmentValues {
    var preferencesStore: PreferencesStore {
        get { self[PreferencesStoreKey.self] ?? PreferencesStore() }
        set { self[PreferencesStoreKey.self] = newValue }
    }
}
