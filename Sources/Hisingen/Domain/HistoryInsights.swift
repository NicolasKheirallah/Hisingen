import Foundation

/// Pure presentation-support computations for the History dashboard: turning persisted
/// telemetry rows into chart-ready series. Deliberately UI-free so every filter bound,
/// ordering rule and downsampling decision stays unit-testable.
enum HistoryInsights {

    struct ChargingCurvePoint: Identifiable, Equatable {
        let id: Int64
        let timestamp: Date
        let soc: Double
        let powerKw: Double?
    }

    struct EfficiencyPoint: Identifiable, Equatable {
        let id: Int64
        let timestamp: Date
        /// kWh per 100 km — the canonical internal unit. Presentation converts on display.
        let kwhPer100Km: Double
    }

    struct OdometerPoint: Identifiable, Equatable {
        let id: Int64
        let timestamp: Date
        let odometerKm: Double
    }

    /// Sane long-term consumption bounds in kWh/100 km. Below ~2 the vehicle is coasting or
    /// regenerating rather than consuming; above 60 is a data error, not a driving style.
    static let efficiencyBounds = 2.0...60.0
    /// A charging sample whose power exceeds this (kW) is treated as a telemetry glitch.
    static let maxPlausiblePowerKw = 500.0

    /// Builds a chronological charge curve from a session's samples.
    ///
    /// - Filters impossible readings (non-positive SoC, absurd power) instead of letting one
    ///   glitched poll stretch a chart axis.
    /// - Downsamples to `maximumPoints` while always keeping the first and last sample, so a
    ///   week-long session renders as fast as a one-hour one without changing its shape.
    static func chargingCurve(from samples: [HistoricalChargingSample],
                              maximumPoints: Int = 160) -> [ChargingCurvePoint] {
        let chronological = samples
            .filter { $0.soc > 0 && $0.soc <= 100 }
            .filter { $0.powerKw.map { $0 >= 0 && $0 <= maxPlausiblePowerKw } ?? true }
            .sorted { $0.timestamp < $1.timestamp }
        guard chronological.isEmpty == false else { return [] }
        guard chronological.count > maximumPoints, maximumPoints >= 2 else {
            return chronological.enumerated().map { offset, item in
                ChargingCurvePoint(id: Int64(offset + 1), timestamp: item.timestamp,
                                   soc: item.soc, powerKw: item.powerKw)
            }
        }
        let stride = Double(chronological.count - 1) / Double(maximumPoints - 1)
        var picked: [HistoricalChargingSample] = []
        for index in 0..<maximumPoints {
            picked.append(chronological[min(Int((Double(index) * stride).rounded()),
                                            chronological.count - 1)])
        }
        return picked.enumerated().map { offset, item in
            ChargingCurvePoint(id: Int64(offset + 1), timestamp: item.timestamp,
                               soc: item.soc, powerKw: item.powerKw)
        }
    }

    /// Long-term consumption trend in kWh/100 km, oldest first. Readings outside
    /// `efficiencyBounds` are dropped; consecutive identical vehicle-reported values collapse
    /// to one point so a parked week renders as a flat line segment, not a dense cluster.
    static func efficiencyTrend(from records: [HistoricalTelemetryRecord]) -> [EfficiencyPoint] {
        var points: [EfficiencyPoint] = []
        let chronological = records.sorted { $0.timestamp < $1.timestamp }
        for record in chronological {
            guard let value = record.averageConsumption,
                  efficiencyBounds.contains(value) else { continue }
            // `<=`, not `<`: a reading exactly 0.05 kWh/100km from the last kept point is still
            // "within tolerance," not just outside it — the boundary case matters here since
            // real vehicle-reported consumption values are often rounded to two decimal places.
            if let last = points.last, abs(last.kwhPer100Km - value) <= 0.05,
               record.timestamp.timeIntervalSince(last.timestamp) < 6 * 3_600 {
                continue
            }
            points.append(EfficiencyPoint(id: record.id, timestamp: record.timestamp,
                                          kwhPer100Km: value))
        }
        return points
    }

    /// Odometer growth over time, oldest first. Non-positive and clearly-reset readings are
    /// dropped so an odometer rollover or provider glitch cannot draw a cliff in the chart.
    static func odometerTrend(from records: [HistoricalTelemetryRecord]) -> [OdometerPoint] {
        var points: [OdometerPoint] = []
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let value = record.odometerKm, value > 0 else { continue }
            if let previous = points.last?.odometerKm,
               value < previous * 0.5 || abs(value - previous) > 1_000_000 {
                continue
            }
            points.append(OdometerPoint(id: record.id, timestamp: record.timestamp,
                                        odometerKm: value))
        }
        return points
    }

    /// Mean of an efficiency series, or nil when empty.
    static func averageEfficiency(of points: [EfficiencyPoint]) -> Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.kwhPer100Km } / Double(points.count)
    }

    /// Distance driven between the first and last odometer observation, when both exist.
    static func distanceCovered(from points: [OdometerPoint]) -> Double? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let delta = last.odometerKm - first.odometerKm
        return delta >= 0 ? delta : nil
    }
}
