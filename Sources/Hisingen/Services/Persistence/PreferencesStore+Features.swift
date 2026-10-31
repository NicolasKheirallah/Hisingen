import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    var features: FeatureSelection {
        get {
            if let values = d.array(forKey: "enabled_features_v2") as? [String] {
                // The stored selection is authoritative. Earlier versions force-enabled
                // three presentation features on every read, which made their Settings
                // toggles appear to work only until the next launch.
                var enabled = Set(values.compactMap(AppFeature.init))
                    .intersection(AppFeature.permittedFeatures)
                // The stream lifecycle is now activity-gated, circuit-broken, and mutually
                // aware of polling. Re-enable it once for installations migrated off the old
                // reconnecting implementation; later user changes remain authoritative.
                if !d.bool(forKey: "streaming_default_migration_v2") {
                    enabled.insert(.realTimeUpdates)
                    d.set(enabled.map(\.rawValue).sorted(), forKey: "enabled_features_v2")
                    d.set(true, forKey: "streaming_default_migration_v2")
                }
                return FeatureSelection(enabled: enabled)
            }
            // v1 installs predate the .notifications case; it shipped default-on, so the
            // migration must carry it forward or upgraders silently lose every alert.
            if let values = d.array(forKey: "enabled_features_v1") as? [String] { var set = Set(values.compactMap(AppFeature.init)); set.formUnion([.exteriorStatus, .tyreAndWarnings, .softwareUpdates, .chargingSchedule, .climateStatus, .tripMeters, .notifications]); let result = FeatureSelection(enabled: set.intersection(AppFeature.permittedFeatures)); d.set(result.enabled.map(\.rawValue).sorted(), forKey: "enabled_features_v2"); return result }
            var result = FeatureSelection.default; if d.bool(forKey: "show_vehicle_image") { result.set(.vehicleImage, enabled: true) }; return result
        }
        set { d.set(newValue.enabled.intersection(AppFeature.permittedFeatures).map(\.rawValue).sorted(), forKey: "enabled_features_v2"); d.set(true, forKey: "streaming_default_migration_v2"); d.removeObject(forKey: "enabled_features_v1"); d.removeObject(forKey: "show_vehicle_image") }
    }

    /// Which tabs exist, what is on each of them, and in what order.
    ///
    /// Stored as JSON under one key rather than as several parallel arrays, so a tab and the
    /// cards on it can never be read half-updated. Decoding failure returns the shipped layout
    /// instead of an empty panel: a corrupt layout should cost a reader their customisation,
    /// not their whole interface.
    var tabComposition: TabComposition {
        get {
            guard let data = d.data(forKey: Self.tabCompositionKey),
                  let decoded = try? JSONDecoder().decode(TabComposition.self, from: data) else {
                return seededTabComposition()
            }
            return decoded.normalized()
        }
        set {
            let clean = newValue.normalized()
            guard let data = try? JSONEncoder().encode(clean) else { return }
            d.set(data, forKey: Self.tabCompositionKey)
            d.set(true, forKey: "tab_items_seeded_v1")
        }
    }

    /// First read on an installation that predates tabs-and-cards: take the feature toggles
    /// the reader already made as the starting layout, so a card they switched off does not
    /// reappear the first time they open the panel. Runs once — after that the layout is the
    /// reader's, and a feature they re-enable through the feature list stays hidden until they
    /// say otherwise.
    private func seededTabComposition() -> TabComposition {
        guard !d.bool(forKey: "tab_items_seeded_v1") else { return .default }
        d.set(true, forKey: "tab_items_seeded_v1")
        var seeded = TabComposition.default
        let disabled = Set(AppFeature.allCases).subtracting(features.enabled)
        guard !disabled.isEmpty else { return seeded }
        for item in TabItemCatalog.all {
            guard let feature = item.feature, disabled.contains(feature) else { continue }
            // An item whose reading is never fetched cannot draw anything, so hiding it keeps
            // the layout honest instead of leaving an empty card on the tab.
            seeded.hiddenItems.insert(item.id)
        }
        return seeded
    }

    /// Switches off the readings a card arrangement no longer shows.
    ///
    /// `candidates` is every feature some card that used to need it has just been switched off
    /// for; `keptFeatures` is every feature a card the reader can still see needs, across every
    /// tab. A feature in `candidates` outside that set is a reading nothing draws on any more,
    /// so the provider request behind it stops. Deliberately conservative: a feature is only
    /// switched off when this action is what made it unnecessary, so a reading the reader turned
    /// on by hand in the feature list is never taken away by moving a card.
    ///
    /// Returns whether anything actually changed, so the caller can tell the rest of the app
    /// that the feature selection moved rather than guessing.
    @discardableResult
    func stopFetchingUnusedFeatures(_ candidates: Set<AppFeature>, keeping keptFeatures: Set<AppFeature>) -> Bool {
        let unused = candidates.subtracting(keptFeatures)
        guard !unused.isEmpty else { return false }
        var updated = features
        for feature in unused { updated.set(feature, enabled: false) }
        guard updated != features else { return false }
        features = updated
        return true
    }
}
