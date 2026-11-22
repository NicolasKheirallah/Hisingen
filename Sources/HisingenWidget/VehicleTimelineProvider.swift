import Foundation
import WidgetKit

/// One widget render pass. Carries the snapshot (nil draws the placeholder) and the date
/// the age line is measured against; everything else on screen was resolved by the app.
struct VehicleWidgetEntry: TimelineEntry, Equatable, Sendable {
    let date: Date
    let snapshot: VehicleWidgetSnapshot?

    /// Where a tap on the data area takes the reader: the car's own view when a snapshot
    /// exists, the panel toggle when it does not. Command buttons carry their own intents, so
    /// the extension never sends a command itself.
    var link: URL {
        guard let snapshot else { return URL(string: "hisingen://status")! }
        let vin = snapshot.vin.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? snapshot.vin
        return URL(string: "hisingen://select-car?vin=\(vin)") ?? URL(string: "hisingen://status")!
    }

    var checkedLine: String? { snapshot?.checkedLine(now: date) }

    static func filled(_ snapshot: VehicleWidgetSnapshot, now: Date) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: now, snapshot: snapshot)
    }

    static func empty(now: Date) -> VehicleWidgetEntry {
        VehicleWidgetEntry(date: now, snapshot: nil)
    }
}

/// Serves one entry per timeline pass, re-read from the App Group container. The age line
/// is the only value that keeps moving, so a 15-minute reload keeps it honest without any
/// network work; the app also reloads the timeline after every completed refresh.
struct VehicleTimelineProvider: TimelineProvider {
    /// Injectable so tests read a fixture directory instead of the real App Group container.
    var directory: URL? = nil

    func placeholder(in context: Context) -> VehicleWidgetEntry {
        VehicleWidgetEntry.empty(now: Date())
    }

    func getSnapshot(in context: Context, completion: @escaping (VehicleWidgetEntry) -> Void) {
        completion(Self.entry(now: Date(), directory: directory))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<VehicleWidgetEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [Self.entry(now: now, directory: directory)],
                            policy: .after(now.addingTimeInterval(900))))
    }

    static func entry(now: Date, directory: URL?) -> VehicleWidgetEntry {
        WidgetSnapshotStore.load(directory: directory)
            .map { VehicleWidgetEntry.filled($0, now: now) }
            ?? VehicleWidgetEntry.empty(now: now)
    }
}
