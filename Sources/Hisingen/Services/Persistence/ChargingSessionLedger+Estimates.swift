import Foundation

/// Read-time estimate policies tolerate much wider polling gaps than the authoritative
/// summary: a long, slow AC session polled only once an hour is a perfectly ordinary
/// cadence, and discarding its intervals would understate delivered energy for loss and
/// cost purposes (where the estimate is explicitly provisional).
extension ChargingSessionLedger {
    struct TariffCost: Equatable {
        let dayEnergyKwh: Double
        let nightEnergyKwh: Double
        let cost: Double
    }

    /// An interval between consecutive samples longer than this is treated as a polling gap
    /// (e.g. the vehicle was unplugged and replugged elsewhere) rather than continuous
    /// charging, in the read-time estimators below.
    static let maximumEstimateSampleGap: TimeInterval = 3 * 3_600

    /// Splits a session's sample-integrated energy into day/night buckets by each interval's
    /// local hour and prices each bucket separately – materially more accurate than
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
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            // Split at hour boundaries so a long interval straddling a tariff switch
            // is not priced entirely at the midpoint rate. Power is interpolated
            // linearly within each slice for trapezoidal accuracy.
            var cursor = a.timestamp
            let end = b.timestamp
            var slicedNight = 0.0
            var slicedTotal = 0.0
            var sliced = false
            while cursor < end {
                let comps = calendar.dateComponents([.year, .month, .day, .hour], from: cursor)
                guard let hourStart = calendar.date(from: comps),
                      let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
                let sliceEnd = min(nextHour, end)
                let sliceSeconds = sliceEnd.timeIntervalSince(cursor)
                guard sliceSeconds > 0 else { break }
                let fraction = sliceSeconds / interval
                let offsetAtCursor = cursor.timeIntervalSince(a.timestamp) / interval
                let powerAtCursor = p0 + (p1 - p0) * offsetAtCursor
                let powerAtSliceEnd = p0 + (p1 - p0) * (offsetAtCursor + fraction)
                let sliceEnergy = (powerAtCursor + powerAtSliceEnd) / 2 * (sliceSeconds / 3_600)
                slicedTotal += sliceEnergy
                if isNight(cursor.addingTimeInterval(sliceSeconds / 2)) { slicedNight += sliceEnergy }
                cursor = sliceEnd
                sliced = true
                if slicedTotal > 1_000_000 { break }
            }
            if sliced && slicedTotal > 0 {
                nightKwh += slicedNight
                dayKwh += slicedTotal - slicedNight
            } else {
                let midpoint = a.timestamp.addingTimeInterval(interval / 2)
                let energy = (p0 + p1) / 2 * (interval / 3_600)
                if isNight(midpoint) { nightKwh += energy } else { dayKwh += energy }
            }
        }
        guard dayKwh + nightKwh > 0 else { return nil }
        return TariffCost(dayEnergyKwh: dayKwh, nightEnergyKwh: nightKwh,
                          cost: dayKwh * dayRatePerKwh + nightKwh * nightRatePerKwh)
    }

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
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            energyInputKwh += (p0 + p1) / 2 * (interval / 3_600)
        }
        guard energyInputKwh > 0 else { return nil }
        let storedKwh = packCapacityKwh * (last.soc - first.soc) / 100
        let lossPct = (1 - storedKwh / energyInputKwh) * 100
        return (0...40).contains(lossPct) ? lossPct : nil
    }
}
