import Foundation
import Testing
@testable import Hisingen

/// Stockholm-local calendar used to build fixtures at fixed wall-clock hours.
private let plannerFixtureCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar
}()

/// A fixed wall-clock instant in Stockholm time, e.g. 2026-02-10 03:00.
private func fixtureDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    plannerFixtureCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// A series of `count` slots, each `slotHours` long, starting at the given hour.
private func fixtureSeries(startingAt start: Date, count: Int, slotHours: Double, prices: [Double]) -> [ElectricityPricePoint] {
    (0..<count).map { index in
        let slotStart = start.addingTimeInterval(Double(index) * slotHours * 3_600)
        return ElectricityPricePoint(
            startDate: slotStart,
            endDate: slotStart.addingTimeInterval(slotHours * 3_600),
            sekPerKwh: prices[index % prices.count]
        )
    }
}

struct ChargingPlannerTests {

    // MARK: - Hourly prices

    @Test
    func picksCheapestContiguousHourlyWindow() {
        // Prices 00–24 on Feb 10; cheap valley 02:00–05:00, spike at noon.
        let prices: [Double] = [2.0, 1.5, 0.5, 0.4, 0.6, 1.2, 2.2, 3.0, 3.5, 4.0, 4.5, 5.0,
                                5.5, 5.0, 4.0, 3.0, 2.5, 2.0, 1.8, 1.6, 1.4, 1.3, 1.2, 1.1]
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 24, slotHours: 1, prices: prices)
        // At 03:00 the 00–03 valley is partially gone; the cheapest full 2 h window is 03:00–05:00.
        let plan = ChargingPlanner.cheapestWindow(
            prices: points,
            now: fixtureDate(2026, 2, 10, 3),
            energyKwh: 14,
            chargerPowerKw: 7.0
        )
        #expect(plan != nil)
        #expect(plan?.hours == 2)
        #expect(plan?.start == fixtureDate(2026, 2, 10, 3))
        #expect(plan?.end == fixtureDate(2026, 2, 10, 5))
        #expect(abs((plan?.averagePrice ?? 0) - 0.5) < 0.0001)
        #expect(plan?.currentPrice == 0.4) // the slot covering 03:00–04:00
        let expectedSavings = ((plan?.currentPrice ?? 0) - (plan?.averagePrice ?? 0)) * 14
        #expect(abs((plan?.savings ?? 0) - expectedSavings) < 1e-9)
    }

    @Test
    func skipsPastSlots() {
        let prices: [Double] = [0.1, 0.1, 9.0, 9.0, 1.0, 1.0, 1.0, 1.0]
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 8, slotHours: 1, prices: prices)
        let plan = ChargingPlanner.cheapestWindow(
            prices: points,
            now: fixtureDate(2026, 2, 10, 2),
            energyKwh: 2,
            chargerPowerKw: 1.0
        )
        // The 0.1 kr slots are in the past; cheapest future 2 h window is 04:00–06:00.
        #expect(plan?.start == fixtureDate(2026, 2, 10, 4))
    }

    // MARK: - Quarterly (kvart) prices

    @Test
    func quarterlyPricesProduceWholeHourWindow() {
        // 24 h of quarter slots: cheapest quarter price 0.2 in 02:00–02:45, rest 1.0, spike 3.0 at noon hour.
        var points: [ElectricityPricePoint] = []
        let start = fixtureDate(2026, 2, 10, 0)
        for index in 0..<96 {
            let slotStart = start.addingTimeInterval(Double(index) * 900)
            let hour = index / 4
            let quarter = index % 4
            let price: Double
            if hour == 12 { price = 3.0 }
            else if hour == 2 && quarter < 3 { price = 0.2 }
            else { price = 1.0 }
            points.append(ElectricityPricePoint(startDate: slotStart, endDate: slotStart.addingTimeInterval(900), sekPerKwh: price))
        }
        let plan = ChargingPlanner.cheapestWindow(
            prices: points,
            now: fixtureDate(2026, 2, 10, 1),
            energyKwh: 11,
            chargerPowerKw: 11.0
        )
        #expect(plan != nil)
        #expect(plan?.hours == 1)
        // A one-hour window, not a 15-minute slice at the single cheap quarter. The
        // earliest equal-cost window starts 01:45 and wraps the three cheap quarters.
        #expect(plan?.start == fixtureDate(2026, 2, 10, 1, 45))
        #expect(plan?.end == fixtureDate(2026, 2, 10, 2, 45))
        // 3 cheap quarters (0.2) + 1 at 1.0 → weighted average 0.4.
        #expect(abs((plan?.averagePrice ?? 0) - 0.4) < 0.0001)
    }

    // MARK: - Edge cases

    @Test
    func returnsNilWithoutEnergyOrPrices() {
        #expect(ChargingPlanner.cheapestWindow(prices: [], now: Date(), energyKwh: 10, chargerPowerKw: 7) == nil)
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 5, slotHours: 1, prices: [1.0, 1.0, 1.0, 1.0, 1.0])
        #expect(ChargingPlanner.cheapestWindow(prices: points, now: fixtureDate(2026, 2, 10, 0), energyKwh: 0, chargerPowerKw: 7) == nil)
        #expect(ChargingPlanner.cheapestWindow(prices: points, now: fixtureDate(2026, 2, 10, 0), energyKwh: 10, chargerPowerKw: 0) == nil)
    }

    @Test
    func returnsNilWhenHorizonTooShort() {
        // Only 3 h of data; a 5 h window can never fit.
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 3, slotHours: 1, prices: [1.0, 1.0, 1.0])
        #expect(ChargingPlanner.cheapestWindow(prices: points, now: fixtureDate(2026, 2, 10, 0), energyKwh: 5, chargerPowerKw: 1) == nil)
    }

    @Test
    func tieResolvesToEarliestWindow() {
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 8, slotHours: 1, prices: [1.0])
        let plan = ChargingPlanner.cheapestWindow(
            prices: points,
            now: fixtureDate(2026, 2, 10, 0),
            energyKwh: 2,
            chargerPowerKw: 1.0
        )
        #expect(plan?.start == fixtureDate(2026, 2, 10, 0))
    }

    @Test
    func currentPricePrefersLatestCoveringSlot() {
        let points = fixtureSeries(startingAt: fixtureDate(2026, 2, 10, 0), count: 4, slotHours: 1, prices: [1.0, 2.0, 3.0, 4.0])
        #expect(ChargingPlanner.currentPrice(prices: points, at: fixtureDate(2026, 2, 10, 1, 30)) == 2.0)
        #expect(ChargingPlanner.currentPrice(prices: points, at: fixtureDate(2026, 2, 9, 23)) == nil)
        #expect(ChargingPlanner.dataHorizonEnd(prices: points) == fixtureDate(2026, 2, 10, 4))
    }
}

struct ElectricityPriceServiceDateTests {
    private var calendar: Calendar { plannerFixtureCalendar }

    @Test
    func nextFetchDateLandsAtPublicationTime() {
        // Before 14:15 → today's 14:15.
        #expect(ElectricityPriceService.nextFetchDate(after: fixtureDate(2026, 2, 10, 9)) == fixtureDate(2026, 2, 10, 14, 15))
        // Exactly at 14:15 → tomorrow's 14:15 (today's run is happening right now).
        #expect(ElectricityPriceService.nextFetchDate(after: fixtureDate(2026, 2, 10, 14, 15)) == fixtureDate(2026, 2, 11, 14, 15))
        // Late evening → tomorrow 14:15.
        #expect(ElectricityPriceService.nextFetchDate(after: fixtureDate(2026, 2, 10, 23)) == fixtureDate(2026, 2, 11, 14, 15))
        // Month rollover.
        #expect(ElectricityPriceService.nextFetchDate(after: fixtureDate(2026, 8, 31, 20)) == fixtureDate(2026, 9, 1, 14, 15))
    }

    @Test
    func urlMatchesApiContract() {
        let url = ElectricityPriceService.priceURL(zone: .se3, date: fixtureDate(2026, 9, 11, 15))
        #expect(url.absoluteString == "https://www.elprisetjustnu.se/api/v1/prices/2026/09-11_SE3.json")
        let firstOfMonth = ElectricityPriceService.priceURL(zone: .se1, date: fixtureDate(2026, 3, 1, 5))
        #expect(firstOfMonth.absoluteString == "https://www.elprisetjustnu.se/api/v1/prices/2026/03-01_SE1.json")
    }

    @Test
    func requiredCoverageFlipsAtPublication() {
        // Morning: today's file alone (through end of today) is enough.
        let morning = fixtureDate(2026, 2, 10, 9)
        #expect(ElectricityPriceService.requiredCoverageEnd(after: morning, calendar: calendar) == fixtureDate(2026, 2, 11, 0))
        // After 14:15: tomorrow must be covered too.
        let evening = fixtureDate(2026, 2, 10, 18)
        #expect(ElectricityPriceService.requiredCoverageEnd(after: evening, calendar: calendar) == fixtureDate(2026, 2, 12, 0))
    }

    @Test
    func freshCacheSkipsRefetch() {
        let points = stride(from: 0, to: 48, by: 1).map { hour -> ElectricityPricePoint in
            let start = fixtureDate(2026, 2, 10, 0).addingTimeInterval(Double(hour) * 3_600)
            return ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(3_600), sekPerKwh: 1.0)
        }
        // Fetched yesterday evening, covers through end of Feb 11 → fresh until Feb 11 14:15.
        let entry = ElectricityPriceService.CachedPrices(zone: .se3, points: points, fetchedAt: fixtureDate(2026, 2, 9, 18))
        #expect(ElectricityPriceService.isCacheFresh(entry, after: fixtureDate(2026, 2, 10, 9), calendar: calendar))
        #expect(ElectricityPriceService.isCacheFresh(entry, after: fixtureDate(2026, 2, 11, 14, 14), calendar: calendar))
        #expect(!ElectricityPriceService.isCacheFresh(entry, after: fixtureDate(2026, 2, 11, 14, 15), calendar: calendar))
    }
}

struct ElectricityPricePointDecodingTests {
    @Test
    func decodesPublishedApiShape() throws {
        // Verbatim shape from the elprisetjustnu.se API docs, including the +01:00 offset.
        let json = """
        [
          {
            "SEK_per_kWh": 1.50616,
            "EUR_per_kWh": 0.13823,
            "EXR": 10.896049,
            "time_start": "2022-11-24T00:00:00+01:00",
            "time_end": "2022-11-24T01:00:00+01:00"
          },
          {
            "SEK_per_kWh": 1.35449,
            "EUR_per_kWh": 0.12431,
            "EXR": 10.896049,
            "time_start": "2022-11-24T01:00:00+01:00",
            "time_end": "2022-11-24T02:00:00+01:00"
          }
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let points = try decoder.decode([ElectricityPricePoint].self, from: Data(json.utf8))
        #expect(points.count == 2)
        #expect(abs(points[0].sekPerKwh - 1.50616) < 0.000001)
        // 2022-11-24T00:00:00+01:00 == 2022-11-23T23:00:00Z.
        let expectedStart = Date(timeIntervalSince1970: 1_669_244_400) // 2022-11-23T23:00:00Z
        #expect(points[0].startDate == expectedStart)
        #expect(points[0].endDate == expectedStart.addingTimeInterval(3_600))
    }

    @Test
    func zoneRoundTripsThroughRawValue() {
        for zone in ElspotZone.allCases {
            #expect(ElspotZone(rawValue: zone.rawValue) == zone)
        }
        #expect(ElspotZone(rawValue: "SE9") == nil)
        #expect(ElspotZone.allCases.count == 4)
    }
}

struct ElectricityPriceCacheCodableTests {
    @Test
    func cachedPricesRoundTripThroughJSON() throws {
        var entry = ElectricityPriceService.CachedPrices(zone: .se4, points: [], fetchedAt: fixtureDate(2026, 2, 10, 14, 30))
        for hour in 0..<48 {
            let start = fixtureDate(2026, 2, 10, 0).addingTimeInterval(Double(hour) * 3_600)
            entry.points.append(ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(3_600), sekPerKwh: Double(hour)))
        }
        let data = try JSONEncoder().encode([ElspotZone.se4: entry])
        let decoded = try JSONDecoder().decode([ElspotZone: ElectricityPriceService.CachedPrices].self, from: data)
        #expect(decoded[.se4] == entry)
    }
}

struct ElectricityPriceStoreTests {
    @Test
    func saveLoadRoundTripKeepsOrderAndOverwrites() {
        let database = VehicleDatabase.inMemory()
        let store = database.electricityPrices
        #expect(store.prices(zone: .se3).isEmpty)

        var first = [ElectricityPricePoint]()
        for quarter in 0..<96 {
            let start = fixtureDate(2026, 2, 10, 0).addingTimeInterval(Double(quarter) * 900)
            first.append(ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(900), sekPerKwh: 1.0))
        }
        store.save(zone: .se3, points: first, fetchedAt: fixtureDate(2026, 2, 10, 14, 20))
        #expect(store.prices(zone: .se3) == first)
        #expect(store.fetchedAt(zone: .se3) == fixtureDate(2026, 2, 10, 14, 20))

        // A second fetch replaces the zone wholesale — no duplicate or stale intervals.
        var second = [ElectricityPricePoint]()
        for hour in 0..<48 {
            let start = fixtureDate(2026, 2, 11, 0).addingTimeInterval(Double(hour) * 3_600)
            second.append(ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(3_600), sekPerKwh: 0.5))
        }
        store.save(zone: .se3, points: second, fetchedAt: fixtureDate(2026, 2, 11, 14, 20))
        #expect(store.prices(zone: .se3) == second)
        #expect(store.fetchedAt(zone: .se3) == fixtureDate(2026, 2, 11, 14, 20))
    }

    @Test
    func zonesAreIsolated() {
        let database = VehicleDatabase.inMemory()
        let store = database.electricityPrices
        let start = fixtureDate(2026, 2, 10, 0)
        let se1Point = ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(3_600), sekPerKwh: 0.9)
        let se4Point = ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(3_600), sekPerKwh: 1.1)
        store.save(zone: .se1, points: [se1Point], fetchedAt: start)
        store.save(zone: .se4, points: [se4Point], fetchedAt: start)
        #expect(store.prices(zone: .se1) == [se1Point])
        #expect(store.prices(zone: .se4) == [se4Point])
        #expect(store.prices(zone: .se2).isEmpty)
        #expect(store.fetchedAt(zone: .se2) == nil)
    }

    @Test
    func removeAllClearsEveryZone() {
        let database = VehicleDatabase.inMemory()
        let store = database.electricityPrices
        let start = fixtureDate(2026, 2, 10, 0)
        store.save(zone: .se2, points: [ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(900), sekPerKwh: 0.4)], fetchedAt: start)
        store.removeAll()
        #expect(store.prices(zone: .se2).isEmpty)
        #expect(store.fetchedAt(zone: .se2) == nil)
    }
}

struct ChargingPlannerSupportTests {
    @Test
    func neededEnergyAppliesLossFactorAndGuards() {
        // 90% of a 50 kWh pack = 45 kWh stored; grid-side adds the loss factor.
        let energy = ChargingPlannerSupport.neededEnergyKwh(batteryPercentage: 10, targetPercentage: 100, usableCapacityKwh: 50)
        #expect(abs(energy - 45.0 * ChargingPlannerSupport.chargingLossFactor) < 0.0001)
        #expect(ChargingPlannerSupport.neededEnergyKwh(batteryPercentage: 90, targetPercentage: 90, usableCapacityKwh: 50) == 0)
        #expect(ChargingPlannerSupport.neededEnergyKwh(batteryPercentage: 95, targetPercentage: 90, usableCapacityKwh: 50) == 0)
        #expect(ChargingPlannerSupport.neededEnergyKwh(batteryPercentage: nil, targetPercentage: 90, usableCapacityKwh: 50) == 0)
        #expect(ChargingPlannerSupport.neededEnergyKwh(batteryPercentage: 50, targetPercentage: 90, usableCapacityKwh: 0) == 0)
    }

    @Test
    func powerPrefersLiveRateWhileCharging() {
        #expect(ChargingPlannerSupport.powerKw(liveWatts: 7_200, isCharging: true, configuredKw: 3.7) == 7.2)
        // A live rate only counts while charging; idle non-zero watts fall back.
        #expect(ChargingPlannerSupport.powerKw(liveWatts: 7_200, isCharging: false, configuredKw: 11.0) == 11.0)
        #expect(ChargingPlannerSupport.powerKw(liveWatts: nil, isCharging: true, configuredKw: 11.0) == 11.0)
        #expect(ChargingPlannerSupport.powerKw(liveWatts: 0, isCharging: true, configuredKw: 3.7) == 3.7)
    }

    @Test
    func zoneSuggestionMatchesReferenceCities() {
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 65.6) == .se1) // Luleå
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 63.8) == .se2) // Umeå
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 59.9) == .se3) // Uppsala
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 58.4) == .se3) // Linköping
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 57.7) == .se4) // Gothenburg
        #expect(ChargingPlannerSupport.suggestedZone(latitude: 55.6) == .se4) // Malmö
    }
}

struct ChargingPlannerDecisionsTests {
    private static func plan(startOffsetHours: Double, hours: Double, from now: Date) -> ChargingPlan {
        ChargingPlan(
            start: now.addingTimeInterval(startOffsetHours * 3_600),
            end: now.addingTimeInterval((startOffsetHours + hours) * 3_600),
            hours: hours,
            energyKwh: 10,
            averagePrice: 0.5,
            currentPrice: 1.0,
            savings: 5
        )
    }

    @Test
    func windowNotificationFiresOncePerWindowInsideLeadAndSpan() {
        let now = fixtureDate(2026, 2, 10, 12)
        let plan = Self.plan(startOffsetHours: 0.1, hours: 2, from: now)
        #expect(ChargingPlannerDecisions.shouldNotifyWindowStart(plan: plan, now: now, lastNotifiedStart: nil))
        #expect(!ChargingPlannerDecisions.shouldNotifyWindowStart(plan: plan, now: now, lastNotifiedStart: plan.start))
        // Outside the window entirely: before the lead time and after it ends.
        let earlyPlan = Self.plan(startOffsetHours: 1, hours: 2, from: now)
        #expect(!ChargingPlannerDecisions.shouldNotifyWindowStart(plan: earlyPlan, now: now, lastNotifiedStart: nil))
        let latePlan = Self.plan(startOffsetHours: -3, hours: 2, from: now)
        #expect(!ChargingPlannerDecisions.shouldNotifyWindowStart(plan: latePlan, now: now, lastNotifiedStart: nil))
    }

    @Test
    func autoStartRequiresPluggedIdleVehicleInsideWindow() {
        let now = fixtureDate(2026, 2, 10, 12)
        let activePlan = Self.plan(startOffsetHours: -1, hours: 2, from: now)
        let futurePlan = Self.plan(startOffsetHours: 2, hours: 2, from: now)
        let finishedPlan = Self.plan(startOffsetHours: -4, hours: 2, from: now)

        #expect(ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: activePlan, now: now, connection: .connected, chargingState: .idle))
        #expect(!ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: activePlan, now: now, connection: .disconnected, chargingState: .idle))
        #expect(!ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: activePlan, now: now, connection: .connected, chargingState: .charging))
        #expect(!ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: futurePlan, now: now, connection: .connected, chargingState: .idle))
        #expect(!ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: finishedPlan, now: now, connection: .connected, chargingState: .idle))
    }
}
