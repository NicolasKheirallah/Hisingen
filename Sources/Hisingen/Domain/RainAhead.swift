import Foundation

/// Rain that is about to start, read from the next quarter hours of the forecast. It exists to warn
/// someone whose windows are open before the first drops, not after, so it looks only a short way
/// ahead: a forecast of rain two hours away is not a reason to walk out to the car.
struct RainAhead: Equatable, Sendable {
    /// How far ahead a wet quarter hour counts.
    static let lookahead: TimeInterval = 45 * 60
    /// Dry spells under this, in mm per quarter hour, are drizzle the forecast cannot call.
    static let thresholdMillimetres = 0.1

    /// When the rain starts, or `now` when a wet quarter hour is already under way.
    let startsAt: Date
    let millimetres: Double

    /// Whole minutes until the rain, at least 1 so the notice never says "within 0 min".
    func minutes(from now: Date) -> Int {
        max(1, Int((startsAt.timeIntervalSince(now) / 60).rounded(.up)))
    }

    /// The first wet quarter hour that has not ended by `now` and starts inside the lookahead.
    static func next(in intervals: [PrecipitationInterval], after now: Date) -> RainAhead? {
        let limit = now.addingTimeInterval(lookahead)
        return intervals
            .filter { $0.end > now && $0.start < limit && $0.millimetres >= thresholdMillimetres }
            .min { $0.start < $1.start }
            .map { RainAhead(startsAt: max($0.start, now), millimetres: $0.millimetres) }
    }
}
