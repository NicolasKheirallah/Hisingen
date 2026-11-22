import Foundation

/// The one definition of the JSON the app writes into the App Group container and the widget
/// extension reads back.
///
/// The app and the extension are separate binaries, but both link this module, so the wire
/// shape lives here rather than in two hand-kept copies. A field or key can only be changed
/// in this file; `WidgetSnapshotRoundTripTests` still writes with the app's writer and decodes
/// with the widget's reader, so the exchange itself stays pinned.
///
/// Every display string is resolved by the app before writing (label format, privacy
/// redaction, distance unit, time format, language). The widget re-derives exactly one value
/// itself: the reading age line, because that keeps moving after the file is written.
package struct VehicleWidgetSnapshot: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1
    package static let fileName = "vehicle-widget-snapshot.json"

    package var schemaVersion: Int
    package var vin: String
    /// The vehicle title exactly as the app resolves it, honouring the reader's label
    /// format and privacy redaction.
    package var name: String
    /// "78%", formatted the way the app's own battery readouts are. Nil when the car
    /// reported no battery level, which stays distinguishable from a real zero.
    package var batteryText: String?
    /// "213 km", already converted to the reader's distance unit. Nil when not reported.
    package var rangeText: String?
    /// The charging state as a stable token (see `WidgetChargingKind`). The widget maps it to
    /// its own kinds and keeps unknown tokens soft rather than failing the whole decode.
    package var chargingKind: String
    /// The charging state's own words, already localized by the app.
    package var chargingText: String?
    /// "07:30" for the next reported departure, or "22 Nov · 07:30" when it is not today.
    /// Nil when no departure is on file.
    package var departureText: String?
    /// When the car's readings were fetched. The widget's age line is measured from here,
    /// the same timestamp the panel's "Checked" line uses.
    package var fetchedAt: Date
    /// When the app wrote this file. Distinct from `fetchedAt`: a cached restore can rewrite
    /// the file long after the reading.
    package var writtenAt: Date
    /// The interface language the app had selected, so the widget's few own strings follow
    /// the same choice. Nil means the app follows the system language.
    package var languageCode: String?

    package init(
        schemaVersion: Int,
        vin: String,
        name: String,
        batteryText: String?,
        rangeText: String?,
        chargingKind: String,
        chargingText: String?,
        departureText: String?,
        fetchedAt: Date,
        writtenAt: Date,
        languageCode: String?
    ) {
        self.schemaVersion = schemaVersion
        self.vin = vin
        self.name = name
        self.batteryText = batteryText
        self.rangeText = rangeText
        self.chargingKind = chargingKind
        self.chargingText = chargingText
        self.departureText = departureText
        self.fetchedAt = fetchedAt
        self.writtenAt = writtenAt
        self.languageCode = languageCode
    }

    package var charging: WidgetChargingKind? { WidgetChargingKind(rawValue: chargingKind) }
}

/// The charging tokens the app writes into a snapshot. A token the widget does not recognise
/// decodes softly (the string is kept, the enum reads nil) so a future app cannot break an
/// installed widget.
package enum WidgetChargingKind: String, CaseIterable, Sendable {
    case charging, smartCharging, paused, scheduled, idle, complete, discharging, fault, unknown

    /// Only these fill the charge line with the live colour; every other state draws the line
    /// in ink, matching the panel's "gold while charging, ink at rest" rule.
    package var isLive: Bool { self == .charging || self == .smartCharging }
}

/// The garage-level container beside the active-car snapshot: one display entry per car the
/// app can render, so a configurable widget instance can pin itself to a specific car.
///
/// Written by `WidgetSnapshotWriter` on every completed refresh. The active-car file stays
/// the single-car contract the original widget reads, so an extension from before the per-car
/// work keeps rendering unchanged.
package struct VehicleWidgetGarageSnapshot: Codable, Equatable, Sendable {
    package static let currentSchemaVersion = 1
    package static let fileName = "vehicle-widget-garage.json"

    package var schemaVersion: Int
    /// The active car first, then every other car with a stored reading. Entries reuse the
    /// per-car snapshot shape, so each one carries its own vin, display strings, timestamps
    /// and language code.
    package var cars: [VehicleWidgetSnapshot]

    package init(schemaVersion: Int, cars: [VehicleWidgetSnapshot]) {
        self.schemaVersion = schemaVersion
        self.cars = cars
    }
}

/// Where both processes find those files. The App Group identifier is derived from the app's
/// bundle id (`io.kheirallah.hisingen`), as the App Group rules require; both the app and the
/// appex entitlements declare it.
package enum WidgetSnapshotFile {
    package static let appGroupID = "group.io.kheirallah.hisingen"

    package static func url(named fileName: String, directory: URL? = nil) -> URL? {
        let base = directory
            ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
        return base?.appendingPathComponent(fileName)
    }
}
