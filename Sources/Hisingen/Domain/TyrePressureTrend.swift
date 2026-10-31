import Foundation

/// Reads stored tyre-pressure samples for a slow leak: one tyre losing pressure steadily while
/// the other three hold still. A leak in one tyre moves that tyre alone, while a cold snap or a
/// refill moves all four, so the stable-others condition is what separates the two.
enum TyrePressureTrend {
    struct SlowLeak: Equatable, Sendable {
        let position: TyrePosition
        let dropKilopascals: Double
        let span: TimeInterval
    }

    /// Fewer samples than this for the suspect tyre and the reading is too thin to act on.
    static let minimumSamples = 6
    static let minimumDrop: Double = 10
    static let minimumSpan: TimeInterval = 2 * 86_400
    /// How far each of the other three tyres may move across the window.
    static let stableChange: Double = 4
    /// The trailing window the rule looks at, ending at the newest sample.
    static let window: TimeInterval = 7 * 86_400

    /// The first tyre, in position order, that fits the slow-leak pattern in the trailing window.
    /// The other three must each have at least two samples in the window, so a tyre that went
    /// silent cannot count as stable.
    static func slowLeak(in records: [VehicleDatabase.TyrePressureRecord]) -> SlowLeak? {
        guard records.count >= minimumSamples, let latest = records.map(\.timestamp).max() else { return nil }
        let windowStart = latest.addingTimeInterval(-window)
        let recent = records.filter { $0.timestamp >= windowStart }
        let series = Dictionary(grouping: recent, by: \.position)
            .mapValues { $0.sorted { $0.timestamp < $1.timestamp } }

        for position in TyrePosition.allCases {
            guard let samples = series[position], samples.count >= minimumSamples,
                  let first = samples.first, let last = samples.last else { continue }
            let span = last.timestamp.timeIntervalSince(first.timestamp)
            let drop = first.kilopascals - last.kilopascals
            guard span >= minimumSpan, drop >= minimumDrop else { continue }

            let othersStable = TyrePosition.allCases.filter { $0 != position }.allSatisfy { other in
                guard let otherSamples = series[other], otherSamples.count >= 2,
                      let otherFirst = otherSamples.first, let otherLast = otherSamples.last else { return false }
                return abs(otherLast.kilopascals - otherFirst.kilopascals) < stableChange
            }
            if othersStable {
                return SlowLeak(position: position, dropKilopascals: drop, span: span)
            }
        }
        return nil
    }
}
