import Foundation

/// A whole-house electricity meter Hisingen reads, as the reader picks it during setup. Today that is
/// a Perific (formerly Enegic) monitor on the meter's HAN port. The meter is read only: Hisingen never
/// sends it anything, and the load balancing it does for the charger stays with Perific.
struct HouseMeter: Codable, Equatable, Identifiable, Sendable {
    /// The vendor's stable item id. The name is the reader's own and can change.
    var id: String
    var name: String
    /// The zone the vendor labels history in. Its timestamps carry no offset.
    var timeZoneIdentifier: String?

    var timeZone: TimeZone { timeZoneIdentifier.flatMap(TimeZone.init(identifier:)) ?? .current }
}

/// One supply phase as the house meter measures it. Current is signed: positive is power taken from
/// the grid, negative is power sent back.
struct HouseMeterPhase: Equatable, Sendable {
    var amps: Double
    var volts: Double
    var watts: Double { amps * volts }
}

/// The meter's latest packet, reduced to what the card and the settings readout need.
struct HouseMeterReading: Equatable, Sendable {
    /// A reading older than this is shown as last known. The meter reports about every ten seconds
    /// and Hisingen reads every thirty, so three minutes means several reads were missed.
    static let staleAfter: TimeInterval = 180

    /// When the meter took the reading, from the packet and not from the poll.
    var observedAt: Date
    var phases: [HouseMeterPhase]
    /// The packet carried no voltage, so a nominal 230 V stands in for it. Power is rougher then.
    var voltageAssumed = false
    /// Cumulative registers from the minute packet, in kWh. They only ever rise.
    var importedKwh: Double?
    var exportedKwh: Double?
    /// When the minute packet took the registers. It trails `observedAt` by up to a minute.
    var registersAt: Date?
    /// The same registers at the end of the last completed day, which is local midnight. Today is
    /// this pair subtracted from the minute pair, so no history request is needed for it.
    var dayRegister: DayRegister?

    struct DayRegister: Equatable, Sendable {
        /// When that day started, from its own packet: local midnight of yesterday.
        var startedAt: Date
        var importedKwh: Double
        var exportedKwh: Double
    }

    /// Current times voltage, summed over the phases. That is apparent power: with a poor power
    /// factor it reads a little above the energy the meter bills.
    var netWatts: Double { phases.reduce(0) { $0 + $1.watts } }
    var importKw: Double { max(0, netWatts) / 1_000 }
    var exportKw: Double { max(0, -netWatts) / 1_000 }

    func age(now: Date) -> TimeInterval { max(0, now.timeIntervalSince(observedAt)) }
    func isCurrent(now: Date) -> Bool { age(now: now) <= Self.staleAfter }
}

/// A cumulative register pair at one moment, from the meter's per-minute history.
struct HouseMeterRegisterPoint: Equatable, Sendable {
    var at: Date
    var importedKwh: Double
    var exportedKwh: Double
}

/// What the meter counted between two register readings, typically from midnight until now.
struct HouseMeterSpan: Equatable, Sendable {
    var from: Date
    var to: Date
    var importedKwh: Double
    var exportedKwh: Double
}

enum HouseMeterHistory {
    /// More than this in one hour is not something a home supply can draw (a 63 A three-phase
    /// connection is about 43 kW), so a larger step is the register being set, not consumption.
    /// A real installation did exactly that: on its first day the register went from 0 to the
    /// meter's lifetime total, 61,011 kWh, in one minute.
    static let maximumKwhPerHour = 100.0

    /// Energy between the first and last register reading in `points`. `nil` with fewer than two
    /// readings, or when a register went backwards (a device reset), because a difference across
    /// a reset is not a measurement.
    static func span(_ points: [HouseMeterRegisterPoint]) -> HouseMeterSpan? {
        let sorted = points.sorted { $0.at < $1.at }
        guard let first = sorted.first, let last = sorted.last, last.at > first.at,
              last.importedKwh >= first.importedKwh, last.exportedKwh >= first.exportedKwh else { return nil }
        let hours = max(1, last.at.timeIntervalSince(first.at) / 3_600)
        guard last.importedKwh - first.importedKwh <= maximumKwhPerHour * hours,
              last.exportedKwh - first.exportedKwh <= maximumKwhPerHour * hours else { return nil }
        return HouseMeterSpan(from: first.at, to: last.at,
                              importedKwh: last.importedKwh - first.importedKwh,
                              exportedKwh: last.exportedKwh - first.exportedKwh)
    }

    /// Today's energy from the live packets rather than the history: the day packet carries the
    /// registers at the end of the last completed day, which is local midnight, and the minute
    /// packet carries them now. `nil` when a packet is missing, or when the day packet does not
    /// cover the day that just ended, because then the difference spans more than today.
    static func today(_ reading: HouseMeterReading, in timeZone: TimeZone) -> HouseMeterSpan? {
        guard let at = reading.registersAt,
              let imported = reading.importedKwh, let exported = reading.exportedKwh,
              let day = reading.dayRegister else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let midnight = calendar.startOfDay(for: at)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: midnight),
              calendar.isDate(day.startedAt, inSameDayAs: yesterday) else { return nil }
        return span([
            HouseMeterRegisterPoint(at: midnight, importedKwh: day.importedKwh, exportedKwh: day.exportedKwh),
            HouseMeterRegisterPoint(at: at, importedKwh: imported, exportedKwh: exported)
        ])
    }

    /// Whole-house hours of grid import, from register readings taken on the hour. An hour needs
    /// both its edges: a missing minute leaves that hour out, and so does a register that fell or
    /// jumped by more than a home can draw.
    /// The result feeds the same car-share calculation as Tibber's hourly readings.
    static func hourlyImport(_ points: [HouseMeterRegisterPoint]) -> [TibberConsumptionHour] {
        var onTheHour: [Int: Double] = [:]
        for point in points {
            let seconds = Int(point.at.timeIntervalSince1970.rounded())
            if seconds % 3_600 == 0 { onTheHour[seconds] = point.importedKwh }
        }
        return onTheHour.keys.sorted().compactMap { start in
            guard let begin = onTheHour[start], let end = onTheHour[start + 3_600], end >= begin,
                  end - begin <= maximumKwhPerHour else { return nil }
            return TibberConsumptionHour(start: Date(timeIntervalSince1970: TimeInterval(start)),
                                         end: Date(timeIntervalSince1970: TimeInterval(start + 3_600)),
                                         kwh: end - begin)
        }
    }
}

/// The house meter's part of the charging card and the settings readout, resolved to words.
struct HouseMeterPresentation: Equatable {
    struct Detail: Equatable, Identifiable {
        var label: String
        var value: String
        var info: String?
        var id: String { label }
    }

    /// `House 3.2 kW`, or `House sending 1.1 kW to the grid`. `nil` until a reading arrives.
    var houseLine: String?
    /// The figure alone, for a row that already says "House": `3.4 kW`, or `1.1 kW to the grid`.
    var houseValue: String?
    /// False when the line shows the last reading received rather than a current one.
    var isLive = false
    /// While the car charges: `Car 2.3 kW, rest of the house 0.9 kW`. Only when both readings are
    /// current and agree closely enough to subtract.
    var splitLine: String?
    /// Set when the reading is last known, or the meter cannot be reached.
    var freshnessLine: String?
    var details: [Detail]

    static func make(reading: HouseMeterReading?, span: HouseMeterSpan?, carKw: Double?, now: Date) -> HouseMeterPresentation {
        guard let reading else { return HouseMeterPresentation(houseLine: nil, splitLine: nil, freshnessLine: nil, details: []) }
        let current = reading.isCurrent(now: now)
        let houseLine: String
        let houseValue: String
        if reading.exportKw >= 0.1 {
            houseLine = L10n.format("House sending %@ to the grid", Format.powerKw(reading.exportKw))
            houseValue = L10n.format("%@ to the grid", Format.powerKw(reading.exportKw))
        } else {
            houseLine = L10n.format("House %@", Format.powerKw(reading.importKw))
            houseValue = Format.powerKw(reading.importKw)
        }

        var split: String?
        if current, let carKw, carKw >= HomeChargerTelemetry.zeroPowerThresholdKw, reading.importKw >= carKw * 0.9 {
            split = L10n.format("Car %@, rest of the house %@", Format.powerKw(carKw),
                                Format.powerKw(max(0, reading.importKw - carKw)))
        }

        var freshness: String?
        if !current {
            freshness = L10n.format("House meter last read %@ ago", Format.shortDuration(minutes: max(1, Int(reading.age(now: now) / 60))))
        }

        var rows: [Detail] = []
        let phases = reading.phases.filter { $0.volts >= HomeChargerPhase.energisedVolts }
        if current, !phases.isEmpty {
            let volts = phases.map { Format.number($0.volts, decimals: 0) }.joined(separator: " · ")
            let amps = phases.map { Format.number($0.amps, decimals: 1) }.joined(separator: " · ")
            rows.append(Detail(label: L10n.text("House Voltage"), value: L10n.format("%@ V", volts),
                               info: reading.voltageAssumed
                                   ? L10n.text("The meter sent no voltage, so 230 V is assumed and power is approximate.") : nil))
            rows.append(Detail(label: L10n.text("House Current per Phase"), value: L10n.format("%@ A", amps)))
        }
        if let span {
            rows.append(Detail(label: L10n.text("Imported Today"), value: Format.energyKwh(span.importedKwh)))
            if span.exportedKwh >= 0.05 {
                rows.append(Detail(label: L10n.text("Exported Today"), value: Format.energyKwh(span.exportedKwh)))
            }
        }
        return HouseMeterPresentation(houseLine: houseLine, houseValue: houseValue, isLive: current, splitLine: split, freshnessLine: freshness, details: rows)
    }
}
