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

    private enum DistanceSource {
        case odometer
        case automatic
        case manual
    }

    /// `records` must be in ascending timestamp order – the order a journey reads in.
    static func trips(
        from records: [HistoricalTelemetryRecord],
        vin: String,
        limit: Int,
        includeReconciledGaps: Bool = false
    ) -> [TripHistoryEntry] {
        var trips: [TripHistoryEntry] = []
        var segmentStart: HistoricalTelemetryRecord?
        var segmentEnd: HistoricalTelemetryRecord?
        var segmentDistance = 0.0
        var distanceSource: DistanceSource?
        var temperatureTotal = 0.0
        var temperatureCount = 0

        func finishSegment() {
            if let start = segmentStart, let end = segmentEnd, segmentDistance >= minimumDistanceKm {
                trips.append(TripHistoryEntry(
                    id: "\(start.id)-\(end.id)", vin: vin,
                    startedAt: start.timestamp, endedAt: end.timestamp,
                    distanceKm: segmentDistance,
                    // The ledger's consumption column carries the vehicle's long-term average.
                    averageConsumption: nil,
                    ambientTemperatureCelsius: temperatureCount > 0 ? temperatureTotal / Double(temperatureCount) : nil,
                    startLatitude: start.latitude, startLongitude: start.longitude,
                    endLatitude: end.latitude, endLongitude: end.longitude
                ))
            }
            segmentStart = nil
            segmentEnd = nil
            segmentDistance = 0
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

            let gap = end.timestamp.timeIntervalSince(start.timestamp)
            guard gap >= 0, gap <= maximumGap else {
                finishSegment()
                distanceSource = nil
                if includeReconciledGaps, gap > maximumGap,
                   let odoGap = odometerDelta, odoGap >= 1.0, odoGap < maximumDistanceKm {
                    let avgTemp: Double? = switch (start.ambientTemperatureCelsius, end.ambientTemperatureCelsius) {
                    case let (a?, b?): (a + b) / 2
                    case let (a?, nil): a
                    case let (nil, b?): b
                    case (nil, nil): nil
                    }
                    trips.append(TripHistoryEntry(
                        id: "\(start.id)-\(end.id)-gap",
                        vin: vin,
                        startedAt: start.timestamp,
                        endedAt: end.timestamp,
                        distanceKm: odoGap,
                        averageConsumption: nil,
                        ambientTemperatureCelsius: avgTemp,
                        startLatitude: start.latitude,
                        startLongitude: start.longitude,
                        endLatitude: end.latitude,
                        endLongitude: end.longitude,
                        isReconciledGap: true
                    ))
                }
                continue
            }

            let deltas: [(source: DistanceSource, distance: Double)] = [
                (DistanceSource.odometer, odometerDelta), (.automatic, automaticDelta), (.manual, manualDelta)
            ].compactMap { source, value in
                guard let value, value < maximumDistanceKm else { return nil }
                return (source, value)
            }
            let continued = deltas.first { $0.source == distanceSource }
            if distanceSource != nil, continued == nil {
                finishSegment()
                distanceSource = nil
            }
            guard let movement = continued ?? deltas.first(where: { $0.distance >= minimumDistanceKm }),
                  movement.distance >= minimumDistanceKm else {
                // A parked reading ends the trip. Keep the same counter so the next odometer
                // tick cannot count distance already measured by a finer counter.
                finishSegment()
                continue
            }
            distanceSource = movement.source
            // Zero-duration duplicates with real movement are quantization noise, not a new
            // trip: absorb the distance into the open segment instead of splitting.
            if segmentStart == nil { segmentStart = start }
            segmentEnd = end
            segmentDistance += movement.distance
            if gap == 0 { continue }
            if let value = end.ambientTemperatureCelsius ?? start.ambientTemperatureCelsius {
                temperatureTotal += value
                temperatureCount += 1
            }
        }
        finishSegment()
        return Array(trips.suffix(limit).reversed())
    }
}
