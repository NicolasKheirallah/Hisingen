import Foundation

/// Where the user buys electricity. Market-linked pricing (spot zones, retailers, the charging
/// planner) is built for the Swedish market, so it is offered only for Sweden; every other
/// country gets the typed-in rate.
enum MarketCountry: String, CaseIterable, Codable, Sendable, Identifiable {
    case sweden
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sweden: return L10n.text("Sweden")
        case .other: return L10n.text("Other country")
        }
    }

    var offersMarketPricing: Bool { self == .sweden }
}

/// How the electricity rate behind every charge-cost figure is chosen.
enum ElectricityRateMode: String, CaseIterable, Codable, Sendable, Identifiable {
    /// One price per kWh the user types in (plus the optional night tariff).
    case fixed
    /// Hourly or quarterly spot price for the user's zone, plus their provider's markup.
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fixed: return L10n.text("Fixed rate")
        case .automatic: return L10n.text("Automatic")
        }
    }
}

/// Swedish electricity retailers (elhandlare) a household might buy spot-price power from.
/// The provider names the contract in the UI; it carries no price. Markups (påslag) are
/// per contract and change often, so the app asks for the user's own figure instead of
/// shipping numbers that would go stale or be wrong for their agreement.
enum ElectricityProvider: String, CaseIterable, Codable, Sendable, Identifiable {
    case vattenfall
    case fortum
    case eon
    case tibber
    case bixia
    case greenely
    case goteborgEnergi
    case skelleftea
    case telge
    case jamtkraft
    case other

    var id: String { rawValue }

    /// Brand names are not translated; only the catch-all is.
    var title: String {
        switch self {
        case .vattenfall: return "Vattenfall"
        case .fortum: return "Fortum"
        case .eon: return "E.ON"
        case .tibber: return "Tibber"
        case .bixia: return "Bixia"
        case .greenely: return "Greenely"
        case .goteborgEnergi: return "Göteborg Energi"
        case .skelleftea: return "Skellefteå Kraft"
        case .telge: return "Telge Energi"
        case .jamtkraft: return "Jämtkraft"
        case .other: return L10n.text("Other provider")
        }
    }
}

/// How an automatic contract settles the spot price. Since 2025-10-01 the market publishes
/// 15-minute prices; a "timpris" contract bills the average of the four quarters in each hour,
/// a "kvartspris" contract bills each quarter as published.
enum ElectricityPriceContract: String, CaseIterable, Codable, Sendable, Identifiable {
    case quarterHour
    case hourly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quarterHour: return L10n.text("15-minute price")
        case .hourly: return L10n.text("Hourly price")
        }
    }

    /// The price series as this contract bills it. Quarter-hour keeps the published
    /// intervals. Hourly folds sub-hour slots into time-weighted hour averages; an hour the
    /// series only partly covers keeps its original slots rather than inventing an average.
    func settle(_ points: [ElectricityPricePoint], calendar: Calendar = ElectricityPriceService.stockholmCalendar) -> [ElectricityPricePoint] {
        guard self == .hourly else { return points }
        var buckets: [Date: [ElectricityPricePoint]] = [:]
        var passthrough: [ElectricityPricePoint] = []
        for point in points {
            let length = point.endDate.timeIntervalSince(point.startDate)
            guard length > 0, length < 3_600,
                  let hour = calendar.dateInterval(of: .hour, for: point.startDate),
                  point.endDate <= hour.end else {
                passthrough.append(point)
                continue
            }
            buckets[hour.start, default: []].append(point)
        }
        var settled = passthrough
        for (hourStart, slots) in buckets {
            let seconds = slots.reduce(0.0) { $0 + $1.endDate.timeIntervalSince($1.startDate) }
            guard seconds >= 3_600 - 1 else {
                settled += slots
                continue
            }
            let weighted = slots.reduce(0.0) { $0 + $1.sekPerKwh * $1.endDate.timeIntervalSince($1.startDate) }
            settled.append(ElectricityPricePoint(
                startDate: hourStart, endDate: hourStart.addingTimeInterval(3_600), sekPerKwh: weighted / seconds
            ))
        }
        return settled.sorted { $0.startDate < $1.startDate }
    }
}

/// Everything needed to turn a stored spot cost into the figure on the user's bill. The
/// conversion is affine in the spot price, so history stores the raw market cost once and
/// every display re-derives the billed cost: changing the markup re-prices past sessions.
///
/// Retail price per kWh = (spot + markup + other charges) × VAT. Spot prices from
/// elprisetjustnu.se exclude VAT, energy tax and grid fees; the user supplies the markup
/// and whatever tax and grid fees they want counted, in öre/kWh as written on an invoice.
struct ElectricityRatePolicy: Equatable, Sendable {
    /// Swedish VAT on electricity, applied to the whole retail price including tax and grid fee.
    static let vatMultiplier = 1.25

    var mode: ElectricityRateMode
    var provider: ElectricityProvider
    var contract: ElectricityPriceContract
    var markupOrePerKwh: Double
    var otherChargesOrePerKwh: Double
    var includesVAT: Bool

    static let fixed = ElectricityRatePolicy(
        mode: .fixed, provider: .other, contract: .quarterHour, markupOrePerKwh: 0, otherChargesOrePerKwh: 0, includesVAT: true
    )

    var isAutomatic: Bool { mode == .automatic }

    /// Per-kWh amount added to the spot price, in SEK, before VAT.
    private var addersSek: Double { (markupOrePerKwh + otherChargesOrePerKwh) / 100 }
    private var vat: Double { includesVAT ? Self.vatMultiplier : 1 }

    /// SEK/kWh the user pays for energy drawn at a given spot price.
    func retailPrice(spotSekPerKwh: Double) -> Double {
        (spotSekPerKwh + addersSek) * vat
    }

    /// SEK for a session whose energy cost `spotCost` at raw spot prices.
    func retailCost(spotCost: Double, energyKwh: Double) -> Double {
        (spotCost + energyKwh * addersSek) * vat
    }

    /// What automatic figures are built from, for tooltips. Empty in fixed mode, which has no basis to name.
    var basisDescription: String {
        guard isAutomatic else { return "" }
        return L10n.format("spot price plus %@ markup", provider.title)
    }
}

/// The cost a session resolves to before any fallback is applied. Automatic mode prices from the
/// market cost when the session has one. Otherwise the stored cost wins, then the session's own
/// tariff. `nil` means the session has no price of its own.
private func ownSessionCost(
    policy: ElectricityRatePolicy,
    spotCost: Double?,
    energyKwh: Double,
    storedCost: Double?,
    tariffPricePerKwh: Double?
) -> Double? {
    if policy.isAutomatic, let spotCost {
        return policy.retailCost(spotCost: spotCost, energyKwh: energyKwh)
    }
    if let storedCost { return storedCost }
    return tariffPricePerKwh.map { $0 * energyKwh }
}

extension HistoricalChargingSession {
    /// The session's cost under the active policy. Automatic mode prices from the stored
    /// market cost; a session the spot series never covered keeps the fixed-rate figure,
    /// which `usedFallback` reports so totals can say how many sessions were not market-priced.
    func resolvedCost(policy: ElectricityRatePolicy, fallbackPricePerKwh: Double) -> (amount: Double, usedFallback: Bool) {
        if let own = ownSessionCost(policy: policy, spotCost: spotEstimatedCost, energyKwh: energyDeliveredKwh,
                                    storedCost: estimatedCost, tariffPricePerKwh: tariffPricePerKwh) {
            return (own, false)
        }
        return (fallbackPricePerKwh * energyDeliveredKwh, true)
    }
}

extension ChargingSession {
    /// Same contract as `HistoricalChargingSession.resolvedCost`, for the in-memory session
    /// the charging card and CSV export read. Returns nil only when no price is known at all.
    func resolvedCost(policy: ElectricityRatePolicy, fallbackPricePerKwh: Double?) -> Double? {
        if let own = ownSessionCost(policy: policy, spotCost: spotCost, energyKwh: kwhDelivered,
                                    storedCost: cost, tariffPricePerKwh: tariffPricePerKwh) {
            return own
        }
        return fallbackPricePerKwh.map { $0 * kwhDelivered }
    }
}
