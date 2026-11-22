import Foundation

/// Swedish electricity spot-price areas (ELSPOT/entsoe bidding zones). Sweden is divided
/// into four zones; the elprisetjustnu.se API serves one static JSON file per zone and day.
enum ElspotZone: String, CaseIterable, Codable, Sendable, Identifiable {
    case se1 = "SE1"
    case se2 = "SE2"
    case se3 = "SE3"
    case se4 = "SE4"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .se1: return L10n.text("SE1 · Luleå")
        case .se2: return L10n.text("SE2 · Sundsvall")
        case .se3: return L10n.text("SE3 · Stockholm")
        case .se4: return L10n.text("SE4 · Malmö")
        }
    }
}

/// One market price interval as published by elprisetjustnu.se. The JSON keys are the
/// API's own; before 2025-10-01 each point covers an hour, after that a quarter – the
/// planner treats points as arbitrary-duration slots, so both shapes work unchanged.
struct ElectricityPricePoint: Codable, Equatable, Sendable {
    var startDate: Date
    var endDate: Date
    var sekPerKwh: Double
    /// Tibber's own level for the slot. Not stored: only the live Tibber series carries it.
    var level: TibberPriceLevel? = nil

    enum CodingKeys: String, CodingKey {
        case startDate = "time_start"
        case endDate = "time_end"
        case sekPerKwh = "SEK_per_kWh"
    }
}

/// The cheapest contiguous whole-hour window that covers the energy still needed to
/// reach the vehicle's charge limit. Pure value type so the search itself stays
/// unit-testable against both hourly and quarterly (kvart) price series.
struct ChargingPlan: Equatable, Sendable {
    var start: Date
    var end: Date
    /// Hours the window spans. A quarter-hourly price gives a window that can end on a quarter,
    /// so this is a fraction, not a whole number.
    var hours: Double
    var energyKwh: Double
    /// SEK/kWh averaged over the window.
    var averagePrice: Double
    /// SEK/kWh at the moment the plan was computed – the do-nothing baseline.
    var currentPrice: Double
    /// Positive when waiting for the window beats charging immediately.
    var savings: Double
}

enum ChargingPlanner {
    /// Slide a fixed-duration window across every future price slot and keep the run
    /// with the lowest energy-weighted average price. Works for any slot granularity
    /// (hourly, quarterly, or a mix) because windows are accumulated in seconds, not
    /// in slot counts. Ties resolve to the earliest window.
    /// `granularity` is the shortest window the reader's price can express: an hour for an hourly
    /// contract, a quarter hour for a 15-minute one. The run length is rounded up to a whole number
    /// of steps, so a quarter-hourly plan can propose 1 h 15 min where an hourly one would say 2 h.
    static func cheapestWindow(
        prices: [ElectricityPricePoint],
        now: Date,
        energyKwh: Double,
        chargerPowerKw: Double,
        granularity: TimeInterval = 3_600
    ) -> ChargingPlan? {
        guard energyKwh > 0, chargerPowerKw > 0 else { return nil }
        let slots = prices
            .filter { $0.endDate > now }
            .sorted { $0.startDate == $1.startDate ? $0.endDate < $1.endDate : $0.startDate < $1.startDate }
        guard !slots.isEmpty else { return nil }

        // At least one step, rounded up to a whole number of them: "02:00–03:15" at quarter-hourly
        // prices, "02:00–04:00" at hourly ones.
        let step = max(60, granularity)
        let neededSeconds = (energyKwh / chargerPowerKw) * 3_600
        let targetSeconds = max(step, (neededSeconds / step).rounded(.up) * step)
        let hours = targetSeconds / 3_600
        let current = currentPrice(prices: prices, at: now) ?? slots[0].sekPerKwh

        var bestAverage: Double?
        var bestStart = Date.distantPast

        for start in slots.indices {
            var accumulatedSeconds = 0.0
            var accumulatedCost = 0.0
            var index = start
            while index < slots.count, accumulatedSeconds < targetSeconds {
                let slot = slots[index]
                let from = max(slot.startDate, now)
                let seconds = slot.endDate.timeIntervalSince(from)
                if seconds > 0 {
                    accumulatedSeconds += seconds
                    accumulatedCost += seconds * slot.sekPerKwh
                }
                index += 1
            }
            guard accumulatedSeconds >= targetSeconds else { continue }
            let average = accumulatedCost / accumulatedSeconds
            if bestAverage == nil || average < bestAverage! {
                bestAverage = average
                bestStart = max(slots[start].startDate, now)
            }
        }

        guard let average = bestAverage else { return nil }
        let start = bestStart
        let end = start.addingTimeInterval(targetSeconds)
        return ChargingPlan(
            start: start,
            end: end,
            hours: hours,
            energyKwh: energyKwh,
            averagePrice: average,
            currentPrice: current,
            savings: (current - average) * energyKwh
        )
    }

    /// A flat rate's own series, an hour at a time. There is no market file behind a fixed rate, so
    /// the planner gets one synthetic hour per hour: with a single price the window lands as early as
    /// the horizon allows and the saving is nothing, which is the truth. A night tariff, when the
    /// reader has opted into one, is honoured inside its window and makes the window worth choosing.
    static func fixedSeries(
        dayPricePerKwh: Double,
        nightPricePerKwh: Double? = nil,
        nightStartHour: Int = 22,
        nightEndHour: Int = 6,
        from now: Date,
        length: TimeInterval = 48 * 3_600,
        calendar: Calendar = ElectricityPriceService.stockholmCalendar
    ) -> [ElectricityPricePoint] {
        guard let hour = calendar.dateInterval(of: .hour, for: now) else { return [] }
        let day = max(0, dayPricePerKwh)
        let night = nightPricePerKwh.map { max(0, $0) }
        let limit = now.addingTimeInterval(length)
        var points: [ElectricityPricePoint] = []
        var start = hour.start
        while start < limit {
            let end = start.addingTimeInterval(3_600)
            let hourOfDay = calendar.component(.hour, from: start)
            let isNight = night != nil && (nightStartHour <= nightEndHour
                ? hourOfDay >= nightStartHour && hourOfDay < nightEndHour
                : hourOfDay >= nightStartHour || hourOfDay < nightEndHour)
            points.append(ElectricityPricePoint(
                startDate: start, endDate: end, sekPerKwh: isNight ? (night ?? day) : day
            ))
            start = end
        }
        return points
    }

    /// The price in effect at the given instant, preferring the latest overlapping slot.
    static func currentPrice(prices: [ElectricityPricePoint], at date: Date) -> Double? {
        prices
            .filter { $0.startDate <= date && $0.endDate > date }
            .max { $0.startDate < $1.startDate }?
            .sekPerKwh
    }

    enum FixedWindow {
        case missingPrices, unavailable, available(DateInterval)
    }

    static func cheapestWindow(
        prices: [ElectricityPricePoint], within range: DateInterval, duration: TimeInterval,
        canSchedule: (DateInterval) -> Bool
    ) -> FixedWindow {
        guard duration > 0, duration <= range.duration else { return .unavailable }
        let slots = prices.filter { $0.startDate < range.end && $0.endDate > range.start }
            .sorted { $0.startDate < $1.startDate }
        var coveredUntil = range.start
        for slot in slots {
            guard slot.endDate > slot.startDate, slot.sekPerKwh.isFinite,
                  max(slot.startDate, range.start) == coveredUntil else { return .missingPrices }
            coveredUntil = slot.endDate
        }
        guard coveredUntil >= range.end else { return .missingPrices }

        var best: DateInterval?
        var bestCost = Double.infinity
        var start = Date(timeIntervalSince1970: (range.start.timeIntervalSince1970 / 60).rounded(.up) * 60)
        while start.addingTimeInterval(duration) <= range.end {
            let end = start.addingTimeInterval(duration)
            let window = DateInterval(start: start, end: end)
            let cost = slots.reduce(0.0) { total, slot in
                let seconds = min(end, slot.endDate).timeIntervalSince(max(start, slot.startDate))
                return total + max(0, seconds) * slot.sekPerKwh
            }
            if cost < bestCost - 0.000_001, canSchedule(window) {
                best = window
                bestCost = cost
            }
            start = start.addingTimeInterval(60)
        }
        return best.map(FixedWindow.available) ?? .unavailable
    }

    /// Last instant the series can speak for – used to tell "tomorrow not published yet"
    /// apart from "no data at all".
    static func dataHorizonEnd(prices: [ElectricityPricePoint]) -> Date? {
        prices.map(\.endDate).max()
    }
}

/// Shared planning inputs for the dashboard card and the background controller, so the
/// two can never drift apart. Includes the estimated round-trip AC charging loss between
/// what the outlet delivers and what lands in the pack – hours and costs are computed on
/// grid-side energy, which is what the meter, and the bill, actually sees.
enum ChargingPlannerSupport {
    static let chargingLossFactor: Double = 1.1

    /// Energy that must flow from the grid to move from the current level to the charge
    /// limit, including the AC charging loss. Returns 0 when inputs are missing or the
    /// battery already sits at or above the limit.
    static func neededEnergyKwh(batteryPercentage: Double?, targetPercentage: Int?, usableCapacityKwh: Double) -> Double {
        guard let battery = batteryPercentage,
              let target = targetPercentage,
              target > Int(battery),
              usableCapacityKwh > 0 else { return 0 }
        let storedKwh = (Double(target) - battery) / 100 * usableCapacityKwh
        return storedKwh * chargingLossFactor
    }

    /// The charging rate to plan with: the live rate while the vehicle is charging,
    /// otherwise the charger output configured in Settings.
    static func powerKw(liveWatts: Int?, isCharging: Bool, configuredKw: Double) -> Double {
        let liveKw = isCharging ? liveWatts.map { Double($0) / 1_000 } : nil
        return (liveKw ?? 0) > 0 ? liveKw! : configuredKw
    }

    /// Approximate spot-price zone from a latitude. The real zone borders run through
    /// sparsely populated areas and bend around municipalities, so this is a *suggestion*
    /// for the Settings picker, never an automatic assignment. Thresholds (north → south):
    /// Umeå (63.8°N) lands in SE2, Uppsala (59.9°N) in SE3, Gothenburg and Visby
    /// (57.6–57.7°N) in SE4.
    static func suggestedZone(latitude: Double) -> ElspotZone {
        switch latitude {
        case 64.0...: return .se1
        case 60.2..<64.0: return .se2
        case 58.0..<60.2: return .se3
        default: return .se4
        }
    }
}

/// Pure decisions for the background planner controller, extracted so the notification
/// and auto-start behaviour stays unit-testable without timers or the notification center.
enum ChargingPlannerDecisions {
    /// Notify once per window, from `leadMinutes` before it opens until it ends – an app
    /// launched mid-window still earns the notice, a relaunch inside the same window does
    /// not repeat it.
    ///
    /// Dedupe keys on the announced window's *end*, not its start: while "charge now" is
    /// cheapest, the recomputed plan starts at `now` and slides a minute forward on every
    /// tick, so a start-keyed dedupe re-announces every minute. The sliding plan still
    /// overlaps the window already announced, so it stays quiet until a plan begins at or
    /// after the announced end – a genuinely later window.
    static func shouldNotifyWindowStart(
        plan: ChargingPlan,
        now: Date,
        leadMinutes: Int,
        announcedWindowEnd: Date?
    ) -> Bool {
        guard now >= plan.start.addingTimeInterval(TimeInterval(-leadMinutes * 60)),
              now < plan.end else { return false }
        guard let announcedWindowEnd else { return true }
        return plan.start >= announcedWindowEnd
    }

    /// Start charging automatically only strictly inside the planned window, when the
    /// vehicle is plugged in but not already charging. Never fires at or above the
    /// charge limit – the plan itself is nil then.
    static func shouldAutoStartCharging(
        plan: ChargingPlan,
        now: Date,
        connection: ChargerConnection,
        chargingState: ChargingState
    ) -> Bool {
        now >= plan.start && now < plan.end
            && connection == .connected
            && !chargingState.isActivelyCharging
    }

    /// End the planner's own charge-now override at the committed window's end, while the car
    /// is still drawing power. The window's end is fixed when the start is sent; without this
    /// a car that charges slower than planned keeps the override into the hours after the
    /// cheap window and runs to target instead of stopping.
    ///
    /// Nothing is sent once the window is old enough that the app cannot say who started the
    /// charge. A stop that would arrive hours late is more likely to interrupt a manual charge
    /// than to finish the plan.
    static let stopWindowGrace: TimeInterval = 60 * 60

    static func shouldStopChargingAtWindowEnd(
        window: DateInterval?,
        now: Date,
        connection: ChargerConnection,
        chargingState: ChargingState
    ) -> Bool {
        guard let window, now >= window.end else { return false }
        guard now < window.end.addingTimeInterval(stopWindowGrace) else { return false }
        return connection == .connected && chargingState.isActivelyCharging
    }

    /// The planner's sleep assertion is worth holding only while a window is still ahead or
    /// running, and only when both consents that make the planner act are on.
    static func shouldPreventSleep(
        window: DateInterval?,
        now: Date,
        autoStartEnabled: Bool,
        keepAwakeEnabled: Bool
    ) -> Bool {
        guard autoStartEnabled, keepAwakeEnabled, let window else { return false }
        return now < window.end
    }
}
