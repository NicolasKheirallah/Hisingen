import Foundation

/// What a trip cost to drive, from the same rate policy the charging figures use.
///
/// A trip is not a charging session: there is no stored cost to resolve, only energy the car
/// burned between two odometer readings. So the rule is the plain one the reader can check –
/// distance × reported consumption × the price per kWh their rate settings produce – and every
/// input it cannot honestly supply stays `nil` rather than becoming an estimate.
enum TripCost {
    /// Energy a trip used, from its distance and the vehicle's reported consumption. Consumption
    /// outside `HistoryInsights.efficiencyBounds` is a misread, not an economy figure, so it is
    /// dropped the same way the efficiency chart drops it.
    static func energyKwh(distanceKm: Double, consumptionKwhPer100Km: Double?) -> Double? {
        guard distanceKm > 0, let consumption = consumptionKwhPer100Km,
              consumption.isFinite,
              HistoryInsights.efficiencyBounds.contains(consumption) else { return nil }
        return distanceKm * consumption / 100
    }

    static func cost(energyKwh: Double?, pricePerKwh: Double?) -> Double? {
        guard let energyKwh, energyKwh > 0, let pricePerKwh, pricePerKwh > 0,
              energyKwh.isFinite, pricePerKwh.isFinite else { return nil }
        return energyKwh * pricePerKwh
    }
}

/// The per-kWh retail price report figures are priced at.
///
/// Fixed mode uses the reader's own tariff (`fallbackPricePerKwh`) – already a retail figure.
/// Automatic mode converts the average market price over the window through the same
/// `ElectricityRatePolicy` (markup, charges, VAT) the charging rows use, and says when it had to
/// fall back to the fixed tariff instead.
enum ReportPricing {
    static func retailPricePerKwh(
        policy: ElectricityRatePolicy,
        fallbackPricePerKwh: Double,
        averageSpotSekPerKwh: Double?
    ) -> (price: Double, usedFallback: Bool) {
        if policy.isAutomatic, let spot = averageSpotSekPerKwh, spot.isFinite {
            return (policy.retailPrice(spotSekPerKwh: spot), false)
        }
        return (fallbackPricePerKwh, true)
    }

    /// Time-weighted average spot price over a window. Each point contributes its own price for
    /// the part of its slot the window covers, so a week whose prices start mid-day is not skewed
    /// by counting a slot that mostly falls outside it. `nil` when no stored slot overlaps.
    static func averageSpot(_ points: [ElectricityPricePoint], over period: ReportPeriod) -> Double? {
        var weighted = 0.0
        var covered: TimeInterval = 0
        for point in points {
            let start = max(point.startDate, period.start)
            let end = min(point.endDate, period.end)
            let seconds = end.timeIntervalSince(start)
            guard seconds > 0, point.sekPerKwh.isFinite else { continue }
            weighted += point.sekPerKwh * seconds
            covered += seconds
        }
        guard covered > 0 else { return nil }
        return weighted / covered
    }
}
