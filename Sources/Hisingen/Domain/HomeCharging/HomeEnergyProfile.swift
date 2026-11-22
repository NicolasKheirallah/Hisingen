import Foundation

/// Turns a charger's hourly energy readings into the intervals a session is priced by.
///
/// A charger that lists only whole sessions says how much arrived, not when. Its hourly
/// readings say when, to the hour. Pricing a session at the average price over the time the
/// cable was in charges the idle hours as if they had drawn energy.
enum HomeEnergyProfile {
    /// One reading: the energy the charger delivered in the hour starting at `start`.
    struct Hour: Equatable, Sendable {
        var start: Date
        var kwh: Double
    }

    static let hourLength: TimeInterval = 3_600
    /// Each hour is cut into pieces no longer than this, so the pricer reads it against the
    /// 15-minute prices. The energy inside an hour is spread evenly: the readings do not say more.
    static let slice: TimeInterval = 15 * 60

    static let note = "Energy by the hour from the charger's own readings, spread evenly within each hour"

    /// The session's intervals, or `nil` when the readings do not describe this session: no energy
    /// in its window, or a total more than 5% (at least 0.5 kWh) from the session's own, which is
    /// what a second session sharing an hour looks like. The readings are scaled to the session
    /// total so the priced energy matches the energy shown.
    static func intervals(from hours: [Hour], startedAt: Date, endedAt: Date, energyKwh: Double) -> [HomeEnergyInterval]? {
        guard endedAt > startedAt, energyKwh > 0 else { return nil }
        var segments: [(start: Date, end: Date, kwh: Double)] = []
        for hour in hours where hour.kwh > 0 {
            let start = max(hour.start, startedAt)
            let end = min(hour.start.addingTimeInterval(hourLength), endedAt)
            if end > start { segments.append((start, end, hour.kwh)) }
        }
        let total = segments.reduce(0) { $0 + $1.kwh }
        guard total > 0, abs(total - energyKwh) <= max(0.5, energyKwh * 0.05) else { return nil }
        let scale = energyKwh / total
        var intervals: [HomeEnergyInterval] = []
        for segment in segments.sorted(by: { $0.start < $1.start }) {
            let length = segment.end.timeIntervalSince(segment.start)
            let pieces = max(1, Int((length / slice).rounded(.up)))
            let pieceLength = length / Double(pieces)
            for index in 0..<pieces {
                let start = segment.start.addingTimeInterval(pieceLength * Double(index))
                intervals.append(HomeEnergyInterval(start: start, end: start.addingTimeInterval(pieceLength),
                                                    kwh: segment.kwh * scale / Double(pieces)))
            }
        }
        return intervals
    }
}
