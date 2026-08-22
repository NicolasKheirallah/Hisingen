import Foundation

/// General-purpose numeric helpers shared by history/trend computations. Pure and UI-free so
/// every formula stays independently unit-testable.
enum Statistics {

    /// The middle value of a sorted copy of `values`; the mean of the two middle values when
    /// the count is even. `nil` for an empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    /// Linear-interpolated percentile (0...100) of `values`, using the same "interpolate
    /// between ranks" convention as most statistics packages rather than nearest-rank, so a
    /// small sample doesn't jump discontinuously as new points arrive.
    static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        guard sorted.count > 1 else { return sorted[0] }
        let clamped = min(max(p, 0), 100)
        let rank = (clamped / 100) * Double(sorted.count - 1)
        let lowerIndex = Int(rank.rounded(.down))
        let upperIndex = Int(rank.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let weight = rank - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - weight) + sorted[upperIndex] * weight
    }

    struct LinearFit: Equatable {
        let slope: Double
        let intercept: Double
        func value(at x: Double) -> Double { slope * x + intercept }
    }

    /// Ordinary least-squares fit of `points`. `nil` when fewer than 2 points are given, or
    /// the x values don't vary at all (a slope isn't defined, and the OLS denominator would
    /// be zero).
    static func linearRegression(_ points: [(x: Double, y: Double)]) -> LinearFit? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumXX = points.reduce(0) { $0 + $1.x * $1.x }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > .ulpOfOne else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        let intercept = (sumY - slope * sumX) / n
        return LinearFit(slope: slope, intercept: intercept)
    }

    /// Pearson correlation coefficient of `pairs`, in -1...1. `nil` when there isn't enough
    /// spread in either axis to define one (e.g. every x value identical).
    static func pearsonCorrelation(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 2 else { return nil }
        let n = Double(pairs.count)
        let sumX = pairs.reduce(0) { $0 + $1.0 }
        let sumY = pairs.reduce(0) { $0 + $1.1 }
        let sumXY = pairs.reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = pairs.reduce(0) { $0 + $1.0 * $1.0 }
        let sumYY = pairs.reduce(0) { $0 + $1.1 * $1.1 }
        let numerator = n * sumXY - sumX * sumY
        let denominator = ((n * sumXX - sumX * sumX) * (n * sumYY - sumY * sumY)).squareRoot()
        guard denominator > .ulpOfOne else { return nil }
        return numerator / denominator
    }

    /// Trailing simple moving average over `windowSize` elements. The first `windowSize - 1`
    /// outputs average over however many points are available so far rather than being
    /// dropped, so the smoothed series stays the same length as the input (important for
    /// charts, which pair each smoothed value back up with its original x-axis point).
    static func movingAverage(_ values: [Double], windowSize: Int) -> [Double] {
        guard windowSize > 1, !values.isEmpty else { return values }
        var result: [Double] = []
        result.reserveCapacity(values.count)
        var window: [Double] = []
        window.reserveCapacity(windowSize)
        var windowSum = 0.0
        for value in values {
            window.append(value)
            windowSum += value
            if window.count > windowSize {
                windowSum -= window.removeFirst()
            }
            result.append(windowSum / Double(window.count))
        }
        return result
    }
}
