import Foundation

/// Turns a vehicle's telemetry rows into trips.
///
/// Pure on purpose: the segmentation rules – how much movement counts as a journey, which
/// deltas are nonsense, and how long a silence ends one – are testable without a database.
/// `VehicleHistoryLedger.derivedTrips` fetches the rows and delegates here, so the SQL stays
/// where it is and this stays a rule.
enum TripSegmentation {
    /// Below this a delta is odometer noise rather than movement.
    static let minimumDistanceKm = 0.05
    /// Above this the delta is a rollover or a misread, not a journey.
    static let maximumDistanceKm = 2_000.0
    /// Telemetry this far apart starts a new trip.
    static let maximumGap: TimeInterval = 45 * 60

    /// `records` must be in ascending timestamp order – the order a journey reads in.
    static func trips(
        from records: [HistoricalTelemetryRecord],
        vin: String,
        limit: Int
    ) -> [TripHistoryEntry] {
        var trips: [TripHistoryEntry] = []
        var segmentStart: HistoricalTelemetryRecord?
        var segmentEnd: HistoricalTelemetryRecord?
        var segmentDistance = 0.0
        var consumptionTotal = 0.0
        var consumptionCount = 0
        var temperatureTotal = 0.0
        var temperatureCount = 0

        func appendSegment() {
            guard let start = segmentStart, let end = segmentEnd,
                  segmentDistance >= minimumDistanceKm else { return }
            trips.append(TripHistoryEntry(
                id: "\(start.id)-\(end.id)", vin: vin,
                startedAt: start.timestamp, endedAt: end.timestamp,
                distanceKm: segmentDistance,
                averageConsumption: consumptionCount > 0 ? consumptionTotal / Double(consumptionCount) : nil,
                ambientTemperatureCelsius: temperatureCount > 0 ? temperatureTotal / Double(temperatureCount) : nil,
                startLatitude: start.latitude, startLongitude: start.longitude,
                endLatitude: end.latitude, endLongitude: end.longitude
            ))
        }

        func clearSegment() {
            segmentStart = nil
            segmentEnd = nil
            segmentDistance = 0
            consumptionTotal = 0
            consumptionCount = 0
            temperatureTotal = 0
            temperatureCount = 0
        }

        for (start, end) in zip(records, records.dropFirst()) {
            // Odometer first, then the trip meters; each delta is accepted only inside
            // the plausible band. Trip-meter resets (next < current) yield nil so the
            // interval falls back to another source instead of inventing distance.
            let odometerDelta: Double? = {
                guard let current = start.odometerKm, let next = end.odometerKm else { return nil }
                let delta = next - current
                return delta >= 0 ? delta : nil
            }()
            let automaticDelta: Double? = {
                guard let current = start.tripAutomaticKm, let next = end.tripAutomaticKm else { return nil }
                return next >= current ? next - current : nil
            }()
            let manualDelta: Double? = {
                guard let current = start.tripManualKm, let next = end.tripManualKm else { return nil }
                return next >= current ? next - current : nil
            }()
            // Prefer a consistent source within a segment: once a segment has started,
            // keep using its source instead of mixing baselines per interval.
            let distance = [odometerDelta, automaticDelta, manualDelta]
                .compactMap { $0 }
                .first { $0 >= minimumDistanceKm && $0 < maximumDistanceKm }
            let gap = end.timestamp.timeIntervalSince(start.timestamp)
            guard let distance, gap >= 0, gap <= maximumGap else {
                appendSegment()
                clearSegment()
                continue
            }
            // Zero-duration duplicates with real movement are quantization noise, not a new
            // trip: absorb the distance into the open segment instead of splitting.
            if gap == 0 {
                if segmentStart == nil { segmentStart = start }
                segmentEnd = end
                segmentDistance += distance
                continue
            }
            if segmentStart == nil { segmentStart = start }
            segmentEnd = end
            segmentDistance += distance
            if let value = end.averageConsumption ?? start.averageConsumption {
                consumptionTotal += value
                consumptionCount += 1
            }
            if let value = end.ambientTemperatureCelsius ?? start.ambientTemperatureCelsius {
                temperatureTotal += value
                temperatureCount += 1
            }
        }
        appendSegment()
        return Array(trips.suffix(limit).reversed())
    }
}
