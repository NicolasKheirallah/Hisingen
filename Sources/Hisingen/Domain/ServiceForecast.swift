import Foundation

/// Estimated date the next service falls due, from the remaining distance and the odometer
/// rate over the last 30 days. The vehicle's own time countdown caps the estimate, so the
/// earlier of the two wins. Nil whenever the distance or the rate is missing, because a date
/// without a rate would be a guess, not a forecast.
struct ServiceForecast: Equatable, Sendable {
    static let window: TimeInterval = 30 * 86_400
    static let minimumSpan: TimeInterval = 7 * 86_400

    let dueDate: Date
    let kmPerDay: Double

    static func estimate(distanceToServiceKm: Int?,
                         daysToService: Int?,
                         odometerSamples: [HistoryInsights.OdometerPoint],
                         now: Date = Date()) -> ServiceForecast? {
        guard let remainingKm = distanceToServiceKm, remainingKm > 0 else { return nil }

        let windowStart = now.addingTimeInterval(-window)
        let samples = odometerSamples
            .filter { $0.timestamp >= windowStart && $0.timestamp <= now }
            .sorted { $0.timestamp < $1.timestamp }
        guard let first = samples.first, let last = samples.last else { return nil }

        let span = last.timestamp.timeIntervalSince(first.timestamp)
        guard span >= minimumSpan else { return nil }
        let drivenKm = last.odometerKm - first.odometerKm
        guard drivenKm > 0 else { return nil }
        let kmPerDay = drivenKm / (span / 86_400)

        var dueDate = now.addingTimeInterval(Double(remainingKm) / kmPerDay * 86_400)
        if let days = daysToService, days > 0 {
            dueDate = min(dueDate, now.addingTimeInterval(Double(days) * 86_400))
        }
        return ServiceForecast(dueDate: dueDate, kmPerDay: kmPerDay)
    }
}
