import Foundation

/// Decides when the price the reader pays crosses the level they set. The crossing is read from
/// the series itself rather than from the previous poll, so a relaunch in the middle of an
/// expensive hour does not announce it twice: a crossing exists at the boundary where a slot at
/// or above the level follows a slot below it.
///
/// The reader is notified for the slot running now, or for the next full hour. A volatile quarter
/// that jumps back and forth produces a crossing per jump, which is why the caller passes the
/// quiet period and the slot it last announced.
enum PriceThresholdAlert {
    enum Window: String, Equatable, Sendable {
        case current
        case nextHour = "next_hour"
    }

    struct Crossing: Equatable, Sendable {
        var window: Window
        var slotStart: Date
        var slotEnd: Date
        var price: Double
    }

    enum Decision: Equatable, Sendable {
        case alert(Crossing)
        /// No level has been entered yet, so there is nothing to compare against.
        case thresholdNotSet
        /// The series is empty, does not cover the current instant, or has a gap where the
        /// comparison would need a price. A missing price is never read as zero.
        case noSeries
        case belowThreshold
        /// This slot's crossing has already been announced; a later tick in the same slot stays quiet.
        case alreadyAnnounced(slotStart: Date)
        case quietPeriod(since: Date, until: Date)
    }

    static let defaultQuietPeriod: TimeInterval = 60 * 60

    /// The level is compared against what the reader actually pays: the provider's all-in price
    /// as it stands, or a market price with the reader's markup, charges and VAT applied by the
    /// rate policy. `prices` must therefore stay the raw series.
    static func evaluate(
        prices: [ElectricityPricePoint],
        policy: ElectricityRatePolicy,
        allIn: Bool,
        gridTariff: GridTariff = .none,
        now: Date,
        threshold: Double,
        quietPeriod: TimeInterval = defaultQuietPeriod,
        lastAlertAt: Date? = nil,
        lastAlertedSlotStart: Date? = nil,
        calendar: Calendar = ElectricityPriceService.stockholmCalendar
    ) -> Decision {
        guard threshold.isFinite, threshold > 0 else { return .thresholdNotSet }

        let settled = policy.contract.settle(prices, calendar: calendar)
        let slots = settled.compactMap { point -> RateSlot? in
            guard point.sekPerKwh.isFinite, point.endDate > point.startDate else { return nil }
            let price = allIn ? point.sekPerKwh : policy.retailPrice(for: point, gridTariff: gridTariff)
            guard price.isFinite else { return nil }
            return RateSlot(start: point.startDate, end: point.endDate, price: price)
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        guard !slots.isEmpty,
              let currentSlot = slots.filter({ $0.start <= now && $0.end > now })
                .max(by: { $0.start < $1.start }),
              let hour = calendar.dateInterval(of: .hour, for: now) else { return .noSeries }

        // The current hour, and the hour before it, must be fully covered before the app can say
        // the price rose from below the level to above it.
        let previousHour = DateInterval(start: hour.start.addingTimeInterval(-3_600), end: hour.start)
        let currentHour = DateInterval(start: hour.start, end: min(now, hour.end))
        let nextHour = DateInterval(start: hour.end, end: hour.end.addingTimeInterval(3_600))

        if currentSlot.price >= threshold,
           let previousAverage = average(slots, over: previousHour), previousAverage < threshold {
            return decide(
                Crossing(window: .current, slotStart: hour.start, slotEnd: hour.end, price: currentSlot.price),
                now: now, quietPeriod: quietPeriod,
                lastAlertAt: lastAlertAt, lastAlertedSlotStart: lastAlertedSlotStart
            )
        }

        if let nextAverage = average(slots, over: nextHour), nextAverage >= threshold,
           let currentAverage = average(slots, over: currentHour), currentAverage < threshold {
            return decide(
                Crossing(window: .nextHour, slotStart: nextHour.start, slotEnd: nextHour.end, price: nextAverage),
                now: now, quietPeriod: quietPeriod,
                lastAlertAt: lastAlertAt, lastAlertedSlotStart: lastAlertedSlotStart
            )
        }

        return .belowThreshold
    }

    private struct RateSlot {
        var start: Date
        var end: Date
        var price: Double
    }

    /// The time-weighted price over a whole window, or nil when the series does not cover every
    /// second of it. A partly covered window would need a price the app does not have.
    private static func average(_ slots: [RateSlot], over window: DateInterval) -> Double? {
        let duration = window.duration
        guard duration > 0 else { return nil }
        var covered = 0.0
        var cost = 0.0
        for slot in slots {
            let overlap = min(window.end, slot.end).timeIntervalSince(max(window.start, slot.start))
            guard overlap > 0 else { continue }
            covered += overlap
            cost += overlap * slot.price
        }
        guard abs(covered - duration) <= 1 else { return nil }
        return cost / covered
    }

    private static func decide(_ crossing: Crossing, now: Date, quietPeriod: TimeInterval,
                               lastAlertAt: Date?, lastAlertedSlotStart: Date?) -> Decision {
        if let lastAlertedSlotStart, abs(lastAlertedSlotStart.timeIntervalSince(crossing.slotStart)) < 1 {
            return .alreadyAnnounced(slotStart: crossing.slotStart)
        }
        if let lastAlertAt, quietPeriod > 0 {
            let until = lastAlertAt.addingTimeInterval(quietPeriod)
            if now >= lastAlertAt, now < until {
                return .quietPeriod(since: lastAlertAt, until: until)
            }
        }
        return .alert(crossing)
    }
}
