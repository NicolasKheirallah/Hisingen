import Foundation

/// Which meter's hourly readings a share was worked out from.
enum HouseLoadMeter: Equatable, Sendable {
    case tibber
    case perific
}

/// How much of the house's metered electricity went to the car, over the hours the meter has readings for.
struct HouseLoadShare: Equatable, Sendable {
    var meter: HouseLoadMeter = .tibber
    /// Hours that carry a meter reading and count towards the totals.
    var hours: Int
    var houseKwh: Double
    /// Charger-metered energy that fell inside those hours. Sessions at other places never reach
    /// the house meter, so only sessions a home charger measured are counted.
    var carKwh: Double
    /// Sessions that contributed any energy.
    var sessions: Int
    var coveredFrom: Date
    var coveredTo: Date
    /// Energy the even spread put on the car above what the meter saw in the same hour, which the
    /// hour's reading cut off. It is zero when the spread agrees with the meter.
    var cappedKwh: Double = 0
    var cappedHours: Int = 0
    /// What Tibber billed for the house's energy, and the car's part at each hour's average price. Both
    /// are `nil` unless every counted hour has a cost and they share one currency. The grid fee is in them
    /// only when `includesGridFee` says so: Tibber's own cost leaves it out.
    var houseCost: Double? = nil
    var carCost: Double? = nil
    var currency: String? = nil
    /// The costs include the grid transfer fee from the reader's grid tariff.
    var includesGridFee: Bool = false
    /// What the home's production meter reported in the same hours, added up. `nil` unless the home
    /// reports production, so a house without a production metering point never sees the row.
    var productionKwh: Double? = nil

    var restKwh: Double { max(0, houseKwh - carKwh) }
    /// The car's part of the house total, 0 to 1.
    var carShare: Double { houseKwh > 0 ? min(1, carKwh / houseKwh) : 0 }
}

enum HouseLoad {
    /// Spreads each home-charger session evenly over its own span and adds the part inside each metered
    /// hour. Within one hour the car cannot draw more than the meter saw, so a spread that overshoots
    /// (a session that ended mid-hour, say) is held to the hour's reading and the cut is reported.
    ///
    /// Returns `nil` when no hour has a reading or no charger-measured session overlaps any of them:
    /// a share of nothing is not reported as zero.
    ///
    /// With a grid tariff, each hour's cost gets that hour's transfer fee added, because Tibber's billed
    /// cost leaves the grid fee out.
    static func share(hours: [TibberConsumptionHour], sessions: [HistoricalChargingSession],
                      gridTariff: GridTariff? = nil) -> HouseLoadShare? {
        let tariff = gridTariff.flatMap { $0.hasFee ? $0 : nil }
        let spans: [(start: Date, end: Date, kwh: Double)] = sessions.compactMap { session in
            guard let wallbox = session.wallbox, wallbox.energyKwh > 0 else { return nil }
            let start = wallbox.startedAt ?? session.startedAt
            let end = wallbox.endedAt ?? session.endedAt ?? wallbox.measuredAt
            guard end > start else { return nil }
            return (start, end, wallbox.energyKwh)
        }
        let metered = hours.filter { $0.end > $0.start && $0.kwh.isFinite && $0.kwh >= 0 }
        guard let first = metered.map(\.start).min(), let last = metered.map(\.end).max() else { return nil }

        var houseKwh = 0.0
        var carKwh = 0.0
        var cappedKwh = 0.0
        var cappedHours = 0
        var houseCost = 0.0
        var carCost = 0.0
        var carCostKnown = true
        var contributing = Set<Int>()
        for hour in metered {
            houseKwh += hour.kwh
            let fee = tariff?.averageFeePerKwh(from: hour.start, to: hour.end) ?? 0
            houseCost += (hour.cost ?? 0) + fee * hour.kwh
            var inHour = 0.0
            for (index, span) in spans.enumerated() {
                let overlap = min(span.end, hour.end).timeIntervalSince(max(span.start, hour.start))
                guard overlap > 0 else { continue }
                inHour += span.kwh * overlap / span.end.timeIntervalSince(span.start)
                contributing.insert(index)
            }
            let counted = min(inHour, hour.kwh)
            carKwh += counted
            if inHour > hour.kwh + 0.001 {
                cappedKwh += inHour - hour.kwh
                cappedHours += 1
            }
            if counted > 0 {
                if let cost = hour.cost, hour.kwh > 0 { carCost += counted * (cost / hour.kwh + fee) } else { carCostKnown = false }
            }
        }
        guard !contributing.isEmpty else { return nil }

        let currencies = Set(metered.compactMap(\.currency))
        let allPriced = metered.allSatisfy { $0.cost != nil && $0.currency != nil }
        let priced = allPriced && currencies.count == 1
        return HouseLoadShare(hours: metered.count, houseKwh: houseKwh, carKwh: carKwh, sessions: contributing.count,
                              coveredFrom: first, coveredTo: last, cappedKwh: cappedKwh, cappedHours: cappedHours,
                              houseCost: priced ? houseCost : nil,
                              carCost: priced && carCostKnown ? carCost : nil,
                              currency: priced ? currencies.first : nil,
                              includesGridFee: priced && tariff != nil)
    }
}
