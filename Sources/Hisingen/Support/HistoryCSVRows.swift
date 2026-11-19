import Foundation

/// The column values of the trip and charging-session CSV exports, in the order of
/// `CSV.tripHistoryHeader` and `CSV.chargingHistoryHeader`.
///
/// The full-history export (ledger) and the selected-period export (history view) write the same
/// columns but follow different number and escaping policies, and a test pins both. The column
/// list lives here once; each caller passes its own `Number` and, for the location name, its own
/// escaping, and applies its own cell quoting to the result.
enum HistoryCSVRows {
    /// Formats `value` with the given number of decimal places.
    typealias Number = @Sendable (Double, Int) -> String

    static let posix: Number = { String(format: "%.\($1)f", $0) }

    static let localized: Number = { String(format: "%.\($1)f", locale: L10n.displayLocale, $0) }

    static func trip(_ trip: TripHistoryEntry, number: Number) -> [String] {
        func coordinate(_ value: Double?) -> String { value.map { String($0) } ?? "" }
        func optional(_ value: Double?, _ places: Int) -> String { value.map { number($0, places) } ?? "" }
        return [
            trip.id, trip.vin,
            Format.iso8601.string(from: trip.startedAt),
            Format.iso8601.string(from: trip.endedAt),
            number(trip.duration / 60, 1),
            number(trip.distanceKm, 2),
            optional(trip.averageConsumption, 2),
            optional(trip.ambientTemperatureCelsius, 1),
            coordinate(trip.startLatitude), coordinate(trip.startLongitude),
            coordinate(trip.endLatitude), coordinate(trip.endLongitude)
        ]
    }

    /// The 25 columns before the charger columns, which the caller appends from
    /// `WallboxCSV.fields`. Built in small typed groups: one 25-element literal plus a
    /// concatenation is more than the pinned Xcode can type-check in reasonable time.
    static func chargingSession(_ s: HistoricalChargingSession, number: Number,
                                location: (String) -> String) -> [String] {
        func optional(_ value: Double?, _ places: Int) -> String { value.map { number($0, places) } ?? "" }
        let endedAt: String = s.endedAt.map { Format.iso8601.string(from: $0) } ?? ""
        let startSoc: String = s.startSoc < 0 ? "" : number(s.startSoc, 1)
        let nightStart: String = s.nightTariffStartHour.map(String.init) ?? ""
        let nightEnd: String = s.nightTariffEndHour.map(String.init) ?? ""
        var fields: [String] = []
        fields += [s.id, s.vin, Format.iso8601.string(from: s.startedAt), endedAt, startSoc]
        fields += [
            optional(s.endSoc, 1),
            number(s.energyDeliveredKwh, 2),
            number(s.peakPowerKw, 1),
            number(s.averagePowerKw, 1)
        ]
        fields += [
            location(s.locationName ?? ""),
            s.lifecycleState.rawValue,
            s.completionReason?.rawValue ?? "",
            s.energySource.rawValue,
            s.confidence.rawValue
        ]
        fields += [
            optional(s.sampleCoverage, 3),
            optional(s.usableCapacityKwh, 2),
            optional(s.tariffPricePerKwh, 4),
            String(s.nightTariffEnabled),
            optional(s.nightTariffPricePerKwh, 4),
            nightStart,
            nightEnd
        ]
        fields += [
            optional(s.estimatedCost, 2),
            s.currencySymbol ?? "",
            optional(s.targetSoc, 1),
            String(s.summaryVersion)
        ]
        return fields
    }
}
