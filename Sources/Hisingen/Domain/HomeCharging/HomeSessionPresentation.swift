import Foundation

/// The wording for the charger's side of a session: what it measured, when, and how its cost was reached.
struct WallboxSessionPresentation: Equatable {
    var energyValue: String
    var energyInfo: String
    var costLabel: String
    /// `nil` when no cost is known at all.
    var costValue: String?
    var costInfo: String?

    init(_ wallbox: WallboxMeasurement, currencyFallback: String) {
        energyValue = Format.energyKwh(wallbox.energyKwh)
        let measuredAt = Format.dateTimeFormatter.string(from: wallbox.measuredAt)
        if let vendor = Self.vendorName(for: wallbox.energySource) {
            energyInfo = L10n.format("Metered by the charger and read from the %@ cloud. Last charger reading %@.", vendor, measuredAt)
        } else {
            energyInfo = L10n.format("Metered by the charger and read from Home Assistant. Last charger reading %@.", measuredAt)
        }
        let currency = wallbox.currency ?? currencyFallback
        if let cost = wallbox.cost {
            costValue = Format.currency(cost, symbol: currency)
            costLabel = wallbox.isEstimatedCost ? L10n.text("Estimated Electricity Cost") : L10n.text("Electricity Cost")
        } else if let missing = wallbox.missingKwh, missing > 0.005 {
            costValue = L10n.format("Missing prices for %@", Format.energyKwh(missing, decimals: 2))
            costLabel = L10n.text("Electricity Cost")
        } else {
            costValue = nil
            costLabel = L10n.text("Electricity Cost")
        }
        var lines: [String] = []
        if let source = wallbox.priceSource { lines.append(L10n.format("Price source: %@.", source)) }
        if let method = wallbox.costMethod.flatMap(HomeSessionCost.Method.init(rawValue:)) {
            lines.append(Self.methodSentence(method))
        }
        lines.append(contentsOf: wallbox.costAssumptions)
        costInfo = lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    /// The vendor a session's energy came straight from, or `nil` when it came through Home Assistant.
    static func vendorName(for energySource: String) -> String? {
        ChargerSource.allCases.first { $0.isDirect && energySource.hasPrefix("\($0.rawValue)_") }?.providerName
    }

    private static func methodSentence(_ method: HomeSessionCost.Method) -> String {
        switch method {
        case .intervalTibber: return L10n.text("Priced per 15-minute interval from the charger's own readings.")
        case .totalTibberAverage: return L10n.text("Only the session total was available, so this is an estimate.")
        case .totalSpotPolicy: return L10n.text("Only the session total was available, so this is an estimate.")
        case .totalFixedTariff: return L10n.text("Only the session total was available, so this is an estimate.")
        }
    }
}

/// The charging rate a plan should assume, taken from what the charger actually delivered.
enum HomeChargingRate {
    /// Intervals under this are idle time between bursts, not charging.
    static let activeThresholdKw = 0.5

    /// The median, over recent sessions, of the average power while the charger was delivering.
    /// `nil` when no session has intervals fine enough to tell.
    static func estimate(fromSessions sessions: [[HomeEnergyInterval]]) -> Double? {
        let rates = sessions.compactMap { intervals -> Double? in
            var hours = 0.0
            var kwh = 0.0
            for interval in intervals {
                let span = interval.end.timeIntervalSince(interval.start) / 3_600
                guard span > 0, interval.kwh / span >= activeThresholdKw else { continue }
                hours += span
                kwh += interval.kwh
            }
            return hours > 0 ? kwh / hours : nil
        }.sorted()
        guard !rates.isEmpty else { return nil }
        let middle = rates.count / 2
        return rates.count % 2 == 1 ? rates[middle] : (rates[middle - 1] + rates[middle]) / 2
    }
}
