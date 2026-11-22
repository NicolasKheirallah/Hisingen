import Foundation
import Testing
@testable import Hisingen

/// The one published preset beyond Sweden, and the rule that a preset never applies in a market
/// whose invoice it did not come from.
struct GridTariffPresetTests {
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
        #expect(tariff.peakMonths.isEmpty)
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
}
