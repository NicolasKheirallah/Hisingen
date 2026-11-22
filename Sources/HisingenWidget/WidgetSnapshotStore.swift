import Foundation
import HisingenIntents

/// The reading age line: the one display value the app does not resolve in the snapshot,
/// because it keeps moving after the file is written. Thresholds and strings mirror the app's
/// `Format.relativeAge`, and the keys already exist in every shipped language table.
extension VehicleWidgetSnapshot {
    func checkedLine(now: Date) -> String {
        WidgetL10n.format("Checked %@", languageCode, ageText(now: now))
    }

    private func ageText(now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 { return WidgetL10n.text("just now", languageCode) }
        if seconds < 3_600 { return WidgetL10n.format("%d min ago", languageCode, seconds / 60) }
        if seconds < 86_400 { return WidgetL10n.format("%d hr ago", languageCode, seconds / 3_600) }
        return WidgetL10n.format("%d d ago", languageCode, seconds / 86_400)
    }
}

/// Reads the snapshot out of the App Group container. Every miss (no container, no file,
/// undecodable bytes, an unknown schema) is the same honest answer: no snapshot, and the
/// widget draws its placeholder.
enum WidgetSnapshotStore {
    static func snapshotURL(directory: URL? = nil) -> URL? {
        WidgetSnapshotFile.url(named: VehicleWidgetSnapshot.fileName, directory: directory)
    }

    static func load(directory: URL? = nil) -> VehicleWidgetSnapshot? {
        guard let url = snapshotURL(directory: directory),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(VehicleWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == VehicleWidgetSnapshot.currentSchemaVersion
        else { return nil }
        return snapshot
    }

    /// The garage the widget's Edit sheet lists. An empty array covers every miss the same way
    /// `load` answers nil: an older app, a future schema, or corrupt bytes all mean "no list",
    /// and the picker then offers nothing while the active-car file keeps the widget rendering.
    static func loadGarage(directory: URL? = nil) -> [VehicleWidgetSnapshot] {
        guard let url = garageURL(directory: directory),
              let data = try? Data(contentsOf: url),
              let garage = try? JSONDecoder().decode(VehicleWidgetGarageSnapshot.self, from: data),
              garage.schemaVersion == VehicleWidgetGarageSnapshot.currentSchemaVersion
        else { return [] }
        return garage.cars
    }

    static func garageURL(directory: URL? = nil) -> URL? {
        WidgetSnapshotFile.url(named: VehicleWidgetGarageSnapshot.fileName, directory: directory)
    }
}
