import Foundation

// MARK: - Charging cost by location

extension HistoryInsights {
    /// Sessions at one place, in one currency. Currencies are never added together, so a place
    /// that was charged in two currencies yields two rows.
    struct LocationCostRow: Identifiable, Equatable {
        var id: String { "\(name)\u{1F}\(currency)" }
        let name: String
        let currency: String
        let sessionCount: Int
        let energyKwh: Double
        let totalCost: Double

        /// `nil` when no energy was recorded, so there is nothing to average over.
        var averageCostPerKwh: Double? {
            energyKwh > 0 ? totalCost / energyKwh : nil
        }
    }

    /// Groups sessions by place name and currency, most-used place first. Each session's own
    /// cost is honoured the same way the other charging totals honour it; a session with no
    /// saved price falls back to `fallbackPricePerKwh`. Sessions without a place name collapse
    /// into one `unknownLabel` bucket rather than being dropped.
    static func locationCostRows(from sessions: [HistoricalChargingSession],
                                 fallbackPricePerKwh: Double,
                                 fallbackCurrency: String,
                                 ratePolicy: ElectricityRatePolicy = .fixed,
                                 unknownLabel: String) -> [LocationCostRow] {
        struct Accumulator { var count = 0; var energy = 0.0; var cost = 0.0 }
        var byKey: [String: (name: String, currency: String, acc: Accumulator)] = [:]
        for session in sessions {
            let trimmedName = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmedName?.isEmpty == false ? trimmedName! : unknownLabel
            let trimmedCurrency = session.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            let currency = trimmedCurrency?.isEmpty == false ? trimmedCurrency! : fallbackCurrency
            let key = "\(name)\u{1F}\(currency)"
            var entry = byKey[key] ?? (name, currency, Accumulator())
            entry.acc.count += 1
            entry.acc.energy += session.energyDeliveredKwh
            entry.acc.cost += session.resolvedCost(policy: ratePolicy, fallbackPricePerKwh: fallbackPricePerKwh).amount
            byKey[key] = entry
        }
        return byKey.values
            .map { entry in
                LocationCostRow(name: entry.name, currency: entry.currency, sessionCount: entry.acc.count,
                                energyKwh: entry.acc.energy, totalCost: entry.acc.cost)
            }
            .sorted {
                if $0.sessionCount != $1.sessionCount { return $0.sessionCount > $1.sessionCount }
                if $0.name != $1.name { return $0.name < $1.name }
                return $0.currency < $1.currency
            }
    }
}
