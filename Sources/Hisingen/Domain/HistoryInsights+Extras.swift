import Foundation

// Derived figures for the Log that need no new view logic: they take stored records and return
// numbers. Kept pure so each rule can be pinned by a test, and so the charts only draw.

extension HistoryInsights {
    // MARK: - Parked drain

    /// Charge lost on one day while the car stood unplugged.
    struct ParkedDrainDay: Equatable, Identifiable, Sendable {
        let day: Date
        let percentLost: Double
        let hours: Double
        var id: Date { day }
    }

    struct ParkedDrain: Equatable, Sendable {
        var days: [ParkedDrainDay] = []
        /// Average over every observed parked hour, as percentage points per 24 hours. `nil` until
        /// there are at least six observed hours, since a shorter stretch says nothing about a slope.
        var percentPerDay: Double?
        var observedHours: Double = 0
    }

    /// Charge lost between consecutive readings that were both taken unplugged.
    ///
    /// A pair counts only when it is short enough to be one stretch (`maxGap`), the level did not
    /// rise, no detected trip overlaps it, and the implied rate is not one a parked car can reach
    /// (above 25 points a day it is almost certainly a drive the trip detector missed). Everything
    /// else is left out rather than guessed, so the figure is a floor of what was observed.
    static func parkedDrain(
        levels: [VehicleMetricRecord], trips: [TripHistoryEntry],
        maxGap: TimeInterval = 12 * 3_600, calendar: Calendar = .current
    ) -> ParkedDrain {
        var byDay: [Date: (lost: Double, hours: Double)] = [:]
        for (earlier, later) in zip(levels, levels.dropFirst()) {
            guard earlier.text == "parked", later.text == "parked",
                  let from = earlier.value, let to = later.value else { continue }
            let seconds = later.timestamp.timeIntervalSince(earlier.timestamp)
            guard seconds >= 60, seconds <= maxGap, to <= from else { continue }
            if trips.contains(where: { $0.startedAt < later.timestamp && $0.endedAt > earlier.timestamp }) { continue }
            let hours = seconds / 3_600
            let lost = from - to
            guard lost / hours * 24 <= 25 else { continue }
            let day = calendar.startOfDay(for: earlier.timestamp)
            let existing = byDay[day] ?? (0, 0)
            byDay[day] = (existing.lost + lost, existing.hours + hours)
        }
        let days = byDay.map { ParkedDrainDay(day: $0.key, percentLost: $0.value.lost, hours: $0.value.hours) }
            .sorted { $0.day < $1.day }
        let hours = days.reduce(0) { $0 + $1.hours }
        let lost = days.reduce(0) { $0 + $1.percentLost }
        return ParkedDrain(days: days, percentPerDay: hours >= 6 ? lost / hours * 24 : nil, observedHours: hours)
    }

    // MARK: - Cost

    /// What 100 km cost in electricity: the car's own consumption priced at the average rate the
    /// charging sessions actually paid. `nil` unless both inputs are positive.
    static func costPer100Km(consumptionKwhPer100Km: Double, pricePerKwh: Double) -> Double? {
        guard consumptionKwhPer100Km > 0, pricePerKwh > 0 else { return nil }
        return consumptionKwhPer100Km * pricePerKwh
    }

    struct SpotSavings: Equatable, Sendable {
        /// What the market-priced sessions cost.
        var paid: Double
        /// What the same energy would have cost at the fixed rate.
        var reference: Double
        var energyKwh: Double
        var sessionCount: Int

        var saved: Double { reference - paid }
        var percent: Double? { reference > 0 ? saved / reference * 100 : nil }
    }

    /// Market-priced sessions against the reader's fixed rate. Only sessions that have a market
    /// estimate count, so a session without hourly prices never shifts the comparison.
    static func spotSavings(sessions: [HistoricalChargingSession], fixedPricePerKwh: Double) -> SpotSavings? {
        guard fixedPricePerKwh > 0 else { return nil }
        var result = SpotSavings(paid: 0, reference: 0, energyKwh: 0, sessionCount: 0)
        for session in sessions {
            guard let spot = session.spotEstimatedCost, session.energyDeliveredKwh > 0 else { continue }
            result.paid += spot
            result.reference += session.energyDeliveredKwh * fixedPricePerKwh
            result.energyKwh += session.energyDeliveredKwh
            result.sessionCount += 1
        }
        return result.sessionCount > 0 ? result : nil
    }

    // MARK: - Temperature and normalised consumption

    /// Least-squares line through the points. `nil` below three points or when every x is equal.
    static func linearFit(_ points: [(x: Double, y: Double)]) -> (slope: Double, intercept: Double)? {
        guard points.count >= 3 else { return nil }
        let n = Double(points.count)
        let meanX = points.reduce(0) { $0 + $1.x } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        let spread = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard spread > 0 else { return nil }
        let slope = points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / spread
        return (slope, meanY - slope * meanX)
    }

    /// Trips with both an outside temperature and a plausible consumption, as (°C, kWh/100 km).
    static func temperatureConsumptionPoints(from trips: [TripHistoryEntry]) -> [(temperature: Double, consumption: Double)] {
        trips.compactMap { trip in
            guard let temperature = trip.ambientTemperatureCelsius, let consumption = trip.averageConsumption,
                  efficiencyBounds.contains(consumption) else { return nil }
            return (temperature, consumption)
        }
    }

    struct MonthlyConsumption: Equatable, Identifiable, Sendable {
        let month: Date
        /// Average of the trips' own consumption, kWh/100 km.
        let raw: Double
        /// The same trips with the temperature effect taken out, as if all were driven at the
        /// reference temperature, kWh/100 km.
        let normalised: Double
        var id: Date { month }
    }

    /// Monthly consumption raw and adjusted to `referenceCelsius`, using the line fitted through
    /// the trips themselves. Needs the fit to stay positive across the observed range and at least
    /// two trips in a month, otherwise it returns nothing rather than a number the data cannot back.
    static func monthlyNormalisedConsumption(
        from trips: [TripHistoryEntry], referenceCelsius: Double = 15, calendar: Calendar = .current
    ) -> [MonthlyConsumption] {
        let usable = trips.compactMap { trip -> (month: Date, temperature: Double, consumption: Double)? in
            guard let temperature = trip.ambientTemperatureCelsius, let consumption = trip.averageConsumption,
                  efficiencyBounds.contains(consumption),
                  let month = calendar.dateInterval(of: .month, for: trip.endedAt)?.start else { return nil }
            return (month, temperature, consumption)
        }
        guard let fit = linearFit(usable.map { ($0.temperature, $0.consumption) }) else { return [] }
        func fitted(_ temperature: Double) -> Double { fit.intercept + fit.slope * temperature }
        let reference = fitted(referenceCelsius)
        guard reference > 0, usable.allSatisfy({ fitted($0.temperature) > 0 }) else { return [] }
        return Dictionary(grouping: usable, by: \.month).compactMap { month, rows in
            guard rows.count >= 2 else { return nil }
            let raw = rows.reduce(0) { $0 + $1.consumption } / Double(rows.count)
            let adjusted = rows.reduce(0) { $0 + $1.consumption * reference / fitted($1.temperature) } / Double(rows.count)
            return MonthlyConsumption(month: month, raw: raw, normalised: adjusted)
        }.sorted { $0.month < $1.month }
    }

    // MARK: - Energy use by month

    struct MonthlyEnergySplit: Equatable, Identifiable, Sendable {
        let month: Date
        var driving: Double
        var climate: Double
        var battery: Double
        var other: Double
        var id: Date { month }
        var total: Double { driving + climate + battery + other }
    }

    /// Energy used per month, split by what used it, from the readings of "energy since the last
    /// charge". That figure only grows until a charge resets it, so the highest reading of each
    /// cycle is the cycle's tally; a fall of more than a tenth marks the reset. Each cycle counts
    /// in the month of its last reading.
    static func monthlyEnergySplit(samples: [VehicleMetricRecord], calendar: Calendar = .current) -> [MonthlyEnergySplit] {
        let decoder = JSONDecoder()
        var finished: [(date: Date, sample: EnergyBreakdownSample)] = []
        var peak: (date: Date, sample: EnergyBreakdownSample)?
        for record in samples {
            guard let text = record.text, let data = text.data(using: .utf8),
                  let sample = try? decoder.decode(EnergyBreakdownSample.self, from: data) else { continue }
            if let current = peak, sample.total < current.sample.total * 0.9 {
                finished.append(current)
                peak = (record.timestamp, sample)
            } else if peak == nil || sample.total >= peak!.sample.total {
                peak = (record.timestamp, sample)
            }
        }
        if let peak { finished.append(peak) }
        var months: [Date: MonthlyEnergySplit] = [:]
        for cycle in finished {
            guard let month = calendar.dateInterval(of: .month, for: cycle.date)?.start else { continue }
            var row = months[month] ?? MonthlyEnergySplit(month: month, driving: 0, climate: 0, battery: 0, other: 0)
            row.driving += cycle.sample.driving
            row.climate += cycle.sample.climate
            row.battery += cycle.sample.battery
            row.other += cycle.sample.other
            months[month] = row
        }
        return months.values.sorted { $0.month < $1.month }
    }

    // MARK: - Recording coverage

    struct CoverageDay: Equatable, Identifiable, Sendable {
        let day: Date
        /// Distinct hours of the day with at least one reading, 0 to 24.
        let hours: Int
        var id: Date { day }
    }

    /// Hours per day in which Hisingen recorded anything. A quiet day here means the app was not
    /// running, which the charts cannot tell apart from a car that did nothing.
    static func recordingCoverage(timestamps: [Date], calendar: Calendar = .current) -> [CoverageDay] {
        var hoursByDay: [Date: Set<Int>] = [:]
        for stamp in timestamps {
            hoursByDay[calendar.startOfDay(for: stamp), default: []].insert(calendar.component(.hour, from: stamp))
        }
        return hoursByDay.map { CoverageDay(day: $0.key, hours: $0.value.count) }.sorted { $0.day < $1.day }
    }

    // MARK: - Software

    struct SoftwareChange: Equatable, Identifiable, Sendable {
        let date: Date
        let version: String
        var id: Date { date }
    }

    /// Version changes: every reported version after the first. The first row is only the version the
    /// car had when recording began, not a change.
    static func softwareChanges(from records: [VehicleMetricRecord]) -> [SoftwareChange] {
        records.dropFirst().compactMap { record in
            record.text.map { SoftwareChange(date: record.timestamp, version: $0) }
        }
    }

    // MARK: - Projection

    /// What a month-to-date total comes to if the pace holds. Needs three full days of the month, so
    /// a first-of-the-month reading cannot project a whole month from one drive.
    static func monthEndProjection(monthToDate: Double, now: Date = Date(), calendar: Calendar = .current) -> Double? {
        guard monthToDate > 0, let interval = calendar.dateInterval(of: .month, for: now),
              let totalDays = calendar.range(of: .day, in: .month, for: now)?.count else { return nil }
        let elapsed = now.timeIntervalSince(interval.start) / 86_400
        guard elapsed >= 3 else { return nil }
        return monthToDate / elapsed * Double(totalDays)
    }

    // MARK: - Warranty

    struct BatteryWarrantyOutlook: Equatable, Sendable {
        let kilometresLeft: Double
        /// When the distance limit is reached at the recorded pace; `nil` without a pace.
        let reachesLimitOn: Date?
        /// True when the distance limit runs out before the date limit does.
        let distanceRunsOutFirst: Bool
    }

    static func batteryWarrantyOutlook(
        odometerKm: Double, limitKm: Int?, validUntil: Date?, kmPerDay: Double?, now: Date = Date()
    ) -> BatteryWarrantyOutlook? {
        guard let limitKm, limitKm > 0 else { return nil }
        let left = max(0, Double(limitKm) - odometerKm)
        let reaches = kmPerDay.flatMap { $0 > 0 ? now.addingTimeInterval(left / $0 * 86_400) : nil }
        let firstByDistance = reaches.map { date in validUntil.map { date < $0 } ?? true } ?? false
        return BatteryWarrantyOutlook(kilometresLeft: left, reachesLimitOn: reaches, distanceRunsOutFirst: firstByDistance)
    }
}
