import Foundation

/// A fee the reader's charger or charging location charges for leaving a car plugged in after
/// the charge has finished. The rule is user data, so it is applied at read time to the stored
/// session: changing the rule re-prices past sessions the same way the rate policy does.
struct ChargingOverstayRule: Codable, Equatable, Identifiable, Sendable {
    /// What a rule is filed against. A charger rule beats a location rule when both match, because
    /// the charger is the more specific fact.
    enum Scope: String, Codable, CaseIterable, Sendable {
        case charger
        case location
    }

    enum Unit: String, Codable, CaseIterable, Sendable {
        case perHour = "per_hour"
        case perMinute = "per_minute"
    }

    var id: String
    var scope: Scope
    /// Charger identifier for `.charger`; the session's location name for `.location`.
    var target: String
    var graceMinutes: Int
    var amount: Double
    var unit: Unit
    var currencySymbol: String

    init(id: String = UUID().uuidString, scope: Scope, target: String, graceMinutes: Int,
         amount: Double, unit: Unit, currencySymbol: String) {
        self.id = id
        self.scope = scope
        self.target = target
        self.graceMinutes = graceMinutes
        self.amount = amount
        self.unit = unit
        self.currencySymbol = currencySymbol
    }
}

/// A resolved overstay fee for one stored session. `amount` is never added to the session's
/// energy cost: the rate policy owns that figure, and a parking-style charge belongs on its own
/// line. Nothing here converts currency either.
struct ChargingOverstayFee: Equatable, Sendable {
    /// Timestamp noise must not turn a session that ended level with the cable coming out into a
    /// billable minute. Anything shorter than this is treated as no overstay at all.
    static let minimumBillableOverstay: TimeInterval = 30

    var rule: ChargingOverstayRule
    var chargeFinishedAt: Date
    var pluggedUntil: Date
    var overstay: TimeInterval
    var billableMinutes: Int
    var amount: Double

    /// A fee only exists where the stored row proves the cable stayed in past the finish. The
    /// charger's session end is that evidence; a session with no charger record keeps no
    /// plug-out time, so it earns no fee rather than an assumed one. Charger timestamps can
    /// understate a late unplug (some vendors end the session at charge complete), which makes
    /// the fee smaller than the real one, never larger.
    static func resolve(session: HistoricalChargingSession,
                        rules: [ChargingOverstayRule]) -> ChargingOverstayFee? {
        guard session.lifecycleState == .completed || session.lifecycleState == .interrupted,
              let finished = session.endedAt,
              let wallbox = session.wallbox,
              let pluggedUntil = wallbox.endedAt,
              pluggedUntil > finished,
              let rule = rule(for: session, in: rules),
              rule.amount.isFinite, rule.amount > 0 else { return nil }

        let overstay = pluggedUntil.timeIntervalSince(finished)
        let minutes = billableMinutes(overstay: overstay, graceMinutes: rule.graceMinutes)
        guard minutes > 0 else { return nil }
        let fee = amount(rule: rule, billableMinutes: minutes)
        guard fee.isFinite, fee > 0 else { return nil }
        return ChargingOverstayFee(
            rule: rule, chargeFinishedAt: finished, pluggedUntil: pluggedUntil,
            overstay: overstay, billableMinutes: minutes, amount: fee
        )
    }

    /// Grace time is free; every started minute after it is billed. Partial minutes round up, as
    /// a charger's own billing does, with `minimumBillableOverstay` absorbing timestamp noise.
    static func billableMinutes(overstay: TimeInterval, graceMinutes: Int) -> Int {
        let billable = overstay - TimeInterval(max(0, graceMinutes) * 60)
        guard billable >= minimumBillableOverstay else { return 0 }
        return Int((billable / 60).rounded(.up))
    }

    static func amount(rule: ChargingOverstayRule, billableMinutes: Int) -> Double {
        guard billableMinutes > 0 else { return 0 }
        switch rule.unit {
        case .perMinute: return rule.amount * Double(billableMinutes)
        case .perHour: return rule.amount * Double(billableMinutes) / 60
        }
    }

    static func rule(for session: HistoricalChargingSession,
                     in rules: [ChargingOverstayRule]) -> ChargingOverstayRule? {
        if let chargerID = session.wallbox?.chargerID, !chargerID.isEmpty,
           let chargerRule = rules.first(where: { $0.scope == .charger && $0.target == chargerID }) {
            return chargerRule
        }
        let location = normalized(session.locationName ?? "")
        guard !location.isEmpty else { return nil }
        return rules.first { $0.scope == .location && normalized($0.target) == location }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

extension ChargingOverstayRule.Unit {
    var displayName: String {
        switch self {
        case .perHour: return L10n.text("Per hour")
        case .perMinute: return L10n.text("Per minute")
        }
    }
}

extension ChargingOverstayRule {
    /// The rule's rate in the compact form a price list uses, e.g. "5.00 kr/h".
    var rateText: String {
        let money = Format.currency(amount, symbol: currencySymbol)
        return unit == .perHour ? "\(money)/h" : "\(money)/min"
    }
}
