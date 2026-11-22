import Foundation
import WidgetKit

/// One widget render pass. Carries the snapshot (nil draws the placeholder) and the date
/// the age line is measured against; everything else on screen was resolved by the app.
struct VehicleWidgetEntry: TimelineEntry, Equatable, Sendable {
    let date: Date
    let snapshot: VehicleWidgetSnapshot?
    /// Set when the configured car is missing and the active car stands in; the note says
    /// which car is shown instead. Already resolved through the snapshot's language.
    var fallbackNote: String? = nil

    /// Where a tap takes the reader: the rendered car's own view when a snapshot exists,
    /// the panel toggle when it does not. The widget never sends a command itself.
    var link: URL {
        guard let snapshot else { return URL(string: "hisingen://status")! }
        let vin = snapshot.vin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? snapshot.vin
        return URL(string: "hisingen://select-car?vin=\(vin)") ?? URL(string: "hisingen://status")!
    }

    var checkedLine: String? { snapshot?.checkedLine(now: date) }

    static func filled(
        _ snapshot: VehicleWidgetSnapshot, now: Date, fallbackNote: String? = nil
    ) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: now, snapshot: snapshot, fallbackNote: fallbackNote)
    }

    static func empty(now: Date) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: now, snapshot: nil)
    }
}

/// Serves one entry per timeline pass, re-reading the App Group container for the car the
/// widget's configuration names. The age line is the only value that keeps moving, so a
/// 15-minute reload keeps it honest without any network work; the app also reloads the
/// timeline after every completed refresh.
struct VehicleTimelineProvider: AppIntentTimelineProvider {
    /// Injectable so tests read a fixture directory instead of the real App Group container.
    var directory: URL? = nil

    func placeholder(in context: Context) -> VehicleWidgetEntry {
        VehicleWidgetEntry.empty(now: Date())
    }

    func snapshot(for configuration: VehicleSelectionIntent, in context: Context) async -> VehicleWidgetEntry {
        Self.entry(now: Date(), selectedVIN: configuration.target?.id, directory: directory)
    }

    func timeline(for configuration: VehicleSelectionIntent, in context: Context) async -> Timeline<VehicleWidgetEntry> {
        let now = Date()
        let entry = Self.entry(now: now, selectedVIN: configuration.target?.id, directory: directory)
        return Timeline(entries: [entry], policy: .after(now.addingTimeInterval(900)))
    }

    /// The active car only: the pre-configuration behaviour every existing reader of this
    /// entry point (including the round-trip tests) pins.
    static func entry(now: Date, directory: URL?) -> VehicleWidgetEntry {
        entry(now: now, selectedVIN: nil, directory: directory)
    }

    /// Resolves the configured VIN against the two snapshot files and builds the entry,
    /// carrying the fallback note (already worded in the shown car's language) when the
    /// active car stood in for a missing one.
    static func entry(now: Date, selectedVIN: String?, directory: URL?) -> VehicleWidgetEntry {
        let active = WidgetSnapshotStore.load(directory: directory)
        let garage = WidgetSnapshotStore.loadGarage(directory: directory)
        let outcome = VehicleWidgetSelection.resolve(
            selectedVIN: selectedVIN, active: active, garage: garage)
        guard let snapshot = outcome.snapshot else { return .empty(now: now) }
        let note = outcome.substitutedActiveCar
            ? WidgetL10n.format("Vehicle not on file — showing %@", snapshot.languageCode, snapshot.name)
            : nil
        return .filled(snapshot, now: now, fallbackNote: note)
    }
}
