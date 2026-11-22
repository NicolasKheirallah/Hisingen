import Foundation

/// Estimates the energy a Volvo drew since its last completed charge, from two sources the
/// vehicle API supplies separately: the car's own since-charge consumption figure and the
/// distance driven since that charge ended (charging-ledger session end × nearest recorded
/// odometer at that moment). Hisingen labels the result as an estimate; the car's own
/// energy-since-charge reading, when the car supplies one, always wins.
enum VolvoChargeEnergyEstimator {
    /// Beyond this distance since the charge ended, the estimate stops meaning anything:
    /// days of driving between odometer samples would dominate the answer.
    static let maximumTrustedDistanceKm: Double = 1_500

    /// How far from a session's end an odometer sample may sit and still stand in for the
    /// odometer at that moment. A sleeping car reports rarely; six hours keeps one honest.
    static let sampleTolerance: TimeInterval = 6 * 60 * 60

    /// kWh/100 km × km = kWh/100, × 10 = Wh.
    static func energyUsedSinceChargeWh(
        consumptionSinceChargeKwhPer100Km: Double?,
        odometerKmNow: Double?,
        odometerKmAtLastChargeEnd: Double?
    ) -> Double? {
        guard let consumption = consumptionSinceChargeKwhPer100Km,
              let odometerNow = odometerKmNow, let odometerAtEnd = odometerKmAtLastChargeEnd,
              consumption >= 0, odometerAtEnd >= 0, odometerAtEnd <= odometerNow,
              odometerNow - odometerAtEnd <= maximumTrustedDistanceKm
        else { return nil }
        return consumption * (odometerNow - odometerAtEnd) * 10
    }

    /// The recorded odometer closest in time to `date`, nil when no sample carrying an
    /// odometer value sits within the tolerance.
    static func odometerKm(
        in records: [HistoricalTelemetryRecord], nearest date: Date
    ) -> Double? {
        records
            .compactMap { record -> (kilometers: Double, distance: TimeInterval)? in
                guard let kilometers = record.odometerKm else { return nil }
                return (kilometers, abs(record.timestamp.timeIntervalSince(date)))
            }
            .filter { $0.distance <= sampleTolerance }
            .min(by: { $0.distance < $1.distance })?
            .kilometers
    }
}
