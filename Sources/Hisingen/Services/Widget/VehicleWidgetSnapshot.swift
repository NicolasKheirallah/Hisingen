import Foundation

/// The app-side half of the widget's wire shape. The widget extension is a separate
/// binary with no shared module, so the decoder twin lives in
/// `Sources/HisingenWidget/VehicleWidgetSnapshot.swift` and the two must stay
/// wire-compatible by hand; `WidgetSnapshotRoundTripTests` pins the exchange by writing
/// here and decoding there.
///
/// Every display string is resolved before writing (label format, privacy redaction,
/// distance unit, time format, language). The widget re-derives exactly one value itself:
/// the reading age line, because that keeps moving after the file is written.
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
    /// The charging state as a stable token. The widget maps it to its own kinds and
    /// keeps unknown tokens soft rather than failing the whole decode.
    var chargingKind: String
    /// The charging state's own words, already localized.
    var chargingText: String?
    /// "07:30" for the next reported departure, or "22 Nov · 07:30" when it is not
    /// today. Nil when no departure is on file.
    var departureText: String?
    /// When the car's readings were fetched; the widget's age line is measured from here,
    /// the same timestamp the panel's "Checked" line uses.
    var fetchedAt: Date
    /// When the app wrote this file. Distinct from `fetchedAt`: a cached restore can
    /// rewrite the file long after the reading.
    var writtenAt: Date
    /// The interface language the app had selected, so the widget's few own strings
    /// follow the same choice. Nil means the app follows the system language.
    var languageCode: String?
}

/// The garage-level container beside the active-car snapshot: one display entry per car
/// the app can render, so a configurable widget instance can pin itself to a specific
/// car. Written by `WidgetSnapshotWriter` on every completed refresh; the active-car
/// file stays the single-car contract the original widget reads, so an extension from
/// before the per-car work keeps rendering unchanged.
struct VehicleWidgetGarageSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let fileName = "vehicle-widget-garage.json"

    var schemaVersion: Int
    /// The active car first, then every other car with a stored reading. Entries reuse
    /// the per-car snapshot shape, so each one carries its own vin, display strings,
    /// timestamps and language code.
    var cars: [VehicleWidgetSnapshot]
}
