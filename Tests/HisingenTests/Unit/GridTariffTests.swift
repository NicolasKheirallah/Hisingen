import Foundation
import Testing
@testable import Hisingen

private func stockholm(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = year; components.month = month; components.day = day; components.hour = hour; components.minute = minute
    return ElectricityPriceService.stockholmCalendar.date(from: components)!
}

@Suite("Grid tariff")
struct GridTariffTests {
    private let single = GridTariff.vattenfall(.vattenfallSingle)
    private let time = GridTariff.vattenfall(.vattenfallTime)

    // MARK: Presets

    @Test("The Vattenfall 2026 presets carry the published rates, VAT included")
    func presets() {
        #expect(single.kind == .vattenfallSingle)
        #expect(single.peakOrePerKwh == 44.5 && single.offPeakOrePerKwh == 44.5)
        #expect(!single.isTimeVarying)
        #expect(time.kind == .vattenfallTime)
        #expect(time.peakOrePerKwh == 76.5 && time.offPeakOrePerKwh == 30.5)
        #expect(time.peakMonths == [1, 2, 3, 11, 12])
        #expect(time.peakStartHour == 6 && time.peakEndHour == 22 && time.peakWeekdaysOnly)
        #expect(time.isTimeVarying)
        #expect(time.priceYear == 2026)
    }

    @Test("The fixed fee follows the main fuse, and an unknown fuse falls back to 25 A")
    func fixedFees() {
        #expect(GridTariff.vattenfall(.vattenfallTime, fuseAmps: 16).fixedKrPerYear == 5_775)
        #expect(GridTariff.vattenfall(.vattenfallTime, fuseAmps: 25).fixedKrPerYear == 10_125)
        #expect(GridTariff.vattenfall(.vattenfallSingle, fuseAmps: 63).fixedKrPerYear == 26_875)
        #expect(GridTariff.vattenfall(.vattenfallSingle, fuseAmps: 40).fixedKrPerYear == 10_125)
        #expect(GridTariff.vattenfall(.vattenfallSingle, fuseAmps: 35).fuseAmps == 35)
    }

    @Test("Preset prices go stale in the year after they were published, and the reader's own never do")
    func staleness() {
        #expect(!time.isStale(at: stockholm(2026, 12, 31, 23, 59)))
        #expect(time.isStale(at: stockholm(2027, 1, 1, 0, 1)))
        #expect(!GridTariff.flat(orePerKwh: 30).isStale(at: stockholm(2030, 1, 1, 12)))
        var custom = time
        custom.kind = .custom
        custom.priceYear = nil
        #expect(!custom.isStale(at: stockholm(2030, 1, 1, 12)))
    }

    // MARK: Flat

    @Test("A flat tariff charges one rate at every moment, and no rate means no fee")
    func flat() {
        let flat = GridTariff.flat(orePerKwh: 35)
        #expect(flat.kind == .flat && flat.hasFee && !flat.isTimeVarying)
        #expect(flat.feePerKwh(at: stockholm(2026, 11, 18, 12)) == 0.35)
        #expect(abs(flat.averageFeePerKwh(from: stockholm(2026, 11, 18, 5), to: stockholm(2026, 11, 18, 23)) - 0.35) < 1e-12)
        #expect(flat.nextChange(after: stockholm(2026, 11, 18, 12)) == nil)
        for none in [GridTariff.flat(orePerKwh: 0), .flat(orePerKwh: -5), .flat(orePerKwh: .nan), .none] {
            #expect(none.kind == .none && !none.hasFee)
            #expect(none.feePerKwh(at: stockholm(2026, 11, 18, 12)) == 0)
        }
    }

    @Test("A window with no months, no hours or one rate is flat whatever it is called")
    func degenerateWindows() {
        var noMonths = time
        noMonths.peakMonths = []
        #expect(!noMonths.isTimeVarying)
        #expect(noMonths.feePerKwh(at: stockholm(2026, 11, 18, 12)) == 0.305)
        var noHours = time
        noHours.peakEndHour = noHours.peakStartHour
        #expect(!noHours.isTimeVarying)
        var sameRate = time
        sameRate.peakOrePerKwh = sameRate.offPeakOrePerKwh
        #expect(!sameRate.isTimeVarying)
    }

    // MARK: High-load window

    @Test("High-load time is weekdays 06:00 to 22:00, with the edges on the right side")
    func windowEdges() {
        // Wednesday 2026-11-18.
        #expect(time.feePerKwh(at: stockholm(2026, 11, 18, 5, 59)) == 0.305)
        #expect(time.feePerKwh(at: stockholm(2026, 11, 18, 6, 0)) == 0.765)
        #expect(time.feePerKwh(at: stockholm(2026, 11, 18, 21, 59)) == 0.765)
        #expect(time.feePerKwh(at: stockholm(2026, 11, 18, 22, 0)) == 0.305)
    }

    @Test("Only January to March and November to December are high-load months")
    func months() {
        // Wednesdays at noon.
        #expect(time.isPeak(at: stockholm(2026, 11, 18, 12)))
        #expect(!time.isPeak(at: stockholm(2026, 10, 14, 12)))
        #expect(time.isPeak(at: stockholm(2027, 1, 13, 12)))
        #expect(time.isPeak(at: stockholm(2027, 3, 31, 12)))
        #expect(!time.isPeak(at: stockholm(2027, 4, 14, 12)))
        #expect(!time.isPeak(at: stockholm(2026, 7, 15, 12)))
    }

    @Test("Weekends are never high-load, and a custom schedule can include them")
    func weekends() {
        #expect(!time.isPeak(at: stockholm(2026, 11, 21, 12)))   // Saturday
        #expect(!time.isPeak(at: stockholm(2026, 11, 22, 12)))   // Sunday
        var everyDay = time
        everyDay.kind = .custom
        everyDay.peakWeekdaysOnly = false
        #expect(everyDay.isPeak(at: stockholm(2026, 11, 21, 12)))
    }

    @Test("The holidays Vattenfall names are not high-load when they fall on a weekday")
    func holidays() {
        #expect(!time.isPeak(at: stockholm(2026, 12, 24, 12)))   // Christmas Eve, a Thursday
        #expect(!time.isPeak(at: stockholm(2026, 12, 25, 12)))   // Christmas Day, a Friday
        #expect(!time.isPeak(at: stockholm(2026, 12, 31, 12)))   // New Year's Eve, a Thursday
        #expect(!time.isPeak(at: stockholm(2027, 1, 1, 12)))     // New Year's Day, a Friday
        #expect(!time.isPeak(at: stockholm(2027, 1, 6, 12)))     // Epiphany, a Wednesday
        #expect(!time.isPeak(at: stockholm(2027, 3, 26, 12)))    // Good Friday
        #expect(!time.isPeak(at: stockholm(2027, 3, 29, 12)))    // Easter Monday
        // The days next to them are ordinary.
        #expect(time.isPeak(at: stockholm(2026, 12, 23, 12)))
        #expect(time.isPeak(at: stockholm(2027, 1, 5, 12)))
        #expect(time.isPeak(at: stockholm(2027, 3, 30, 12)))
    }

    @Test("Easter follows the Gregorian calendar")
    func easter() throws {
        let calendar = ElectricityPriceService.stockholmCalendar
        func parts(_ year: Int) throws -> [Int] {
            let date = try #require(SwedishHolidays.easterSunday(year: year))
            let c = calendar.dateComponents([.month, .day], from: date)
            return [c.month ?? 0, c.day ?? 0]
        }
        #expect(try parts(2026) == [4, 5])
        #expect(try parts(2027) == [3, 28])
        #expect(try parts(2028) == [4, 16])
        #expect(SwedishHolidays.isNamedHoliday(year: 2026, month: 4, day: 3))
        #expect(SwedishHolidays.isNamedHoliday(year: 2026, month: 4, day: 6))
        #expect(!SwedishHolidays.isNamedHoliday(year: 2026, month: 4, day: 5 + 7))
    }

    @Test("May 1, Ascension Day, National Day, and Midsummer Eve are classified across 2025-2028")
    func expandedHolidays() {
        for year in 2025...2028 {
            #expect(SwedishHolidays.isNamedHoliday(year: year, month: 5, day: 1))
            #expect(SwedishHolidays.isNamedHoliday(year: year, month: 6, day: 6))
            #expect(!SwedishHolidays.isNamedHoliday(year: year, month: 5, day: 2))
        }
        // Ascension Day (39 days after Easter) and Midsummer Eve (Friday June 19-25)
        let expected: [(Int, Int, Int)] = [
            (2025, 5, 29), (2025, 6, 20),
            (2026, 5, 14), (2026, 6, 19),
            (2027, 5, 6),  (2027, 6, 25),
            (2028, 5, 25), (2028, 6, 23),
        ]
        for (year, month, day) in expected {
            #expect(SwedishHolidays.isNamedHoliday(year: year, month: month, day: day))
        }
        // Vattenfall T4 treats May 1, etc. inside active winter/non-winter bounds consistently
        #expect(!SwedishHolidays.isNamedHoliday(year: 2026, month: 6, day: 20))
    }

    @Test("The clock is Swedish time, so the window moves with summer time")
    func summerTime() {
        // March 2026 is a high-load month. Summer time starts on Sunday the 29th.
        #expect(time.isPeak(at: stockholm(2026, 3, 27, 6)))    // Friday, UTC+1
        #expect(time.isPeak(at: stockholm(2026, 3, 30, 6)))    // Monday, UTC+2
        #expect(!time.isPeak(at: stockholm(2026, 3, 30, 5, 59)))
        #expect(!time.isPeak(at: stockholm(2026, 3, 30, 22)))
        let utcOffset = ElectricityPriceService.stockholmCalendar.timeZone
        #expect(utcOffset.secondsFromGMT(for: stockholm(2026, 3, 27, 12)) == 3_600)
        #expect(utcOffset.secondsFromGMT(for: stockholm(2026, 3, 30, 12)) == 7_200)
    }

    // MARK: Averages across the window

    @Test("A span across 22:00 pays each side its own rate, weighted by time")
    func averageAcrossTheEdge() {
        let average = time.averageFeePerKwh(from: stockholm(2026, 11, 18, 21), to: stockholm(2026, 11, 18, 23))
        #expect(abs(average - 0.535) < 1e-9)
        // Three quarters of an hour before the edge, a quarter after it.
        let uneven = time.averageFeePerKwh(from: stockholm(2026, 11, 18, 21, 15), to: stockholm(2026, 11, 18, 22, 15))
        #expect(abs(uneven - (0.75 * 0.765 + 0.25 * 0.305)) < 1e-9)
    }

    @Test("A span inside one side of the window gets that side's rate, and an instant gets the fee at it")
    func averageInsideOneSide() {
        #expect(abs(time.averageFeePerKwh(from: stockholm(2026, 11, 18, 8), to: stockholm(2026, 11, 18, 12)) - 0.765) < 1e-12)
        #expect(abs(time.averageFeePerKwh(from: stockholm(2026, 11, 18, 23), to: stockholm(2026, 11, 19, 5)) - 0.305) < 1e-12)
        let instant = stockholm(2026, 11, 18, 7)
        #expect(time.averageFeePerKwh(from: instant, to: instant) == 0.765)
    }

    @Test("A whole weekday averages 16 high-load hours and 8 others")
    func averageOverADay() {
        let average = time.averageFeePerKwh(from: stockholm(2026, 11, 18, 0), to: stockholm(2026, 11, 19, 0))
        #expect(abs(average - (16 * 0.765 + 8 * 0.305) / 24) < 1e-9)
    }

    // MARK: When it changes

    @Test("The next change is the next edge of the window, across a weekend when it has to be")
    func nextChange() {
        #expect(time.nextChange(after: stockholm(2026, 11, 18, 14)) == stockholm(2026, 11, 18, 22))
        #expect(time.nextChange(after: stockholm(2026, 11, 18, 22, 30)) == stockholm(2026, 11, 19, 6))
        #expect(time.nextChange(after: stockholm(2026, 11, 20, 22, 30)) == stockholm(2026, 11, 23, 6))   // Friday night to Monday
        #expect(time.nextChange(after: stockholm(2026, 10, 28, 12)) == stockholm(2026, 11, 2, 6))
        #expect(time.nextChange(after: stockholm(2026, 7, 1, 12)) == nil)   // nothing within two weeks
    }

    @Test("A tariff survives being stored and read back")
    func codable() throws {
        for tariff in [GridTariff.none, .flat(orePerKwh: 42.5), single, time] {
            let data = try JSONEncoder().encode(tariff)
            #expect(try JSONDecoder().decode(GridTariff.self, from: data) == tariff)
        }
    }
}

@Suite("Grid tariff in the calculations")
struct GridTariffCalculationTests {
    private let time = GridTariff.vattenfall(.vattenfallTime)
    private let fallback = HomeSessionPricer.Fallback(fixedPricePerKwh: 2.0, policy: .fixed, spotPrices: [], currency: "kr")

    private func session(from start: Date, to end: Date, kwh: Double, intervals: Bool) -> HomeChargingSessionCandidate {
        HomeChargingSessionCandidate(
            key: "k", keyKind: .vendorSessionID, chargerID: "C1", startedAt: start, endedAt: end, energyKwh: kwh,
            energySource: "test", measuredAt: end, intervals: intervals ? [HomeEnergyInterval(start: start, end: end, kwh: kwh)] : [])
    }

    private func prices(from start: Date, hours: Int, price: Double) -> [HomePricePoint] {
        (0..<hours).map {
            let from = start.addingTimeInterval(Double($0) * 3_600)
            return HomePricePoint(start: from, end: from.addingTimeInterval(3_600), pricePerKwh: price)
        }
    }

    @Test("A session that crosses 22:00 is priced with each side's own transfer fee")
    func sessionAcrossTheEdge() {
        let start = stockholm(2026, 11, 18, 21), end = stockholm(2026, 11, 18, 23)
        let slots = prices(from: start, hours: 2, price: 1.0)
        let cost = HomeSessionPricer.price(session(from: start, to: end, kwh: 4, intervals: true), tibber: slots,
                                           gridTariff: time, fallback: fallback)
        // 2 kWh before 22:00 at 1.0 + 0.765, 2 kWh after at 1.0 + 0.305.
        let billed: Double = cost.amount ?? 0
        let expectedBill: Double = 2 * 1.765 + 2 * 1.305
        #expect(abs(billed - expectedBill) < 1e-9)
        #expect(cost.assumptions.contains { $0.contains("time of day") })
    }

    @Test("A session with only a total uses the fee averaged over the session")
    func totalOnlySession() {
        let start = stockholm(2026, 11, 18, 21), end = stockholm(2026, 11, 18, 23)
        let slots = prices(from: start, hours: 2, price: 1.0)
        let cost = HomeSessionPricer.price(session(from: start, to: end, kwh: 4, intervals: false), tibber: slots,
                                           gridTariff: time, fallback: fallback)
        #expect(cost.method == .totalTibberAverage)
        let billedAgain: Double = cost.amount ?? 0
        let expectedFlat: Double = 4 * (1.0 + 0.535)
        #expect(abs(billedAgain - expectedFlat) < 1e-9)
    }

    @Test("A flat tariff and the old flat fee give the same cost")
    func flatMatchesTheOldFee() {
        let start = stockholm(2026, 11, 18, 21), end = stockholm(2026, 11, 18, 23)
        let slots = prices(from: start, hours: 2, price: 1.0)
        let candidate = session(from: start, to: end, kwh: 4, intervals: true)
        let old = HomeSessionPricer.price(candidate, tibber: slots, networkFeeOrePerKwh: 50, fallback: fallback)
        let new = HomeSessionPricer.price(candidate, tibber: slots, gridTariff: .flat(orePerKwh: 50), fallback: fallback)
        #expect(old == new)
        #expect(abs((new.amount ?? 0) - 6.0) < 1e-9)
        #expect(new.assumptions.contains("Variable network fee of 50.0 öre/kWh added"))
        let none = HomeSessionPricer.price(candidate, tibber: slots, gridTariff: .none, fallback: fallback)
        #expect(none.assumptions.contains("No variable network fee is set, so none is added"))
    }

    @Test("The house-load costs add the transfer fee to Tibber's billed cost, hour by hour")
    func houseLoadCosts() throws {
        let start = stockholm(2026, 11, 18, 20)
        let hours = (0..<4).map { index -> TibberConsumptionHour in
            let from = start.addingTimeInterval(Double(index) * 3_600)
            return TibberConsumptionHour(start: from, end: from.addingTimeInterval(3_600), kwh: 2, cost: 2, currency: "SEK")
        }
        let wallbox = WallboxMeasurement(
            chargerID: "c", sessionKey: "k", keyKind: "test", energyKwh: 4, energySource: "test", measuredAt: start,
            startedAt: start, endedAt: start.addingTimeInterval(2 * 3_600), peakPowerKw: nil, cost: nil, partialCost: nil,
            costMethod: nil, priceSource: nil, costAssumptions: [], missingKwh: nil, currency: nil, attribution: nil)
        let session = HistoricalChargingSession(
            id: "s", vin: "VIN", startedAt: start, endedAt: start.addingTimeInterval(2 * 3_600), startSoc: 20, endSoc: 60,
            energyDeliveredKwh: 0, peakPowerKw: 7, averagePowerKw: 5, locationName: nil, createdAt: start, wallbox: wallbox)

        let plain = try #require(HouseLoad.share(hours: hours, sessions: [session]))
        #expect(plain.includesGridFee == false)
        let plainCost: Double = plain.houseCost ?? 0
        #expect(abs(plainCost - 8) < 1e-9)

        let withFee = try #require(HouseLoad.share(hours: hours, sessions: [session], gridTariff: time))
        #expect(withFee.includesGridFee)
        // Hours 20:00 and 21:00 are high-load, 22:00 and 23:00 are not. 2 kWh each, billed 1 kr per kWh.
        // Written as separate figures: one dense expression here exhausted the CI toolchain's
        // type-checking budget before it could infer the arithmetic.
        let peakHours: Double = 2
        let otherHours: Double = 2
        let expectedHouse: Double = 8 + peakHours * 0.765 * 2 + otherHours * 0.305 * 2
        let houseCost: Double = withFee.houseCost ?? 0
        #expect(abs(houseCost - expectedHouse) < 1e-9)
        // The car drew 2 kWh in each of the first two hours, both high-load.
        let expectedCar: Double = 4 + 4 * 0.765
        let carCost: Double = withFee.carCost ?? 0
        #expect(abs(carCost - expectedCar) < 1e-9)
        // A tariff with no fee changes nothing.
        let none = try #require(HouseLoad.share(hours: hours, sessions: [session], gridTariff: GridTariff.none))
        #expect(none.includesGridFee == false)
        let noneCost: Double = none.houseCost ?? 0
        #expect(abs(noneCost - 8) < 1e-9)
    }

    @Test("The tariff comparison counts the time tariff's high-load share and costs both tariffs on the same hours")
    func advisor() throws {
        func hour(_ hourOfDay: Int, kwh: Double) -> TibberConsumptionHour {
            let start = stockholm(2026, 11, 18, hourOfDay)
            return TibberConsumptionHour(start: start, end: start.addingTimeInterval(3_600), kwh: kwh)
        }
        // A Wednesday in November: 05:00 and 22:00 are outside the window, 06:00 and 21:00 inside.
        let hours = [hour(5, kwh: 1), hour(6, kwh: 1), hour(21, kwh: 1), hour(22, kwh: 1)]
        let result = try #require(TariffAdvisor.compare(hours: hours, single: .vattenfall(.vattenfallSingle),
                                                        time: .vattenfall(.vattenfallTime)))
        #expect(result.days == 1)
        #expect(result.kwh == 4)
        #expect(abs(result.highLoadShare - 0.5) < 1e-9)
        #expect(abs(result.singleSek - 4 * 0.445) < 1e-9)
        #expect(abs(result.timeSek - (2 * 0.765 + 2 * 0.305)) < 1e-9)
        #expect(!result.timeTariffIsCheaper)
        #expect(abs(result.differenceSek - 0.36) < 1e-9)
        #expect(TariffAdvisor.compare(hours: [], single: .vattenfall(.vattenfallSingle), time: .vattenfall(.vattenfallTime)) == nil)
    }
}

@Suite("Grid tariff market")
struct GridTariffRegionTests {
    @Test("The picker offers the markets Tibber sells electricity in, and Sweden is the only one with rates")
    func markets() {
        #expect(GridTariffRegion.allCases.count == 5)
        #expect(GridTariffRegion.allCases.filter(\.hasPublishedRates) == [.sweden])
    }

    @Test("Every market keeps its own clock, and Sweden's is the Stockholm calendar the prices were read against")
    func calendars() {
        for region in GridTariffRegion.allCases {
            #expect(region.calendar.timeZone.identifier == region.timeZoneIdentifier)
        }
        #expect(GridTariffRegion.sweden.calendar.timeZone == ElectricityPriceService.stockholmCalendar.timeZone)
    }

    @Test("A Tibber home's time zone names its market, and an unknown one names none")
    func inference() {
        #expect(GridTariffRegion.matching(timeZoneIdentifier: "Europe/Stockholm") == .sweden)
        #expect(GridTariffRegion.matching(timeZoneIdentifier: "Europe/Oslo") == .norway)
        #expect(GridTariffRegion.matching(timeZoneIdentifier: "Europe/Helsinki") == nil)
        #expect(GridTariffRegion.matching(timeZoneIdentifier: nil) == nil)
    }

    @Test("The fee is written in the market's own hundredth of a currency unit")
    func units() {
        #expect(GridTariffRegion.sweden.feeUnitWord == "öre")
        #expect(GridTariffRegion.denmark.feeUnitWord == "øre")
        #expect(GridTariffRegion.germany.feeUnitWord == "ct")
        #expect(GridTariffRegion.sweden.currencySymbol == "kr")
        #expect(GridTariffRegion.netherlands.currencySymbol == "€")
    }

    @Test("A Vattenfall preset is a preset in Sweden only, so the same rates carried elsewhere are edited as custom")
    func presetIsSwedish() {
        var moved = GridTariff.vattenfall(.vattenfallTime)
        #expect(moved.isPreset)
        moved.region = .germany
        #expect(!moved.isPreset)
        // The figures stay put; only their standing changes, so nothing silently reprices.
        #expect(moved.peakOrePerKwh == 76.5)
    }

    @Test("A preset belongs to its own operator, and a grid company nobody named is not a mismatch")
    func presetBelongsToItsOperator() {
        let preset = GridTariff.vattenfall(.vattenfallTime)
        #expect(preset.presetOperatorName == "Vattenfall Eldistribution AB")
        // The brand word is what counts, so the short and long names agree.
        #expect(preset.belongsToGridCompany("Vattenfall Eldistribution AB"))
        #expect(preset.belongsToGridCompany("Vattenfall AB"))
        // Another operator's meter is where the wrong number would land.
        #expect(!preset.belongsToGridCompany("Ellevio AB"))
        #expect(!preset.belongsToGridCompany("E.ON Energidistribution AB"))
        // No answer is not evidence of a mismatch.
        #expect(preset.belongsToGridCompany(nil))
        #expect(preset.belongsToGridCompany(""))
        // The reader's own figures belong to nobody in particular.
        let custom = GridTariff.flat(orePerKwh: 30)
        #expect(custom.presetOperatorName == nil)
        #expect(custom.belongsToGridCompany("Ellevio AB"))
    }

    @Test("A tariff stored before the country picker existed keeps its rates and reads as Sweden")
    func legacyDecode() throws {
        let legacy = """
        {"kind":"vattenfallTime","peakOrePerKwh":76.5,"offPeakOrePerKwh":30.5,"peakMonths":[1,2,3,11,12],
         "peakStartHour":6,"peakEndHour":22,"peakWeekdaysOnly":true,"fuseAmps":25,
         "fixedKrPerYear":10125,"priceYear":2026}
        """
        let decoded = try JSONDecoder().decode(GridTariff.self, from: Data(legacy.utf8))
        #expect(decoded.region == .sweden)
        #expect(decoded.isPreset)
        #expect(decoded.fixedKrPerYear == 10_125)
        #expect(decoded.peakMonths == [1, 2, 3, 11, 12])
    }

    @Test("A tariff round-trips through storage with its market")
    func roundTrip() throws {
        var custom = GridTariff.flat(orePerKwh: 30)
        custom.region = .denmark
        custom.fixedKrPerYear = 2_400
        let data = try JSONEncoder().encode(custom)
        let back = try JSONDecoder().decode(GridTariff.self, from: data)
        #expect(back == custom)
    }

    @Test("The fuse picker is the fee table's own key set, so the two cannot drift apart")
    func fuseSizesComeFromTheFeeTable() {
        #expect(GridTariff.vattenfallFuseSizes == [16, 20, 25, 35, 50, 63])
        for amps in GridTariff.vattenfallFuseSizes {
            #expect(GridTariff.vattenfall(.vattenfallSingle, fuseAmps: amps).fixedKrPerYear != nil)
        }
    }

    @Test("Moving a tariff across a border keeps its shape and drops every figure written in the old currency")
    func movingMarketClearsMoney() {
        let swedish = GridTariff.vattenfall(.vattenfallTime, fuseAmps: 25)
        let german = swedish.moved(to: .germany)
        #expect(german.region == .germany)
        // The shape survives: re-entering the window is the expensive part.
        #expect(german.peakMonths == [1, 2, 3, 11, 12])
        #expect(german.peakStartHour == 6 && german.peakEndHour == 22 && german.peakWeekdaysOnly)
        #expect(german.fuseAmps == 25)
        // The money does not: 76.5 öre read as 76.3 ct would be a different amount entirely.
        #expect(german.peakOrePerKwh == 0 && german.offPeakOrePerKwh == 0)
        #expect(german.fixedKrPerYear == nil)
        #expect(german.priceYear == nil)
        // A Swedish preset has no meaning elsewhere, so it becomes the reader's own figures.
        #expect(german.kind == .custom)
        #expect(!german.isPreset)
    }

    @Test("A preset found in a market without published rates is read as custom, with its Swedish öre cleared")
    func inconsistentMarketIsNormalized() {
        // The state a restore from another build can leave: a Swedish preset kind in a German market.
        var broken = GridTariff.vattenfall(.vattenfallTime, fuseAmps: 25)
        broken.region = .germany
        let normalized = broken.normalizedForMarket
        #expect(normalized.kind == .custom)
        #expect(normalized.peakOrePerKwh == 0 && normalized.offPeakOrePerKwh == 0)
        #expect(normalized.fixedKrPerYear == nil)
        #expect(normalized.priceYear == nil)
        // A consistent tariff is returned unchanged, so the card's guard settles after one pass.
        let healthy = GridTariff.vattenfall(.vattenfallTime, fuseAmps: 25)
        #expect(healthy.normalizedForMarket == healthy)
    }

    @Test("Moving to the market a tariff is already in changes nothing")
    func movingInPlaceIsIdentity() {
        let tariff = GridTariff.vattenfall(.vattenfallSingle, fuseAmps: 25)
        #expect(tariff.moved(to: .sweden) == tariff)
    }

    @Test("A custom tariff carried to another market loses its figures too, in either direction")
    func movingCustomClearsMoney() {
        var german = GridTariff.flat(orePerKwh: 9)
        german.region = .germany
        german.fixedKrPerYear = 480
        let swedish = german.moved(to: .sweden)
        #expect(swedish.region == .sweden)
        #expect(swedish.kind == .flat)
        #expect(swedish.peakOrePerKwh == 0)
        #expect(swedish.offPeakOrePerKwh == 0)
        #expect(swedish.fixedKrPerYear == nil)
    }

    @Test("The high-load window is still read on Stockholm time, so the published Vattenfall window is unchanged")
    func windowUnchanged() {
        let time = GridTariff.vattenfall(.vattenfallTime)
        #expect(time.isPeak(at: stockholm(2026, 11, 18, 7)))
        #expect(!time.isPeak(at: stockholm(2026, 11, 18, 23)))
        #expect(!time.isPeak(at: stockholm(2026, 7, 15, 7)))
    }
}
