import Foundation

/// Adds up how much time the price slots of a period sit at each of Tibber's levels, from the
/// levels the price points already carry: the price feed is not asked again. A slot without a
/// level counts nowhere, so a feed that gives no levels answers an empty tally and never a set of
/// zeros.
enum TibberPriceLevelTally {
    /// Hours at each level across the whole period. A quarter-hourly feed reaches an hour in four
    /// slots, so the fractions are the hours, not slot counts.
    static func hours(_ points: [HomePricePoint]) -> [TibberPriceLevel: Double] {
        var hours: [TibberPriceLevel: Double] = [:]
        for point in points {
            guard let level = point.level else { continue }
            hours[level, default: 0] += point.end.timeIntervalSince(point.start) / 3_600
        }
        return hours
    }

    /// The same tally split by calendar day, oldest day first, each keyed by that day's start in
    /// the given calendar.
    static func perDay(_ points: [HomePricePoint], calendar: Calendar = .current) -> [(day: Date, hours: [TibberPriceLevel: Double])] {
        var days: [Date: [TibberPriceLevel: Double]] = [:]
        for point in points {
            guard let level = point.level else { continue }
            days[calendar.startOfDay(for: point.start), default: [:]][level, default: 0] += point.end.timeIntervalSince(point.start) / 3_600
        }
        return days.sorted { $0.key < $1.key }.map { (day: $0.key, hours: $0.value) }
    }
}
