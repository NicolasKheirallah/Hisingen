import Foundation

/// One import-price slot as Tibber publishes it through Home Assistant: the all-in price per kWh
/// for a stretch of time (energy, taxes and the supplier's markup; not the grid fee).
struct HomePricePoint: Equatable, Sendable {
    var start: Date
    var end: Date
    var pricePerKwh: Double
    /// Tibber's own reading of this slot against its recent average, when the source gave one.
    var level: TibberPriceLevel? = nil
}

/// How Tibber rates a price slot against the prices around it.
enum TibberPriceLevel: String, Codable, CaseIterable, Sendable {
    case veryCheap = "VERY_CHEAP"
    case cheap = "CHEAP"
    case normal = "NORMAL"
    case expensive = "EXPENSIVE"
    case veryExpensive = "VERY_EXPENSIVE"

    /// Position on the five-step scale, cheapest first.
    var rank: Int { Self.allCases.firstIndex(of: self) ?? 2 }

    init(rank: Int) { self = Self.allCases[min(max(rank, 0), Self.allCases.count - 1)] }

    var title: String {
        switch self {
        case .veryCheap: return L10n.text("Very cheap")
        case .cheap: return L10n.text("Cheap")
        case .normal: return L10n.text("Normal")
        case .expensive: return L10n.text("Expensive")
        case .veryExpensive: return L10n.text("Very expensive")
        }
    }
}

/// The cost of one charger session with the way it was reached recorded beside it.
struct HomeSessionCost: Codable, Equatable, Sendable {
    enum Method: String, Codable, Sendable {
        /// Charger energy per interval against Tibber's 15-minute prices.
        case intervalTibber = "interval_tibber_15min"
        /// Session total at the time-weighted average Tibber price over the session.
        case totalTibberAverage = "total_tibber_span_average"
        /// Session total at the average market price plus the Hisingen rate settings.
        case totalSpotPolicy = "total_spot_price_policy"
        /// Session total at the typed-in tariff.
        case totalFixedTariff = "total_fixed_tariff"
    }

    var method: Method
    /// `nil` when interval pricing found slots missing: the gap is reported, not filled.
    var amount: Double?
    /// What the priced intervals add up to when some were missing.
    var partialAmount: Double?
    var pricedKwh: Double
    var missingKwh: Double
    var priceSource: String
    var assumptions: [String]
    var currency: String

    var isEstimate: Bool { method != .intervalTibber }
    var isIncomplete: Bool { amount == nil }
}

enum HomeSessionPricer {
    /// What Hisingen's own rate settings can offer when Tibber has no price for the session.
    struct Fallback: Sendable {
        var fixedPricePerKwh: Double
        var policy: ElectricityRatePolicy
        /// Market (spot) series from the Charging Planner's source, excluding taxes and fees.
        var spotPrices: [ElectricityPricePoint]
        var currency: String
    }

    static let tibberSource = "Tibber import prices via Home Assistant (tibber.get_prices)"
    static let tibberAPISource = "Tibber import prices from the Tibber API"
    static let spotSource = "Spot prices from elprisetjustnu.se with the Hisingen rate settings"
    static let tariffSource = "Fixed tariff from the Hisingen rate settings"

    /// `tibberSource` names where `tibber` came from: Home Assistant by default, or the Tibber API.
    /// A flat network fee, as a charger's own setting gives it.
    static func price(_ session: HomeChargingSessionCandidate, tibber: [HomePricePoint],
                      networkFeeOrePerKwh: Double, fallback: Fallback,
                      tibberSource: String = HomeSessionPricer.tibberSource) -> HomeSessionCost {
        price(session, tibber: tibber, gridTariff: .flat(orePerKwh: networkFeeOrePerKwh), fallback: fallback,
              tibberSource: tibberSource)
    }

    /// The grid tariff decides the fee for each stretch of the session by the clock, so a session that
    /// runs across the edge of the high-load window pays each side its own rate.
    static func price(_ session: HomeChargingSessionCandidate, tibber: [HomePricePoint],
                      gridTariff: GridTariff, fallback: Fallback,
                      tibberSource: String = HomeSessionPricer.tibberSource) -> HomeSessionCost {
        var assumptions = ["Tibber's price includes energy, taxes and Tibber's markup"]
        if gridTariff.isTimeVarying {
            assumptions.append("Grid transfer fee by the time of day added: \(trimmed(gridTariff.peakOrePerKwh)) öre/kWh in high-load time, \(trimmed(gridTariff.offPeakOrePerKwh)) öre/kWh otherwise")
        } else if gridTariff.hasFee {
            assumptions.append("Variable network fee of \(trimmed(gridTariff.offPeakOrePerKwh)) öre/kWh added")
        } else {
            assumptions.append("No variable network fee is set, so none is added")
        }

        let slots = tibber.sorted { $0.start < $1.start }

        if session.hasPriceableIntervals, !slots.isEmpty, let note = session.energyProfileNote { assumptions.append(note) }
        if session.hasPriceableIntervals, !slots.isEmpty {
            var cost = 0.0
            var priced = 0.0
            var missing = max(0, session.energyKwh - session.intervalEnergyKwh)
            for interval in session.intervals {
                let duration = interval.end.timeIntervalSince(interval.start)
                guard duration > 0 else { continue }
                var coveredSeconds = 0.0
                for slot in slots {
                    let overlap = min(slot.end, interval.end).timeIntervalSince(max(slot.start, interval.start))
                    guard overlap > 0 else { continue }
                    let share = interval.kwh * overlap / duration
                    let from = max(slot.start, interval.start)
                    let fee = gridTariff.averageFeePerKwh(from: from, to: from.addingTimeInterval(overlap))
                    cost += share * (slot.pricePerKwh + fee)
                    priced += share
                    coveredSeconds += overlap
                }
                if coveredSeconds < duration - 0.5 {
                    missing += interval.kwh * (duration - coveredSeconds) / duration
                }
            }
            let complete = missing < 0.005
            if !complete { assumptions.append("Prices were missing for \(trimmed(missing, 2)) kWh, so no total is shown") }
            return HomeSessionCost(
                method: .intervalTibber, amount: complete ? cost : nil, partialAmount: complete ? nil : cost,
                pricedKwh: priced, missingKwh: missing, priceSource: tibberSource,
                assumptions: assumptions, currency: fallback.currency
            )
        }

        // Only a session total (or intervals too coarse to price by the clock): an estimate, with
        // the method recorded.
        if let average = coveredAverage(slots, from: session.startedAt, to: session.endedAt) {
            assumptions.append("Session total priced at the time-weighted average price over the session")
            return HomeSessionCost(
                method: .totalTibberAverage,
                amount: session.energyKwh * (average + gridTariff.averageFeePerKwh(from: session.startedAt, to: session.endedAt)),
                partialAmount: nil,
                pricedKwh: session.energyKwh, missingKwh: 0, priceSource: tibberSource,
                assumptions: assumptions, currency: fallback.currency
            )
        }

        if fallback.policy.isAutomatic {
            let settled = fallback.policy.contract.settle(fallback.spotPrices)
            let spot = settled.map { HomePricePoint(start: $0.startDate, end: $0.endDate, pricePerKwh: $0.sekPerKwh) }
            if let average = coveredAverage(spot, from: session.startedAt, to: session.endedAt) {
                let retail = fallback.policy.retailPrice(spotSekPerKwh: average)
                return HomeSessionCost(
                    method: .totalSpotPolicy, amount: session.energyKwh * retail, partialAmount: nil,
                    pricedKwh: session.energyKwh, missingKwh: 0, priceSource: spotSource,
                    assumptions: [
                        "Spot prices exclude taxes and fees; the \(fallback.policy.provider.title) markup, other charges and VAT from the Hisingen rate settings are added",
                        "Session total priced at the time-weighted average price over the session"
                    ],
                    currency: fallback.currency
                )
            }
        }

        return HomeSessionCost(
            method: .totalFixedTariff, amount: session.energyKwh * fallback.fixedPricePerKwh, partialAmount: nil,
            pricedKwh: session.energyKwh, missingKwh: 0, priceSource: tariffSource,
            assumptions: ["No Tibber or spot prices cover this session; the typed-in price per kWh is used as entered"],
            currency: fallback.currency
        )
    }

    /// Time-weighted mean price across `[start, end]`, or `nil` unless the slots cover all of it.
    static func coveredAverage(_ slots: [HomePricePoint], from start: Date, to end: Date) -> Double? {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return nil }
        var weighted = 0.0
        var covered = 0.0
        for slot in slots {
            let overlap = min(slot.end, end).timeIntervalSince(max(slot.start, start))
            guard overlap > 0 else { continue }
            weighted += overlap * slot.pricePerKwh
            covered += overlap
        }
        guard covered >= duration - 1 else { return nil }
        return weighted / covered
    }

    private static func trimmed(_ value: Double, _ decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", value)
    }
}

/// Reads the `tibber.get_prices` action response.
enum TibberPriceResponse {
    /// `prices` maps a Tibber home's nickname to its slots. A slot ends where the next begins; the
    /// last one is as long as the one before it.
    static func points(from response: HAJSONValue, home: String?) -> [HomePricePoint] {
        guard let prices = response.objectValue?["prices"]?.objectValue else { return [] }
        let entries: [HAJSONValue]
        if let home, let chosen = prices[home]?.arrayValue {
            entries = chosen
        } else if let first = prices.keys.sorted().first, let chosen = prices[first]?.arrayValue {
            entries = chosen
        } else {
            return []
        }
        let raw: [(start: Date, price: Double)] = entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let startText = object["start_time"]?.stringValue,
                  let start = HATimestamp.parse(startText),
                  let price = object["price"]?.doubleValue else { return nil }
            return (start, price)
        }.sorted { $0.start < $1.start }
        guard !raw.isEmpty else { return [] }
        var points: [HomePricePoint] = []
        var lastStep: TimeInterval = 900
        for (index, slot) in raw.enumerated() {
            let step: TimeInterval
            if index + 1 < raw.count {
                step = raw[index + 1].start.timeIntervalSince(slot.start)
                if step > 0 { lastStep = step }
            } else {
                step = lastStep
            }
            guard step > 0 else { continue }
            points.append(HomePricePoint(start: slot.start, end: slot.start.addingTimeInterval(step), pricePerKwh: slot.price))
        }
        return points
    }
}
