import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    nonisolated static func removeSnapshotMirrorEntry(
        _ d: UserDefaults, _ key: String, _ vin: String
    ) {
        removeJSONEntry(VehicleState.self, key: key, vin: vin, from: d)
    }

    /// Removes one vehicle's local state from `UserDefaults`. A database erase must clear these
    /// too or an old snapshot or command receipt can reappear after relaunch.
    ///
    /// All twelve stores go, including the reader-authored nickname and theme. The action is
    /// presented as "local vehicle data was erased", and a name or colour that outlives its
    /// vehicle is the half-erase that sentence exists to rule out; the accepted cost is that
    /// re-adding the car means naming and colouring it again. A sign-out that knows the vehicle
    /// takes the same twelve, because that vehicle's session genuinely ended and it is the
    /// vehicle the reader acted on.
    ///
    /// The VIN is normalized the way every writer normalizes it, so a caller holding a
    /// lower-case or padded identifier still reaches the entry that was written. An undecodable
    /// legacy payload is left in place rather than removed, because removing it would take every
    /// other vehicle's entries with it.
    func clearLocalVehicleDefaults(for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // An empty VIN names no vehicle; it never stands for all of them.
        guard !key.isEmpty else { return }
        for store in Self.perVehicleStores {
            store.remove(d, store.key, key)
        }
    }

    /// The all-twelve fleet erase, for the reader-chosen "Erase All Local Vehicle Data" action:
    /// names, themes, baselines and receipts for every vehicle this Mac knows about. Its own
    /// member because "no VIN" used to mean this, and the reader asking for every vehicle to be
    /// gone is the one thing that may take what the reader authored.
    func clearAllLocalVehicleDefaults() {
        for store in Self.perVehicleStores {
            d.removeObject(forKey: store.key)
        }
    }

    /// The fleet-wide erase for a sign-out that no longer knows any vehicle. Only the
    /// vehicle-derived half goes: ending a session discards what the vehicles reported, and the
    /// reader never asked for a name or a colour to be forgotten. Taking those here would erase
    /// them for vehicles of a brand whose session was never touched.
    func clearAllVehicleDerivedDefaults() {
        for store in Self.perVehicleStores where store.ownership == .vehicleDerived {
            d.removeObject(forKey: store.key)
        }
    }

    /// The single store a location erase invalidates. It is named rather than reached through an
    /// exclusion on the table, because the table's set is the whole per-vehicle set: a scope that
    /// asked for "everything except these two" silently widened into the nickname, the theme and
    /// the rest the moment the table grew.
    func clearSnapshotMirror(for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // An empty VIN names no vehicle; it never stands for all of them.
        guard !key.isEmpty else { return }
        Self.removeSnapshotMirrorEntry(d, Self.snapshotMirrorKey, key)
    }

    /// The fleet-wide counterpart of `clearSnapshotMirror(for:)`.
    func clearAllSnapshotMirrors() {
        d.removeObject(forKey: Self.snapshotMirrorKey)
    }

    nonisolated static func removeJSONEntry<Value: Codable>(
        _ type: Value.Type, key: String, vin: String, from d: UserDefaults
    ) {
        guard let data = d.data(forKey: key) else { return }
        guard var values = try? JSONDecoder().decode([String: Value].self, from: data) else {
            // The blob holds every vehicle's entries, so removing it here would erase the other
            // vehicles too. Readers already treat an undecodable payload as absent, so leaving it
            // in place is harmless; it is logged so the corruption is not silent.
            AppLog.logger("preferences").error("Leaving undecodable \(key, privacy: .public) in place while erasing one vehicle.")
            return
        }
        values.removeValue(forKey: vin)
        if values.isEmpty {
            d.removeObject(forKey: key)
        } else if let encoded = try? JSONEncoder().encode(values) {
            d.set(encoded, forKey: key)
        } else {
            d.removeObject(forKey: key)
        }
    }

    /// The nine catalogs whose accessors read a property-list dictionary are not JSON, so they
    /// cannot go through `removeJSONEntry`: decoding them as JSON fails, and that failure path
    /// drops the key for every vehicle instead of the one being erased.
    nonisolated static func removeDictionaryEntry(_ key: String, vin: String, from d: UserDefaults) {
        guard var values = d.dictionary(forKey: key) else { return }
        values.removeValue(forKey: vin)
        if values.isEmpty { d.removeObject(forKey: key) } else { d.set(values, forKey: key) }
    }

    nonisolated static func removeListEntry(_ key: String, vin: String, from d: UserDefaults) {
        guard let values = d.array(forKey: key) as? [String] else { return }
        let remaining = values.filter { $0 != vin }
        if remaining.isEmpty { d.removeObject(forKey: key) } else { d.set(remaining, forKey: key) }
    }

    func vehicleNickname(for vin: String) -> String {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); guard !key.isEmpty else { return "" }
        if let values = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String], let value = values[key] { return value }
        guard key == self.vin.uppercased() else { return "" }
        return d.string(forKey: "polestar_vehicle_nickname") ?? ""
    }
    func setVehicleNickname(_ nickname: String, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String] ?? [:]
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { values.removeValue(forKey: key) } else { values[key] = value }
        d.set(values, forKey: "polestar_vehicle_nicknames_v1")
        if key == vin.uppercased() { d.removeObject(forKey: "polestar_vehicle_nickname") }
    }

    /// The charging session the History tab last had open, per vehicle, so switching tabs or
    /// periods doesn't snap the curve back to the newest session every time.
    func selectedHistorySession(for vin: String) -> String? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        return (d.dictionary(forKey: "history_selected_session_v1") as? [String: String])?[key]
    }

    func setSelectedHistorySession(_ sessionID: String?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = (d.dictionary(forKey: "history_selected_session_v1") as? [String: String]) ?? [:]
        if let sessionID { values[key] = sessionID } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "history_selected_session_v1")
    }

    /// Derived trips the user has chosen to hide because segmentation combined or invented
    /// them. Stored per vehicle as trip-id strings; the dashboard filters these out.
    func hiddenTripIDs(for vin: String) -> Set<String> {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "history_hidden_trips_v1") as? [String: [String]] else { return [] }
        return Set(all[key] ?? [])
    }

    func setTripHidden(_ hidden: Bool, id: String, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var all = (d.dictionary(forKey: "history_hidden_trips_v1") as? [String: [String]]) ?? [:]
        var ids = Set(all[key] ?? [])
        if hidden { ids.insert(id) } else { ids.remove(id) }
        if ids.isEmpty { all.removeValue(forKey: key) } else { all[key] = Array(ids) }
        d.set(all, forKey: "history_hidden_trips_v1")
    }

    func warrantyInServiceDate(for vin: String) -> Date? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let value = d.dictionary(forKey: "vehicle_in_service_dates_v1")?[key] else { return nil }
        let interval: Double
        if let number = value as? NSNumber { interval = number.doubleValue }
        else if let double = value as? Double { interval = double }
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func setWarrantyInServiceDate(_ date: Date?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "vehicle_in_service_dates_v1") ?? [:]
        if let date { values[key] = date.timeIntervalSince1970 } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "vehicle_in_service_dates_v1")
    }

    func vehicleSpecificationOverride(for vin: String) -> VehicleSpecificationOverride? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "vehicle_specification_overrides_v1") as? [String: Data],
              let data = all[key],
              let value = try? JSONDecoder().decode(VehicleSpecificationOverride.self, from: data),
              !value.isEmpty else { return nil }
        return value
    }

    func setVehicleSpecificationOverride(_ value: VehicleSpecificationOverride?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var all = d.dictionary(forKey: "vehicle_specification_overrides_v1") as? [String: Data] ?? [:]
        if let value, !value.isEmpty, let data = try? JSONEncoder().encode(value) {
            all[key] = data
        } else {
            all.removeValue(forKey: key)
        }
        d.set(all, forKey: "vehicle_specification_overrides_v1")
    }

    func dismissedSoftwareEventIdentifier(for vin: String) -> String? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        return (d.dictionary(forKey: "dismissed_software_events_v1") as? [String: String])?[key]
    }

    func setDismissedSoftwareEventIdentifier(_ identifier: String?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "dismissed_software_events_v1") as? [String: String] ?? [:]
        if let identifier { values[key] = identifier } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "dismissed_software_events_v1")
    }
}
