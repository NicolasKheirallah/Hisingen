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
        let voltageVolts: Double?
        let currentAmps: Double?
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

    struct AirQualityPoint: Identifiable, Equatable {
        let id: Int64
        let timestamp: Date
        let index: Double
        let pm25: Double?
    }

    /// Sane long-term consumption bounds in kWh/100 km. Below ~2 the vehicle is coasting or
    /// regenerating rather than consuming; above 60 is a data error, not a driving style.
    static let efficiencyBounds = 2.0...60.0
    /// A charging sample whose power exceeds this (kW) is treated as a telemetry glitch.
    static let maxPlausiblePowerKw = 500.0
    /// Default gap beyond which a daily-cadence chart series (efficiency, odometer, air
    /// quality) should break its line rather than draw a straight edge across a period with
    /// no data at all, e.g. the car sitting unplugged and unused for weeks.
    static let defaultChartGapThreshold: TimeInterval = 3 * 24 * 3_600
    /// Gap threshold for a within-session series (the charging curve): much shorter than
    /// `defaultChartGapThreshold` since a single session spans hours, not weeks. This matches
    /// the energy integrator: beyond 15 minutes the app does not know what happened and neither
    /// calculations nor charts may pretend the observations form a continuous interval.
    static let chargingCurveGapThreshold: TimeInterval = 15 * 60

    // MARK: - Charging curve

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
        func point(_ offset: Int, _ item: HistoricalChargingSample) -> ChargingCurvePoint {
            ChargingCurvePoint(id: Int64(offset + 1), timestamp: item.timestamp, soc: item.soc,
                               powerKw: item.powerKw, voltageVolts: item.voltageVolts,
                               currentAmps: item.currentAmps)
        }
        guard chronological.count > maximumPoints, maximumPoints >= 2 else {
            return chronological.enumerated().map(point)
        }
        let stride = Double(chronological.count - 1) / Double(maximumPoints - 1)
        var picked: [HistoricalChargingSample] = []
        for index in 0..<maximumPoints {
            picked.append(chronological[min(Int((Double(index) * stride).rounded()),
                                            chronological.count - 1)])
        }
        return picked.enumerated().map(point)
    }

    /// No onboard AC charger fitted to a Polestar or Volvo EV in this fleet exceeds ~22 kW, so
    /// anything above that observed on a session is DC fast charging. Used only as a fallback
    /// (see `chargingType(from:peakPowerKw:)`) — voltage/current readings during charging
    /// reflect pack-side values on these vehicles, which land in a similar range for both AC
    /// and DC charging, so power, not voltage, is the more reliable signal to fall back to.
    static let dcPowerThresholdKw = 22.0

    /// A session's charging type, preferring the vehicle's own reported signal — the majority
    /// value across its samples' real `chargingType` column — since that's ground truth, not a
    /// guess. Falls back to the peak-power heuristic only when every sample predates that
    /// column (`chargingType == nil`) or the vehicle reported `.unknown` throughout.
    static func chargingType(from samples: [HistoricalChargingSample], peakPowerKw: Double?) -> ChargingType {
        let reported = samples
            .compactMap { $0.chargingType.flatMap(ChargingType.init(rawValue:)) }
            .filter { $0 != .unknown }
        if let mostCommon = Dictionary(grouping: reported, by: { $0 })
            .max(by: { $0.value.count < $1.value.count })?.key {
            return mostCommon
        }
        guard let peakPowerKw else { return .unknown }
        return peakPowerKw > dcPowerThresholdKw ? .dc : .ac
    }

    /// Wall-clock time spent charging from 10% to 80% state of charge, interpolated between
    /// the bracketing samples so the estimate isn't quantized to poll frequency. `nil` when the
    /// curve never reaches both bounds (e.g. a session that started above 10% or stopped
    /// before reaching 80%).
    static func tenToEightyDuration(from curve: [ChargingCurvePoint]) -> TimeInterval? {
        guard curve.count >= 2 else { return nil }
        func crossingTime(_ target: Double) -> Date? {
            for (a, b) in zip(curve, curve.dropFirst()) where a.soc <= target && b.soc >= target && b.soc > a.soc {
                let fraction = (target - a.soc) / (b.soc - a.soc)
                return a.timestamp.addingTimeInterval(b.timestamp.timeIntervalSince(a.timestamp) * fraction)
            }
            return nil
        }
        guard let start = crossingTime(10), let end = crossingTime(80), end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    /// Trailing low-power time at the end of a session once the pack is effectively full — the
    /// slow "trickle" some onboard chargers do to balance cells rather than deliver meaningful
    /// energy. Detected as the run of trailing samples at or above `socThreshold` with power
    /// under `powerThresholdKw`. `nil` when the session never reaches the threshold, or ends
    /// exactly at the point it's reached (nothing trails).
    static func idleTailDuration(from curve: [ChargingCurvePoint], socThreshold: Double = 95,
                                 powerThresholdKw: Double = 1.0) -> TimeInterval? {
        guard let last = curve.last else { return nil }
        var tailStart: ChargingCurvePoint?
        for point in curve.reversed() {
            guard point.soc >= socThreshold, (point.powerKw ?? 0) < powerThresholdKw else { break }
            tailStart = point
        }
        guard let tailStart, tailStart.timestamp < last.timestamp else { return nil }
        return last.timestamp.timeIntervalSince(tailStart.timestamp)
    }

    /// An interval between consecutive samples longer than this is treated as a polling gap
    /// (e.g. the vehicle was unplugged and replugged elsewhere) rather than continuous
    /// charging. Wide enough that a long, slow AC session polled only once an hour — a
    /// perfectly ordinary cadence, matching e.g. `airQualityHeartbeat` elsewhere in this file's
    /// sibling recorder — doesn't get its real energy silently discarded interval by interval.
    static let maxContinuousChargingGap: TimeInterval = 3 * 3_600

    /// Estimated round-trip loss between what the charger delivered and what actually landed
    /// as usable state of charge: integrated sample power (trapezoidal, skipping any interval
    /// that spans a polling gap) compared against SoC-gain × pack capacity. Returns `nil`
    /// rather than a fabricated figure whenever the inputs can't support a plausible estimate.
    static func estimatedChargingLossPct(from samples: [HistoricalChargingSample],
                                         packCapacityKwh: Double) -> Double? {
        guard packCapacityKwh > 0 else { return nil }
        let chronological = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = chronological.first, let last = chronological.last,
              last.soc > first.soc else { return nil }
        var energyInputKwh = 0.0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let interval = b.timestamp.timeIntervalSince(a.timestamp)
            guard interval > 0, interval <= maxContinuousChargingGap else { continue }
            energyInputKwh += (p0 + p1) / 2 * (interval / 3_600)
        }
        guard energyInputKwh > 0 else { return nil }
        let storedKwh = packCapacityKwh * (last.soc - first.soc) / 100
        let lossPct = (1 - storedKwh / energyInputKwh) * 100
        return (0...40).contains(lossPct) ? lossPct : nil
    }

    struct TariffCost: Equatable {
        let dayEnergyKwh: Double
        let nightEnergyKwh: Double
        let cost: Double
    }

    /// Splits a session's sample-integrated energy into day/night buckets by each interval's
    /// local hour and prices each bucket separately — materially more accurate than
    /// multiplying total energy by one flat rate once a night tariff is configured, since it
    /// reflects when the energy actually flowed rather than only how much flowed. `nightStart
    /// == nightEnd` disables the night bucket entirely (everything prices at `dayRatePerKwh`).
    static func tariffAwareCost(from samples: [HistoricalChargingSample], dayRatePerKwh: Double,
                                nightRatePerKwh: Double, nightStartHour: Int, nightEndHour: Int,
                                calendar: Calendar = .current) -> TariffCost? {
        let chronological = samples.sorted { $0.timestamp < $1.timestamp }
        guard chronological.count >= 2 else { return nil }
        func isNight(_ date: Date) -> Bool {
            guard nightStartHour != nightEndHour else { return false }
            let hour = calendar.component(.hour, from: date)
            if nightStartHour < nightEndHour {
                return hour >= nightStartHour && hour < nightEndHour
            }
            return hour >= nightStartHour || hour < nightEndHour
        }
        var dayKwh = 0.0
        var nightKwh = 0.0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let interval = b.timestamp.timeIntervalSince(a.timestamp)
            guard interval > 0, interval <= maxContinuousChargingGap else { continue }
            let energy = (p0 + p1) / 2 * (interval / 3_600)
            let midpoint = a.timestamp.addingTimeInterval(interval / 2)
            if isNight(midpoint) { nightKwh += energy } else { dayKwh += energy }
        }
        guard dayKwh + nightKwh > 0 else { return nil }
        return TariffCost(dayEnergyKwh: dayKwh, nightEnergyKwh: nightKwh,
                          cost: dayKwh * dayRatePerKwh + nightKwh * nightRatePerKwh)
    }

    /// Mean sessions-per-week across the observed span. `nil` for fewer than 2 sessions, since
    /// a rate isn't meaningful from a single data point.
    static func sessionsPerWeek(from sessions: [HistoricalChargingSession]) -> Double? {
        let starts = sessions.map(\.startedAt)
        guard sessions.count >= 2, let first = starts.min(), let last = starts.max(), last > first else { return nil }
        let weeks = last.timeIntervalSince(first) / (7 * 86_400)
        return Double(sessions.count) / weeks
    }

    enum TimeOfDay: String, CaseIterable {
        case night = "Night"
        case morning = "Morning"
        case afternoon = "Afternoon"
        case evening = "Evening"
    }

    static func timeOfDay(for date: Date, calendar: Calendar = .current) -> TimeOfDay {
        switch calendar.component(.hour, from: date) {
        case 0..<6: return .night
        case 6..<12: return .morning
        case 12..<18: return .afternoon
        default: return .evening
        }
    }

    /// Energy delivered per start-time bucket, keyed by when each session began charging.
    static func energyByTimeOfDay(from sessions: [HistoricalChargingSession],
                                  calendar: Calendar = .current) -> [TimeOfDay: Double] {
        var totals: [TimeOfDay: Double] = [:]
        for session in sessions {
            totals[timeOfDay(for: session.startedAt, calendar: calendar), default: 0] += session.energyDeliveredKwh
        }
        return totals
    }

    // MARK: - Efficiency trend

    /// Long-term consumption trend in kWh/100 km, oldest first. Readings outside
    /// `efficiencyBounds` are dropped; consecutive identical vehicle-reported values collapse
    /// to one point so a parked week renders as a flat line segment, not a dense cluster.
    static func efficiencyTrend(from records: [HistoricalTelemetryRecord]) -> [EfficiencyPoint] {
        var points: [EfficiencyPoint] = []
        let chronological = records.sorted { $0.timestamp < $1.timestamp }
        for record in chronological {
            // Combustion rows carry L/100 km; only electric-unit readings may feed an
            // energy-consumption trend. Rows from before the unit column existed (nil) keep
            // their historical EV-only interpretation.
            guard record.averageConsumptionUnit != "l",
                  let value = record.averageConsumption,
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

    /// Slope of the consumption trend in kWh/100km per day, from an OLS fit over the collapsed
    /// efficiency series. Positive means consumption is creeping up over time. `nil` when there
    /// aren't enough points, or they don't span enough time to fit a meaningful trend.
    static func efficiencyTrendSlopePerDay(from points: [EfficiencyPoint]) -> Double? {
        guard points.count >= 5, let first = points.first?.timestamp else { return nil }
        let regressionPoints = points.map { (x: $0.timestamp.timeIntervalSince(first) / 86_400, y: $0.kwhPer100Km) }
        return Statistics.linearRegression(regressionPoints)?.slope
    }

    struct SeasonalEfficiency: Equatable {
        /// Average consumption for trips/readings under 5°C ambient.
        let coldAverage: Double?
        /// Average consumption for trips/readings between 5°C and 15°C ambient.
        let mildAverage: Double?
        /// Average consumption for trips/readings above 15°C ambient.
        let warmAverage: Double?
    }

    static func seasonalEfficiency(from records: [HistoricalTelemetryRecord]) -> SeasonalEfficiency {
        var cold: [Double] = [], mild: [Double] = [], warm: [Double] = []
        for record in records {
            guard let consumption = record.averageConsumption, efficiencyBounds.contains(consumption),
                  let temperature = record.ambientTemperatureCelsius else { continue }
            if temperature < 5 { cold.append(consumption) }
            else if temperature <= 15 { mild.append(consumption) }
            else { warm.append(consumption) }
        }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        return SeasonalEfficiency(coldAverage: average(cold), mildAverage: average(mild), warmAverage: average(warm))
    }

    /// Mean of an efficiency series, or nil when empty.
    static func averageEfficiency(of points: [EfficiencyPoint]) -> Double? {
        guard !points.isEmpty else { return nil }
        return points.reduce(0) { $0 + $1.kwhPer100Km } / Double(points.count)
    }

    // MARK: - Odometer trend

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
            points.append(OdometerPoint(id: record.id, timestamp: record.timestamp, odometerKm: value))
        }
        return points
    }

    /// Distance driven between the first and last odometer observation, when both exist.
    static func distanceCovered(from points: [OdometerPoint]) -> Double? {
        guard points.count >= 2, let first = points.first, let last = points.last else { return nil }
        let delta = last.odometerKm - first.odometerKm
        return delta >= 0 ? delta : nil
    }

    /// Average daily distance in km across the observed span. `nil` when the span is under a
    /// day, since a single day's noise isn't a meaningful daily rate.
    static func averageKmPerDay(from points: [OdometerPoint]) -> Double? {
        guard let first = points.first, let last = points.last, points.count >= 2 else { return nil }
        let days = last.timestamp.timeIntervalSince(first.timestamp) / 86_400
        guard days >= 1, let distance = distanceCovered(from: points) else { return nil }
        return distance / days
    }

    struct MonthlyMileage: Identifiable, Equatable {
        var id: Date { month }
        let month: Date
        let distanceKm: Double
    }

    /// Distance driven per calendar month, from consecutive odometer deltas — works even when
    /// trip-segmentation drops sparse-telemetry drives, since it only needs two odometer
    /// readings, not a continuous run of them.
    static func monthlyMileage(from points: [OdometerPoint], calendar: Calendar = .current) -> [MonthlyMileage] {
        guard points.count >= 2 else { return [] }
        var totals: [Date: Double] = [:]
        for (a, b) in zip(points, points.dropFirst()) {
            let delta = b.odometerKm - a.odometerKm
            guard delta > 0 else { continue }
            totals[monthBucket(b.timestamp, calendar: calendar), default: 0] += delta
        }
        return totals.map { MonthlyMileage(month: $0.key, distanceKm: $0.value) }.sorted { $0.month < $1.month }
    }

    // MARK: - Trip aggregates

    struct DailyDistance: Identifiable, Equatable {
        var id: Date { day }
        let day: Date
        let distanceKm: Double
    }

    static func dailyDistance(from trips: [TripHistoryEntry], calendar: Calendar = .current) -> [DailyDistance] {
        var totals: [Date: Double] = [:]
        for trip in trips {
            totals[dayBucket(trip.endedAt, calendar: calendar), default: 0] += trip.distanceKm
        }
        return totals.map { DailyDistance(day: $0.key, distanceKm: $0.value) }.sorted { $0.day < $1.day }
    }

    struct WeeklyDistance: Identifiable, Equatable {
        var id: Date { week }
        let week: Date
        let distanceKm: Double
    }

    static func weeklyDistance(from trips: [TripHistoryEntry], calendar: Calendar = .current) -> [WeeklyDistance] {
        var totals: [Date: Double] = [:]
        for trip in trips {
            totals[weekBucket(trip.endedAt, calendar: calendar), default: 0] += trip.distanceKm
        }
        return totals.map { WeeklyDistance(week: $0.key, distanceKm: $0.value) }.sorted { $0.week < $1.week }
    }

    static func longestTrip(from trips: [TripHistoryEntry]) -> TripHistoryEntry? {
        trips.max { $0.distanceKm < $1.distanceKm }
    }

    /// Average speed in km/h. `nil` for an implausibly short duration, which would otherwise
    /// blow the average up toward infinity rather than report something meaningful.
    static func averageSpeedKmh(_ trip: TripHistoryEntry) -> Double? {
        guard trip.duration >= 30 else { return nil }
        return trip.distanceKm / (trip.duration / 3_600)
    }

    /// Pearson correlation between ambient temperature and consumption across trips reporting
    /// both. Negative — the expected case — means colder trips consume more. `nil` under 5
    /// trips, where a correlation coefficient is mostly noise.
    static func temperatureConsumptionCorrelation(from trips: [TripHistoryEntry]) -> Double? {
        let pairs = trips.compactMap { trip -> (Double, Double)? in
            guard let temperature = trip.ambientTemperatureCelsius,
                  let consumption = trip.averageConsumption,
                  efficiencyBounds.contains(consumption) else { return nil }
            return (temperature, consumption)
        }
        guard pairs.count >= 5 else { return nil }
        return Statistics.pearsonCorrelation(pairs)
    }

    // MARK: - Battery health

    struct BatteryHealthTrend: Equatable {
        /// Slope of state-of-health against distance, from an OLS fit over the stored
        /// milestones. Negative means the battery is degrading with distance, as expected; a
        /// positive slope usually means too few/noisy points rather than real improvement.
        let stateOfHealthPctPer10kKm: Double?
    }

    static func batteryHealthTrend(from records: [BatteryHealthRecord]) -> BatteryHealthTrend {
        let points = records.map { (x: $0.odometerKm / 10_000, y: $0.stateOfHealthPct) }
        return BatteryHealthTrend(stateOfHealthPctPer10kKm: Statistics.linearRegression(points)?.slope)
    }

    /// Projects state of health at a future odometer reading from the fitted trend. `nil` when
    /// there isn't enough history to fit a trend, or the projection lands outside a physically
    /// sane 0...100% range (a fabricated-looking number is worse than no number).
    static func projectedStateOfHealth(from records: [BatteryHealthRecord], atOdometerKm target: Double) -> Double? {
        let points = records.map { (x: $0.odometerKm / 10_000, y: $0.stateOfHealthPct) }
        guard let fit = Statistics.linearRegression(points) else { return nil }
        let projected = fit.value(at: target / 10_000)
        return (0...100).contains(projected) ? projected : nil
    }

    // MARK: - Air quality trend

    static func airQualityTrend(from records: [AirQualityRecord]) -> [AirQualityPoint] {
        records
            .compactMap { record -> (AirQualityRecord, Double)? in
                guard let index = record.airQualityIndex, index >= 0 else { return nil }
                return (record, index)
            }
            .sorted { $0.0.timestamp < $1.0.timestamp }
            .map { record, index in AirQualityPoint(id: record.id, timestamp: record.timestamp, index: index, pm25: record.particulateMatter25) }
    }

    // MARK: - Command statistics

    struct CommandStatistics: Equatable {
        let totalCount: Int
        let successCount: Int
        let successRatePct: Double?
        let mostUsedCommand: String?
    }

    static func commandStatistics(from records: [RemoteCommandAuditRecord]) -> CommandStatistics {
        guard !records.isEmpty else {
            return CommandStatistics(totalCount: 0, successCount: 0, successRatePct: nil, mostUsedCommand: nil)
        }
        let successCount = records.filter { $0.status != "failed" }.count
        let counts = Dictionary(grouping: records, by: \.command).mapValues(\.count)
        return CommandStatistics(
            totalCount: records.count,
            successCount: successCount,
            successRatePct: Double(successCount) / Double(records.count) * 100,
            mostUsedCommand: counts.max { $0.value < $1.value }?.key
        )
    }

    // MARK: - Data quality

    struct DataCoverage: Equatable {
        let sampleCount: Int
        let spanDays: Double?
        let stalenessDays: Double?

        enum Confidence: String {
            case insufficient = "Insufficient"
            case low = "Low"
            case medium = "Medium"
            case high = "High"
        }

        var confidence: Confidence {
            guard sampleCount >= 3, let spanDays else { return .insufficient }
            if sampleCount >= 20, spanDays >= 14 { return .high }
            if sampleCount >= 8, spanDays >= 5 { return .medium }
            return .low
        }
    }

    static func dataCoverage(timestamps: [Date], now: Date = Date()) -> DataCoverage {
        guard let first = timestamps.min(), let last = timestamps.max() else {
            return DataCoverage(sampleCount: 0, spanDays: nil, stalenessDays: nil)
        }
        return DataCoverage(sampleCount: timestamps.count,
                            spanDays: last.timeIntervalSince(first) / 86_400,
                            stalenessDays: now.timeIntervalSince(last) / 86_400)
    }

    // MARK: - Chart support: gap segmentation & bucketing

    /// Splits a chronologically-sorted series into runs with no internal gap larger than
    /// `maxGap`, so a chart can render each run as its own line instead of drawing a straight
    /// edge across a period with no data — e.g. the car sitting unplugged and unused for weeks.
    static func segments<T>(of points: [T], maxGap: TimeInterval, timestamp: (T) -> Date) -> [[T]] {
        guard let firstPoint = points.first else { return [] }
        var result: [[T]] = [[firstPoint]]
        for point in points.dropFirst() {
            let previousTimestamp = timestamp(result[result.count - 1].last!)
            if timestamp(point).timeIntervalSince(previousTimestamp) > maxGap {
                result.append([point])
            } else {
                result[result.count - 1].append(point)
            }
        }
        return result
    }

    static func dayBucket(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    static func weekBucket(_ date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return calendar.date(from: components) ?? dayBucket(date, calendar: calendar)
    }

    static func monthBucket(_ date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? dayBucket(date, calendar: calendar)
    }
}

extension HistoryInsights {
    struct ServiceProjection: Equatable {
        /// Predicted calendar date the next service becomes due, from current usage rate.
        let projectedDate: Date?
        /// Predicted odometer reading at that date, when an odometer rate exists.
        let projectedOdometerKm: Double?
    }

    /// Projects when the next service falls due by combining the vehicle's own remaining
    /// distance/time-to-service with the observed km/day rate. Purely derived from values the
    /// providers already report; no provider supplies a predicted date themselves.
    static func projectService(currentOdometerKm: Double?,
                               distanceToServiceKm: Int?,
                               daysToService: Int?,
                               odometerPoints: [OdometerPoint],
                               now: Date = Date()) -> ServiceProjection? {
        let rateKmPerDay: Double? = {
            guard odometerPoints.count >= 2,
                  let first = odometerPoints.first, let last = odometerPoints.last else { return nil }
            let days = last.timestamp.timeIntervalSince(first.timestamp) / 86_400
            guard days >= 7 else { return nil }
            let km = last.odometerKm - first.odometerKm
            guard km > 0 else { return nil }
            return km / days
        }()

        // Distance-based estimate needs both a remaining figure and a rate to convert it.
        var dateFromDistance: Date?
        if let remaining = distanceToServiceKm, remaining > 0, let rate = rateKmPerDay, rate > 0 {
            dateFromDistance = now.addingTimeInterval(Double(remaining) / rate * 86_400)
        }
        // Time-based fallback straight from the vehicle's own countdown.
        var dateFromDays: Date?
        if let days = daysToService, days > 0 {
            dateFromDays = now.addingTimeInterval(Double(days) * 86_400)
        }

        let candidate = [dateFromDistance, dateFromDays].compactMap { $0 }.min()
        guard let candidate else { return nil }
        var projection = ServiceProjection(projectedDate: candidate, projectedOdometerKm: nil)
        if let rate = rateKmPerDay,
           let odo = currentOdometerKm ?? odometerPoints.last?.odometerKm {
            let deltaDays = max(0, candidate.timeIntervalSince(now) / 86_400)
            projection = ServiceProjection(projectedDate: candidate,
                                           projectedOdometerKm: odo + rate * deltaDays)
        }
        return projection
    }
}

extension HistoryInsights {
    struct FilterLifeEstimate: Equatable {
        /// Estimated days until the cabin filter reaches 0 %, from observed wear rate.
        let daysRemaining: Double
        /// Observed percentage-points lost per day.
        let percentPerDay: Double
    }

    /// Estimates remaining filter life from the *observed* wear rate across stored air-quality
    /// samples — explicitly a guesstimate: it extrapolates a linear rate from sparse readings
    /// and assumes usage stays similar. Returns nil until at least 0.5 percentage points of
    /// decline have been observed over at least 7 days.
    static func filterLifeEstimate(from records: [AirQualityRecord],
                                   now: Date = Date()) -> FilterLifeEstimate? {
        let chronological = records
            .compactMap { record -> (Date, Double)? in
                record.filterRemainingPercent.map { (record.timestamp, $0) }
            }
            .sorted { $0.0 < $1.0 }
        guard chronological.count >= 2,
              let first = chronological.first, let last = chronological.last else { return nil }
        let days = last.0.timeIntervalSince(first.0) / 86_400
        guard days >= 7 else { return nil }
        let dropped = first.1 - last.1
        guard dropped >= 0.5, last.1 > 0 else { return nil }
        let perDay = dropped / days
        guard perDay > 0 else { return nil }
        return FilterLifeEstimate(daysRemaining: last.1 / perDay, percentPerDay: perDay)
    }

    /// Lifetime energy cost per distance driven, from stored charging sessions and odometer
    /// history. Both figures are local estimates; nil when either side lacks data.
    /// - Parameter fuelCost: manual fill-up spend for PHEV/ICE — combined with electricity
    ///   so hybrid economics are complete instead of silently electric-only.
    static func costPerKm(totalEnergyKwh: Double?, pricePerKwh: Double,
                          odometerPoints: [OdometerPoint],
                          fuelCost: Double = 0) -> Double? {
        let electricSpend = totalEnergyKwh.map { $0 * pricePerKwh } ?? 0
        let totalSpend = electricSpend + max(0, fuelCost)
        guard totalSpend > 0,
              let distance = distanceCovered(from: odometerPoints), distance >= 100 else { return nil }
        return totalSpend / distance
    }
}

extension HistoryInsights {
    /// Detects a completed session whose peak power is dramatically below what this vehicle
    /// usually achieves at the same named location — a classic failing-cable / derated-EVSE
    /// signal. Requires ≥3 comparable sessions so a first visit can never trigger it.
    static func sessionPeakAnomaly(currentPeakKw: Double,
                                   priorPeaksKwAtSameLocation: [Double]) -> Bool {
        guard priorPeaksKwAtSameLocation.count >= 3 else { return false }
        let sorted = priorPeaksKwAtSameLocation.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return false }
        return currentPeakKw < median * 0.6
    }

    /// Runs `sessionPeakAnomaly` over a whole session list, comparing each completed session
    /// against the earlier sessions recorded at the same named location. Returns the ids of
    /// sessions that look derated so the dashboard can flag them inline.
    static func sessionPeakAnomalies(in sessions: [HistoricalChargingSession]) -> Set<String> {
        let chronological = sessions.sorted { $0.startedAt < $1.startedAt }
        var priorPeaksByLocation: [String: [Double]] = [:]
        var flagged: Set<String> = []
        for session in chronological {
            guard let location = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !location.isEmpty else { continue }
            let key = location.lowercased()
            let priors = priorPeaksByLocation[key] ?? []
            if session.endedAt != nil, session.peakPowerKw > 0,
               sessionPeakAnomaly(currentPeakKw: session.peakPowerKw, priorPeaksKwAtSameLocation: priors) {
                flagged.insert(session.id)
            }
            if session.peakPowerKw > 0 { priorPeaksByLocation[key, default: []].append(session.peakPowerKw) }
        }
        return flagged
    }
}

// MARK: - Chart scrubbing

extension HistoryInsights {
    /// The element of `points` whose `timestamp` is closest to `date` — the point a chart
    /// scrub gesture snaps its readout to.
    static func nearest<T>(to date: Date, in points: [T], timestamp: (T) -> Date) -> T? {
        points.min { abs(timestamp($0).timeIntervalSince(date)) < abs(timestamp($1).timeIntervalSince(date)) }
    }
}

// MARK: - Month-to-date / year-to-date windows

extension HistoryInsights {
    /// The elapsed portion of the current month, paired with the identically-long window that
    /// ended one month earlier. Comparing these two answers "am I ahead of last month *so
    /// far*" instead of pitting two days against a whole month. `nil` only if calendar math
    /// fails (it never does for the Gregorian calendar).
    static func monthToDateWindows(now: Date = Date(), calendar: Calendar = .current)
        -> (current: DateInterval, previous: DateInterval)? {
        let monthStart = monthBucket(now, calendar: calendar)
        guard let previousMonthStart = calendar.date(byAdding: .month, value: -1, to: monthStart) else { return nil }
        let elapsed = max(0, now.timeIntervalSince(monthStart))
        // Clamp the mirrored window to the previous month's own length so a 31st never spills
        // into the month before it.
        let previousMonthLength = calendar.date(byAdding: .month, value: 1, to: previousMonthStart)
            .map { $0.timeIntervalSince(previousMonthStart) } ?? elapsed
        let previousEnd = previousMonthStart.addingTimeInterval(min(elapsed, previousMonthLength))
        return (DateInterval(start: monthStart, end: now),
                DateInterval(start: previousMonthStart, end: previousEnd))
    }

    /// Year-to-date paired with the same span a year earlier — the basis for a year-over-year
    /// line on the comparison card.
    static func yearToDateWindows(now: Date = Date(), calendar: Calendar = .current)
        -> (current: DateInterval, previous: DateInterval)? {
        let components = calendar.dateComponents([.year], from: now)
        guard let yearStart = calendar.date(from: components),
              let previousYearStart = calendar.date(byAdding: .year, value: -1, to: yearStart),
              let previousEnd = calendar.date(byAdding: .year, value: -1, to: now) else { return nil }
        return (DateInterval(start: yearStart, end: now),
                DateInterval(start: previousYearStart, end: previousEnd))
    }
}

// MARK: - Monthly charging energy & cost

extension HistoryInsights {
    struct MonthlyEnergy: Identifiable, Equatable {
        var id: Date { month }
        let month: Date
        let energyKwh: Double
        /// `nil` when the month mixed currencies and a single total would be misleading.
        let cost: Double?
        let currency: String?
    }

    /// Energy delivered and spend per calendar month, keyed by session start. Each session's
    /// own saved cost/tariff is honoured; only when a session predates cost retention does
    /// `fallbackPricePerKwh` apply. Months mixing currencies report `cost == nil`.
    static func monthlyChargingEnergy(from sessions: [HistoricalChargingSession],
                                     fallbackPricePerKwh: Double,
                                     fallbackCurrency: String,
                                     calendar: Calendar = .current) -> [MonthlyEnergy] {
        var energyByMonth: [Date: Double] = [:]
        var costByMonth: [Date: Double] = [:]
        var currenciesByMonth: [Date: Set<String>] = [:]
        for session in sessions {
            let bucket = monthBucket(session.startedAt, calendar: calendar)
            energyByMonth[bucket, default: 0] += session.energyDeliveredKwh
            let currency = session.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            currenciesByMonth[bucket, default: []].insert(currency?.isEmpty == false ? currency! : fallbackCurrency)
            let cost = session.estimatedCost
                ?? session.tariffPricePerKwh.map { $0 * session.energyDeliveredKwh }
                ?? fallbackPricePerKwh * session.energyDeliveredKwh
            costByMonth[bucket, default: 0] += cost
        }
        return energyByMonth.keys.sorted().map { month in
            let currencies = currenciesByMonth[month] ?? []
            let mixed = currencies.count > 1
            return MonthlyEnergy(month: month,
                                 energyKwh: energyByMonth[month] ?? 0,
                                 cost: mixed ? nil : costByMonth[month],
                                 currency: mixed ? nil : currencies.first)
        }
    }
}

// MARK: - Charging location breakdown

extension HistoryInsights {
    struct LocationStat: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let sessionCount: Int
        let energyKwh: Double
        let averagePeakKw: Double
        let cost: Double?
        let currency: String?
    }

    /// Per-location charging summary, most-used first. Sessions without a recorded place name
    /// collapse into one `unknownLabel` bucket rather than being dropped.
    static func locationStats(from sessions: [HistoricalChargingSession],
                              fallbackPricePerKwh: Double,
                              fallbackCurrency: String,
                              unknownLabel: String) -> [LocationStat] {
        struct Accumulator { var count = 0; var energy = 0.0; var peakSum = 0.0; var peakCount = 0
                             var cost = 0.0; var currencies: Set<String> = [] }
        var byName: [String: Accumulator] = [:]
        for session in sessions {
            let trimmed = session.locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false ? trimmed! : unknownLabel)
            var acc = byName[name] ?? Accumulator()
            acc.count += 1
            acc.energy += session.energyDeliveredKwh
            if session.peakPowerKw > 0 { acc.peakSum += session.peakPowerKw; acc.peakCount += 1 }
            acc.cost += session.estimatedCost
                ?? session.tariffPricePerKwh.map { $0 * session.energyDeliveredKwh }
                ?? fallbackPricePerKwh * session.energyDeliveredKwh
            let currency = session.currencySymbol?.trimmingCharacters(in: .whitespacesAndNewlines)
            acc.currencies.insert(currency?.isEmpty == false ? currency! : fallbackCurrency)
            byName[name] = acc
        }
        return byName.map { name, acc in
            LocationStat(name: name, sessionCount: acc.count, energyKwh: acc.energy,
                         averagePeakKw: acc.peakCount > 0 ? acc.peakSum / Double(acc.peakCount) : 0,
                         cost: acc.currencies.count > 1 ? nil : acc.cost,
                         currency: acc.currencies.count > 1 ? nil : acc.currencies.first)
        }
        .sorted { ($0.sessionCount, $0.energyKwh) > ($1.sessionCount, $1.energyKwh) }
    }
}

// MARK: - Driving patterns

extension HistoryInsights {
    struct HourBucket: Identifiable, Equatable {
        var id: Int { hour }
        let hour: Int
        let tripCount: Int
        let distanceKm: Double
    }

    /// Trip count and distance by local hour of departure, always a full 0…23 so the
    /// histogram keeps its shape even for quiet hours.
    static func tripsByHourOfDay(from trips: [TripHistoryEntry],
                                 calendar: Calendar = .current) -> [HourBucket] {
        var counts = Array(repeating: 0, count: 24)
        var distances = Array(repeating: 0.0, count: 24)
        for trip in trips {
            let hour = calendar.component(.hour, from: trip.startedAt)
            guard (0..<24).contains(hour) else { continue }
            counts[hour] += 1
            distances[hour] += trip.distanceKm
        }
        return (0..<24).map { HourBucket(hour: $0, tripCount: counts[$0], distanceKm: distances[$0]) }
    }

    struct WeekdayWeekendSplit: Equatable {
        let weekdayKm: Double
        let weekendKm: Double
        let weekdayTripCount: Int
        let weekendTripCount: Int
        /// Distance per calendar day for the five weekdays vs the two weekend days, so the
        /// two figures are comparable despite the 5:2 split.
        var weekdayKmPerDay: Double { weekdayKm / 5 }
        var weekendKmPerDay: Double { weekendKm / 2 }
    }

    static func weekdayWeekendDistance(from trips: [TripHistoryEntry],
                                       calendar: Calendar = .current) -> WeekdayWeekendSplit {
        var weekdayKm = 0.0, weekendKm = 0.0, weekdayCount = 0, weekendCount = 0
        for trip in trips {
            if calendar.isDateInWeekend(trip.startedAt) {
                weekendKm += trip.distanceKm; weekendCount += 1
            } else {
                weekdayKm += trip.distanceKm; weekdayCount += 1
            }
        }
        return WeekdayWeekendSplit(weekdayKm: weekdayKm, weekendKm: weekendKm,
                                   weekdayTripCount: weekdayCount, weekendTripCount: weekendCount)
    }
}

// MARK: - Combustion / hybrid fuel economy

extension HistoryInsights {
    /// Plausible litres-per-100 km bounds. Below ~1 is coasting or a data glitch; above 30 is
    /// not a driving style on any vehicle this app supports.
    static let fuelConsumptionBounds = 1.0...30.0

    /// L/100 km trend for combustion / hybrid vehicles, mirroring `efficiencyTrend`. Reads
    /// only telemetry rows the recorder tagged as litre-unit; `EfficiencyPoint.kwhPer100Km`
    /// simply carries the litre figure here (the struct is unit-agnostic storage).
    static func combustionConsumptionTrend(from records: [HistoricalTelemetryRecord]) -> [EfficiencyPoint] {
        var points: [EfficiencyPoint] = []
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard record.averageConsumptionUnit == "l",
                  let value = record.averageConsumption,
                  fuelConsumptionBounds.contains(value) else { continue }
            if let last = points.last, abs(last.kwhPer100Km - value) <= 0.05,
               record.timestamp.timeIntervalSince(last.timestamp) < 6 * 3_600 {
                continue
            }
            points.append(EfficiencyPoint(id: record.id, timestamp: record.timestamp, kwhPer100Km: value))
        }
        return points
    }

    struct FuelEconomyPoint: Identifiable, Equatable {
        let id: Int64
        let date: Date
        let litersPer100Km: Double
        let pricePerLiter: Double
    }

    /// Tank-to-tank economy: each fill's litres divided by the distance since the previous
    /// fill. Needs an odometer reading on both fills. Fills are supplied newest-first (as the
    /// database returns them); output is oldest-first for charting.
    static func fuelEconomyBetweenFills(
        _ entries: [(id: Int64, date: Date, liters: Double, pricePerLiter: Double, odometerKm: Double?)]
    ) -> [FuelEconomyPoint] {
        let chronological = entries.sorted { $0.date < $1.date }
        var points: [FuelEconomyPoint] = []
        for (previous, current) in zip(chronological, chronological.dropFirst()) {
            guard let startOdo = previous.odometerKm, let endOdo = current.odometerKm,
                  endOdo > startOdo, current.liters > 0 else { continue }
            let distance = endOdo - startOdo
            let lPer100 = current.liters / distance * 100
            guard fuelConsumptionBounds.contains(lPer100) else { continue }
            points.append(FuelEconomyPoint(id: current.id, date: current.date,
                                           litersPer100Km: lPer100, pricePerLiter: current.pricePerLiter))
        }
        return points
    }
}

// MARK: - Emissions comparison

extension HistoryInsights {
    struct EmissionsComparison: Equatable {
        /// Grid generation attributable to the electricity the EV km consumed.
        let electricKgCO2: Double
        /// A comparable petrol car covering the same distance, well-to-wheel.
        let petrolKgCO2: Double
        var avoidedKgCO2: Double { max(0, petrolKgCO2 - electricKgCO2) }
    }

    /// Rough well-to-wheel CO₂ comparison for distance driven electrically vs a comparable
    /// petrol car. Every input is an estimate — grid intensity varies by time and region, and
    /// the petrol baseline is a segment average, not the driver's former car — so callers
    /// should present the result as indicative. `nil` for non-positive distance/consumption.
    static func emissionsComparison(electricKm: Double,
                                    consumptionKwhPer100Km: Double,
                                    gridGramsCO2PerKwh: Double,
                                    petrolGramsCO2PerKm: Double = 170) -> EmissionsComparison? {
        guard electricKm > 0, consumptionKwhPer100Km > 0, gridGramsCO2PerKwh >= 0 else { return nil }
        let energyKwh = electricKm / 100 * consumptionKwhPer100Km
        return EmissionsComparison(
            electricKgCO2: energyKwh * gridGramsCO2PerKwh / 1_000,
            petrolKgCO2: electricKm * max(0, petrolGramsCO2PerKm) / 1_000
        )
    }
}
