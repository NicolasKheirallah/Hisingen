import Foundation

/// The home-versus-public split of stored charging cost. One pure calculation, so the total in
/// the trends card and its two lines cannot disagree: `totalAmount` is the sum of the buckets
/// by construction.
struct ChargingCostSplit: Equatable, Sendable {
    struct Bucket: Equatable, Sendable {
        var amount: Double = 0
        var energyKwh: Double = 0
        var sessionCount: Int = 0
    }

    var home = Bucket()
    var publicCharging = Bucket()
    var currency: String
    var fallbackSessions: Int = 0

    var totalAmount: Double { home.amount + publicCharging.amount }
    var totalEnergyKwh: Double { home.energyKwh + publicCharging.energyKwh }
    var totalSessionCount: Int { home.sessionCount + publicCharging.sessionCount }

    /// The split for one set of sessions under the reader's rate policy. Returns nil when the
    /// sessions span more than one currency: adding kronor to euro would be a made-up number.
    static func resolve(
        sessions: [HistoricalChargingSession],
        policy: ElectricityRatePolicy,
        fallbackPricePerKwh: Double,
        defaultCurrency: String
    ) -> ChargingCostSplit? {
        let currencies = Set(sessions.map { session -> String in
            let saved = session.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (saved?.isEmpty == false ? saved : nil) ?? defaultCurrency
        })
        guard currencies.count <= 1 else { return nil }

        var split = ChargingCostSplit(currency: currencies.first ?? defaultCurrency)
        for session in sessions {
            let resolved = session.resolvedCost(policy: policy, fallbackPricePerKwh: fallbackPricePerKwh)
            if resolved.usedFallback { split.fallbackSessions += 1 }
            let energy = session.energyDeliveredKwh
            switch session.place {
            case .home:
                split.home.amount += resolved.amount
                split.home.energyKwh += energy
                split.home.sessionCount += 1
            case .publicCharging:
                split.publicCharging.amount += resolved.amount
                split.publicCharging.energyKwh += energy
                split.publicCharging.sessionCount += 1
            }
        }
        return split
    }
}
