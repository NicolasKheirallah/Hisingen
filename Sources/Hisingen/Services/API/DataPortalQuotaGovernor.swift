import Foundation

/// Paces scheduled Data Portal refreshes so the day's projected spend stays under a safety
/// budget, instead of running at full cadence until the local hard stop closes the portal
/// until UTC midnight.
///
/// Pure arithmetic over the counter's current value and the clock, so the policy is testable
/// without a network, a timer or UserDefaults. Manual refreshes never pass through here; they
/// still run and count against the same meter.
enum DataPortalQuotaGovernor {
    /// Reads one full refresh spends in `PolestarDataPortalAPI.performFetch` (14 GETs).
    static let callsPerRefresh = PolestarPortalFetchPlan.maximumCost
    /// Share of the daily limit the scheduler plans to spend. The remainder absorbs manual
    /// refreshes, garage scans and token grants that are not part of the schedule.
    static let safetyFraction = 0.9
    /// Never schedule a retry tighter than this while the budget is spent, so a reset that is
    /// seconds away cannot spin the scheduler.
    static let minimumExhaustedWait: TimeInterval = 60

    struct Projection: Equatable, Sendable {
        let used: Int
        let projectedEndOfDay: Int
        let resetDate: Date
    }

    struct Pacing: Equatable, Sendable {
        /// The delay before the next scheduled refresh. At least the requested interval, except
        /// when the budget is spent: then it is the wait until the quota day resets.
        let interval: TimeInterval
        let isStretched: Bool
        let projection: Projection
    }

    /// The paced interval for the next scheduled refresh.
    ///
    /// - Parameters:
    ///   - requestedInterval: the cadence the app would use without a quota constraint.
    ///   - used: calls already counted today.
    ///   - secondsUntilReset: time until the quota day rolls over at UTC midnight.
    ///   - now: the clock reading the reset date is anchored to.
    ///   - dailyLimit: the portal's daily allowance.
    static func pace(requestedInterval: TimeInterval,
                     used: Int,
                     secondsUntilReset: TimeInterval,
                     now: Date,
                     callsPerRefresh: Int = callsPerRefresh,
                     dailyLimit: Int = PolestarDataPortalAPI.dailyCallLimit) -> Pacing {
        let spent = max(0, used)
        let reset = max(0, secondsUntilReset)
        let perRefresh = max(1, callsPerRefresh)
        let requested = max(1, requestedInterval)
        let budget = Int(Double(dailyLimit) * safetyFraction)
        let resetDate = now.addingTimeInterval(reset)

        func projectedEnd(at interval: TimeInterval) -> Int {
            let refreshes = Int(reset / interval)
            return spent + refreshes * perRefresh
        }

        let atRequested = projectedEnd(at: requested)
        if atRequested <= budget {
            return Pacing(
                interval: requested,
                isStretched: false,
                projection: Projection(used: spent, projectedEndOfDay: atRequested, resetDate: resetDate)
            )
        }

        let affordable = (budget - spent) / perRefresh
        guard affordable > 0 else {
            // The budget cannot fund another refresh before reset. Sleep until the day rolls over.
            let wait = max(reset, minimumExhaustedWait)
            return Pacing(
                interval: wait,
                isStretched: wait > requested,
                projection: Projection(used: spent, projectedEndOfDay: spent, resetDate: resetDate)
            )
        }

        let stretched = max(requested, reset / Double(affordable))
        return Pacing(
            interval: stretched,
            isStretched: stretched > requested,
            projection: Projection(used: spent,
                                   projectedEndOfDay: projectedEnd(at: stretched),
                                   resetDate: resetDate)
        )
    }

    /// Seconds from `now` to the next UTC midnight, the boundary the portal's daily counter
    /// resets on.
    static func secondsUntilReset(now: Date) -> TimeInterval {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let midnight = utcCalendar.startOfDay(
            for: utcCalendar.date(byAdding: .day, value: 1, to: now) ?? now)
        return midnight.timeIntervalSince(now)
    }
}
