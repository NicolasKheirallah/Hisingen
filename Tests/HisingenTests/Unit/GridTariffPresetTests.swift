import Foundation
import Testing
@testable import Hisingen

/// The one published preset beyond Sweden, and the rule that a preset never applies in a market
/// whose invoice it did not come from.
struct GridTariffPresetTests {
    private func oslo(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = month; parts.day = day; parts.hour = hour; parts.minute = minute
        return GridTariffRegion.norway.calendar.date(from: parts)!
    }

    @Test
    func theElviaPresetCarriesElviasOwnFigures() {
        let tariff = GridTariff.elvia()
        #expect(tariff.region == .norway)
        #expect(tariff.kind == .elviaNorway)
        // Day 06-22 on weekdays, night the rest plus weekends: the two rates on Elvia's invoice,
        // VAT, elavgift and Enova included.
        #expect(tariff.peakOrePerKwh == 46.40)
        #expect(tariff.offPeakOrePerKwh == 31.40)
        #expect(tariff.peakStartHour == 6)
        #expect(tariff.peakEndHour == 22)
        #expect(tariff.peakWeekdaysOnly)
        #expect(tariff.peakMonths == Set(1...12))
        #expect(tariff.isTimeVarying)
        #expect(tariff.priceYear == GridTariff.elviaPriceYear)
        #expect(tariff.isPreset)
        #expect(tariff.presetOperatorName == "Elvia AS")
    }

    @Test
    func aPresetOutsideItsMarketLosesItsPublishedFigures() {
        var moved = GridTariff.elvia()
        moved.region = .denmark
        #expect(!moved.isPreset)
        let normalized = moved.normalizedForMarket
        #expect(normalized.kind == .custom)
        #expect(normalized.peakOrePerKwh == 0)
        #expect(normalized.offPeakOrePerKwh == 0)
        #expect(normalized.priceYear == nil)
    }

    @Test
    func swedishPresetsStaySwedish() {
        let time = GridTariff.vattenfall(.vattenfallTime)
        #expect(time.isPreset)
        var moved = time
        moved.region = .norway
        #expect(!moved.isPreset)
        #expect(moved.normalizedForMarket.kind == .custom)
    }

    @Test
    func aPresetBelongsToItsOwnOperatorOnly() {
        let tariff = GridTariff.elvia()
        #expect(tariff.belongsToGridCompany("Elvia AS"))
        #expect(tariff.belongsToGridCompany("Elvia"))
        // A different company, or none recorded, is not evidence against the preset.
        #expect(!tariff.belongsToGridCompany("Vattenfall Eldistribution AB"))
        #expect(tariff.belongsToGridCompany(nil))
    }

    @Test
    func theElviaDayRateAppliesOnWeekdayDaytimesAllYear() {
        let tariff = GridTariff.elvia()
        // 2026-07-15 and 2026-01-14 are Wednesdays: the day rate holds in summer as well as winter.
        for (month, day) in [(7, 15), (1, 14)] {
            #expect(abs(tariff.feePerKwh(at: oslo(month, day, 12)) - 0.4640) < 1e-9)
            #expect(abs(tariff.feePerKwh(at: oslo(month, day, 6)) - 0.4640) < 1e-9)
            #expect(abs(tariff.feePerKwh(at: oslo(month, day, 21, 59)) - 0.4640) < 1e-9)
            #expect(tariff.isPeak(at: oslo(month, day, 12)))
        }
    }

    @Test
    func theElviaNightRateAppliesOutsideTheDayWindowAndOnWeekends() {
        let tariff = GridTariff.elvia()
        // Weekday nights, either side of the 06:00 to 22:00 window.
        #expect(abs(tariff.feePerKwh(at: oslo(7, 15, 5, 59)) - 0.3140) < 1e-9)
        #expect(abs(tariff.feePerKwh(at: oslo(7, 15, 22)) - 0.3140) < 1e-9)
        #expect(abs(tariff.feePerKwh(at: oslo(7, 15, 2)) - 0.3140) < 1e-9)
        // 2026-07-18 is a Saturday and 2026-07-19 a Sunday: night rate at noon.
        #expect(abs(tariff.feePerKwh(at: oslo(7, 18, 12)) - 0.3140) < 1e-9)
        #expect(abs(tariff.feePerKwh(at: oslo(7, 19, 12)) - 0.3140) < 1e-9)
        #expect(!tariff.isPeak(at: oslo(7, 18, 12)))
    }

    @Test
    func theElviaRateChangesAtTheWindowEdges() {
        let tariff = GridTariff.elvia()
        #expect(tariff.nextChange(after: oslo(7, 15, 12)) == oslo(7, 15, 22))
        #expect(tariff.nextChange(after: oslo(7, 15, 23)) == oslo(7, 16, 6))
    }

    @Test("An Elvia tariff stored with no months, as earlier builds saved it, gets its day rate back")
    func storedElviaWithoutMonthsReadsAsAllYear() throws {
        let legacy = """
        {"region":"norway","kind":"elviaNorway","peakOrePerKwh":46.4,"offPeakOrePerKwh":31.4,"peakMonths":[],
         "peakStartHour":6,"peakEndHour":22,"peakWeekdaysOnly":true,"priceYear":2026}
        """
        let decoded = try JSONDecoder().decode(GridTariff.self, from: Data(legacy.utf8))
        #expect(decoded == GridTariff.elvia())
        #expect(abs(decoded.feePerKwh(at: oslo(7, 15, 12)) - 0.4640) < 1e-9)
    }

    @Test
    func anEmptyMonthListStaysEmptyOnTariffsThatAreNotElvia() throws {
        var custom = GridTariff.flat(orePerKwh: 30)
        custom.kind = .custom
        custom.peakMonths = []
        let back = try JSONDecoder().decode(GridTariff.self, from: JSONEncoder().encode(custom))
        #expect(back.peakMonths.isEmpty)
    }
}
