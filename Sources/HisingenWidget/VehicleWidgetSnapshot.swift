import Foundation

/// The charging tokens the app writes into a snapshot. A token the widget does not
/// recognise decodes softly (the string is kept, the enum reads nil) so a future app
/// cannot break an installed widget.
enum WidgetChargingKind: String, CaseIterable, Sendable {
    case charging, smartCharging, paused, scheduled, idle, complete, discharging, fault, unknown

    /// Only these fill the charge line with the live colour; every other state draws the
    /// line in ink, matching the panel's "gold while charging, ink at rest" rule.
    var isLive: Bool { self == .charging || self == .smartCharging }
}

/// The small JSON snapshot the Hisingen app writes into the shared App Group container
/// after each completed vehicle refresh, and the widget reads back.
///
/// This is the widget-side decoder. The writer-side twin lives in
/// `Sources/Hisingen/Services/Widget/`; nothing is compiled into both targets, so the
/// two shapes must stay wire-compatible by hand. `WidgetSnapshotRoundTripTests` pins the
/// exchange by writing with the app's writer and decoding with this one.
///
/// Every display string was already resolved by the app (label format, distance unit,
/// time format, language). The widget re-derives exactly one value itself: the reading
/// age line, because that keeps moving after the file is written.
struct VehicleWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let fileName = "vehicle-widget-snapshot.json"

    var schemaVersion: Int
    var vin: String
    /// The vehicle title exactly as the app resolves it, honouring the reader's label
    /// format and privacy redaction.
    var name: String
    /// "78%", formatted the way the app's own battery readouts are. Nil when the car
    /// reported no battery level, which stays distinguishable from a real zero.
    var batteryText: String?
    /// "213 km", already converted to the reader's distance unit. Nil when not reported.
    var rangeText: String?
    /// The charging state as a stable token (see `WidgetChargingKind`).
    var chargingKind: String
    /// The charging state's own words, already localized by the app.
    var chargingText: String?
    /// "07:30" for the next reported departure, or "22 Nov · 07:30" when it is not
    /// today. Nil when no departure is on file.
    var departureText: String?
    /// When the car's readings were fetched. The widget's age line is measured from
    /// here, the same timestamp the panel's "Checked" line uses.
    var fetchedAt: Date
    /// When the app wrote this file. Distinct from `fetchedAt`: a cached restore can
    /// rewrite the file long after the reading.
    var writtenAt: Date
    /// The interface language the app had selected, so the widget's few own strings
    /// follow the same choice. Nil means the app follows the system language.
    var languageCode: String?

    var charging: WidgetChargingKind? { WidgetChargingKind(rawValue: chargingKind) }

    /// "Checked 3 hr ago". The thresholds and the strings mirror the app's
    /// `Format.relativeAge`, and the keys already exist in every shipped language table.
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

/// Reads the snapshot out of the App Group container. Every miss (no container, no
/// file, undecodable bytes, an unknown schema) is the same honest answer: no snapshot,
/// and the widget draws its placeholder.
enum WidgetSnapshotStore {
    static let appGroupID = "group.io.kheirallah.hisingen"

    static func snapshotURL(directory: URL? = nil) -> URL? {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return base?.appendingPathComponent(VehicleWidgetSnapshot.fileName)
    }

    static func load(directory: URL? = nil) -> VehicleWidgetSnapshot? {
        guard let url = snapshotURL(directory: directory),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(VehicleWidgetSnapshot.self, from: data),
              snapshot.schemaVersion == VehicleWidgetSnapshot.currentSchemaVersion
        else { return nil }
        return snapshot
    }
}
