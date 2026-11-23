import Foundation

/// How much of a planned charge the reader's own panels could supply, from the estimated output
/// the solar forecast already shows. It describes the window the planner picked and never moves
/// it: the plan is chosen on price alone, because what the reader would earn for energy they do
/// not use is not something Hisingen knows.
enum SolarCoverage {
    /// The share of `energyKwh` that estimated panel output could supply during `window`, from 0
    /// to 1. Each hour counts at most the charger's power, since the car cannot take more than
    /// the charger delivers, and the rest of the house is not subtracted: that load is unknown,
    /// so the figure is an upper bound and the wording says "before other loads".
    ///
    /// Nil whenever the answer would be a guess: no energy to deliver, a window the forecast does
    /// not cover from start to end, or an hour inside it without a tilted-plane figure.
    nonisolated static func fraction(forecast: SolarForecast,
                                     array: SolarArray,
                                     window: DateInterval,
                                     chargerKw: Double,
                                     energyKwh: Double) -> Double? {
        guard energyKwh > 0, chargerKw > 0, chargerKw.isFinite, energyKwh.isFinite,
              window.duration > 0 else { return nil }

        var coveredSeconds = 0.0
        var solarKwh = 0.0
        for point in forecast.points {
            let overlap = window.intersection(with: DateInterval(start: point.start, end: point.end))
            guard let overlap, overlap.duration > 0 else { continue }
            guard let tilted = point.tiltedWattsPerSquareMeter else { return nil }
            let kw = min(array.estimatedKw(tiltedWattsPerSquareMeter: tilted), chargerKw)
            solarKwh += kw * overlap.duration / 3_600
            coveredSeconds += overlap.duration
        }
        // Whole-second slack: a window that ends on a quarter hour overlaps hour boundaries exactly.
        guard coveredSeconds >= window.duration - 1 else { return nil }
        return min(1, solarKwh / energyKwh)
    }
}
