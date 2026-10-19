import Foundation
import Testing
@testable import Hisingen

private let stockholm: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    stockholm.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: hour, minute: minute))!
}

private func quarter(_ hour: Int, _ minute: Int, _ price: Double) -> ElectricityPricePoint {
    ElectricityPricePoint(startDate: at(hour, minute), endDate: at(hour, minute).addingTimeInterval(900), sekPerKwh: price)
}

private func session(spot: Double?, energy: Double, estimated: Double? = nil, tariff: Double? = nil) -> HistoricalChargingSession {
    HistoricalChargingSession(
        id: "s", vin: "VIN", startedAt: at(1), endedAt: at(3), startSoc: 20, endSoc: 60,
        energyDeliveredKwh: energy, peakPowerKw: 7, averagePowerKw: 7, locationName: nil, createdAt: at(1),
        tariffPricePerKwh: tariff, estimatedCost: estimated, spotEstimatedCost: spot
    )
}

private func automatic(markup: Double = 0, other: Double = 0, vat: Bool = true,
                       contract: ElectricityPriceContract = .quarterHour) -> ElectricityRatePolicy {
    ElectricityRatePolicy(mode: .automatic, provider: .tibber, contract: contract,
                          markupOrePerKwh: markup, otherChargesOrePerKwh: other, includesVAT: vat)
}

struct ElectricityRatePolicyTests {

    @Test
    func retailPriceAddsMarkupAndChargesThenVAT() {
        // (0.80 + 0.05 + 0.40) * 1.25 = 1.5625
        let price = automatic(markup: 5, other: 40).retailPrice(spotSekPerKwh: 0.80)
        #expect(abs(price - 1.5625) < 0.0001)
    }

    @Test
    func vatCanBeLeftOff() {
        let price = automatic(markup: 5, vat: false).retailPrice(spotSekPerKwh: 0.80)
        #expect(abs(price - 0.85) < 0.0001)
    }

    @Test
    func retailCostMatchesPerKwhPriceForFlatSpot() {
        // A flat 0.80 SEK/kWh spot over 10 kWh costs 8.00 at spot; retail must equal 10 * retailPrice.
        let policy = automatic(markup: 5, other: 40)
        let cost = policy.retailCost(spotCost: 8.0, energyKwh: 10)
        #expect(abs(cost - 10 * policy.retailPrice(spotSekPerKwh: 0.80)) < 0.0001)
    }

    @Test
    func automaticSessionIsPricedFromStoredSpotCost() {
        let resolved = session(spot: 8.0, energy: 10, estimated: 20).resolvedCost(
            policy: automatic(markup: 5), fallbackPricePerKwh: 2.0)
        #expect(abs(resolved.amount - (8.0 + 0.5) * 1.25) < 0.0001)
        #expect(resolved.usedFallback == false)
    }

    @Test
    func automaticSessionWithoutSpotCostKeepsItsFixedFigure() {
        let resolved = session(spot: nil, energy: 10, estimated: 20).resolvedCost(
            policy: automatic(), fallbackPricePerKwh: 2.0)
        #expect(resolved.amount == 20)
        #expect(resolved.usedFallback == false)
    }

    @Test
    func sessionWithNoPriceAtAllReportsTheFallback() {
        let resolved = session(spot: nil, energy: 10).resolvedCost(policy: automatic(), fallbackPricePerKwh: 2.0)
        #expect(resolved.amount == 20)
        #expect(resolved.usedFallback == true)
    }

    @Test
    func fixedModeIgnoresSpotCost() {
        let resolved = session(spot: 8.0, energy: 10, tariff: 1.5).resolvedCost(policy: .fixed, fallbackPricePerKwh: 2.0)
        #expect(resolved.amount == 15)
    }

    // MARK: - Contract settlement

    @Test
    func quarterHourContractKeepsPublishedIntervals() {
        let points = [quarter(2, 0, 1), quarter(2, 15, 2), quarter(2, 30, 3), quarter(2, 45, 4)]
        #expect(ElectricityPriceContract.quarterHour.settle(points, calendar: stockholm) == points)
    }

    @Test
    func hourlyContractAveragesTheFourQuartersOfAnHour() {
        let points = [quarter(2, 0, 1), quarter(2, 15, 2), quarter(2, 30, 3), quarter(2, 45, 4),
                      quarter(3, 0, 10), quarter(3, 15, 10), quarter(3, 30, 10), quarter(3, 45, 10)]
        let settled = ElectricityPriceContract.hourly.settle(points, calendar: stockholm)
        #expect(settled.count == 2)
        #expect(settled[0].startDate == at(2))
        #expect(settled[0].endDate == at(3))
        #expect(abs(settled[0].sekPerKwh - 2.5) < 0.0001)
        #expect(settled[1].sekPerKwh == 10)
    }

    @Test
    func hourlyContractLeavesAPartlyCoveredHourUntouched() {
        let points = [quarter(2, 0, 1), quarter(2, 15, 2)]
        #expect(ElectricityPriceContract.hourly.settle(points, calendar: stockholm) == points)
    }

    @Test
    func hourlyContractPassesThroughSeriesThatAreAlreadyHourly() {
        let hourly = ElectricityPricePoint(startDate: at(2), endDate: at(3), sekPerKwh: 1.2)
        #expect(ElectricityPriceContract.hourly.settle([hourly], calendar: stockholm) == [hourly])
    }
}

@MainActor
struct MarketCountryTests {

    private func store(_ name: String) -> PreferencesStore {
        let defaults = UserDefaults(suiteName: "MarketCountryTests.\(name)")!
        defaults.removePersistentDomain(forName: "MarketCountryTests.\(name)")
        return PreferencesStore(defaults: defaults)
    }

    @Test
    func explicitCountryIsKept() {
        let preferences = store("explicit")
        preferences.marketCountry = .other
        #expect(preferences.marketCountry == .other)
        preferences.marketCountry = .sweden
        #expect(preferences.marketCountry == .sweden)
    }

    @Test
    func existingAutomaticUserIsPinnedToSweden() {
        let preferences = store("automatic")
        preferences.electricityRateMode = .automatic
        #expect(preferences.marketCountry == .sweden)
        preferences.electricityRateMode = .fixed
        #expect(preferences.marketCountry == .sweden)
    }

    @Test
    func otherCountryForcesFixedPricingAndDisablesThePlanner() {
        let preferences = store("other")
        preferences.electricityRateMode = .automatic
        var features = preferences.features
        features.set(.smartChargingPlanner, enabled: true)
        preferences.features = features
        preferences.marketCountry = .other
        #expect(preferences.electricityRatePolicy.mode == .fixed)
        #expect(preferences.smartChargingPlannerAvailable == false)
        preferences.marketCountry = .sweden
        #expect(preferences.electricityRatePolicy.mode == .automatic)
        #expect(preferences.smartChargingPlannerAvailable == true)
    }
}
