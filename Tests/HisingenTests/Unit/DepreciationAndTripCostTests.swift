import Foundation
import Testing
@testable import Hisingen

/// The arithmetic a period report stands on: declining-balance depreciation from the reader's own
/// assumption, and trip cost from distance × reported consumption × the rate policy's price.
@Suite("Depreciation and trip cost")
struct DepreciationAndTripCostTests {
    private let purchase = Date(timeIntervalSince1970: 1_680_000_000)

    private func assumption(price: Double = 400_000, decline: Double = 15) -> DepreciationAssumption {
        DepreciationAssumption(purchasePrice: price, purchaseDate: purchase, annualDeclinePercent: decline)
    }

    // MARK: - Depreciation

    @Test
    func decliningBalanceLosesTheStatedShareOfWhatIsLeftEachYear() throws {
        let oneYearLater = purchase.addingTimeInterval(365.25 * 24 * 3_600)

        let value = try #require(Depreciation.value(assumption: assumption(), at: oneYearLater))

        #expect(abs(value - 340_000) < 1)
    }

    @Test
    func twoYearsCompoundRatherThanAddingUp() throws {
        let twoYearsLater = purchase.addingTimeInterval(2 * 365.25 * 24 * 3_600)

        let value = try #require(Depreciation.value(assumption: assumption(), at: twoYearsLater))

        // 400 000 × 0.85² = 289 000, not 400 000 × 0.70.
        #expect(abs(value - 289_000) < 2)
    }

    @Test
    func beforeThePurchaseDateTheValueIsThePriceItsef() throws {
        let value = try #require(Depreciation.value(
            assumption: assumption(), at: purchase.addingTimeInterval(-90 * 24 * 3_600)))

        #expect(value == 400_000)
    }

    @Test
    func aZeroPriceIsAnUnfilledFieldNotACarWorthNothing() {
        #expect(Depreciation.value(assumption: assumption(price: 0), at: purchase.addingTimeInterval(3_600)) == nil)
        #expect(Depreciation.figure(
            assumption: assumption(price: 0),
            periodStart: purchase, periodEnd: purchase.addingTimeInterval(86_400)) == nil)
        #expect(assumption(price: 0).isUsable == false)
        #expect(assumption(decline: 0).isUsable == false)
    }

    @Test
    func hostileStoredValuesAreClampedInsteadOfCompounding() {
        let hostile = DepreciationAssumption(
            purchasePrice: -5, purchaseDate: purchase, annualDeclinePercent: 900).sanitized

        #expect(hostile.purchasePrice == 0)
        #expect(hostile.annualDeclinePercent == DepreciationAssumption.maximumAnnualDeclinePercent)
    }

    @Test
    func thePeriodLossIsTheDropBetweenTheTwoEdgesOfTheWindow() throws {
        let periodStart = purchase.addingTimeInterval(30 * 24 * 3_600)
        let periodEnd = periodStart.addingTimeInterval(31 * 24 * 3_600)

        let figure = try #require(Depreciation.figure(
            assumption: assumption(), periodStart: periodStart, periodEnd: periodEnd))

        #expect(figure.valueAtStart > figure.valueAtEnd)
        #expect(abs(figure.periodLoss - (figure.valueAtStart - figure.valueAtEnd)) < 0.001)
        // One month of a 15 % decline on roughly 390 000 is a few thousand, not a whole year's loss.
        #expect(figure.periodLoss > 1_000)
        #expect(figure.periodLoss < 20_000)
    }

    @Test
    func theBasisSentenceNamesTheAssumptionItApplied() {
        let basis = Depreciation.basisText(assumption: assumption(), currencySymbol: "kr")

        #expect(basis.contains("15"))
        #expect(basis.contains("400"))
        #expect(basis.contains(Format.shortDate(date: purchase)))
    }

    // MARK: - Trip cost

    @Test
    func tripEnergyIsDistanceTimesReportedConsumption() throws {
        let energy = try #require(TripCost.energyKwh(distanceKm: 100, consumptionKwhPer100Km: 20))

        #expect(abs(energy - 20) < 0.0001)
    }

    @Test
    func aConsumptionOutsideThePlausibleBandYieldsNoEnergy() {
        #expect(TripCost.energyKwh(distanceKm: 100, consumptionKwhPer100Km: 0.4) == nil)
        #expect(TripCost.energyKwh(distanceKm: 100, consumptionKwhPer100Km: 80) == nil)
        #expect(TripCost.energyKwh(distanceKm: 100, consumptionKwhPer100Km: nil) == nil)
        #expect(TripCost.energyKwh(distanceKm: 0, consumptionKwhPer100Km: 20) == nil)
    }

    @Test
    func tripCostIsEnergyTimesPriceAndNothingElse() throws {
        let energy = try #require(TripCost.energyKwh(distanceKm: 150, consumptionKwhPer100Km: 18))
        let cost = try #require(TripCost.cost(energyKwh: energy, pricePerKwh: 1.5))

        // 150 km × 18 kWh/100 km = 27 kWh; 27 × 1.5 = 40.5.
        #expect(abs(cost - 40.5) < 0.0001)
    }

    @Test
    func aMissingPriceIsNoCostRatherThanFree() {
        #expect(TripCost.cost(energyKwh: 20, pricePerKwh: nil) == nil)
        #expect(TripCost.cost(energyKwh: 20, pricePerKwh: 0) == nil)
        #expect(TripCost.cost(energyKwh: nil, pricePerKwh: 1.5) == nil)
    }

    // MARK: - Price resolution

    @Test
    func automaticModeConvertsTheWindowAverageThroughTheRatePolicy() {
        var policy = ElectricityRatePolicy.fixed
        policy.mode = .automatic
        policy.markupOrePerKwh = 10
        policy.otherChargesOrePerKwh = 0
        policy.includesVAT = true

        let resolved = ReportPricing.retailPricePerKwh(
            policy: policy, fallbackPricePerKwh: 2.0, averageSpotSekPerKwh: 1.0)

        // (1.00 kr + 0.10 kr) × 1.25 = 1.375 kr/kWh, not the fixed tariff.
        #expect(abs(resolved.price - 1.375) < 0.0001)
        #expect(resolved.usedFallback == false)
    }

    @Test
    func fixedModeUsesTheTariffAndSaysItDid() {
        let resolved = ReportPricing.retailPricePerKwh(
            policy: .fixed, fallbackPricePerKwh: 2.0, averageSpotSekPerKwh: 1.0)

        #expect(resolved.price == 2.0)
        #expect(resolved.usedFallback)
    }

    @Test
    func automaticModeWithoutAMarketSeriesFallsBackToTheTariff() {
        var policy = ElectricityRatePolicy.fixed
        policy.mode = .automatic

        let resolved = ReportPricing.retailPricePerKwh(
            policy: policy, fallbackPricePerKwh: 1.75, averageSpotSekPerKwh: nil)

        #expect(resolved.price == 1.75)
        #expect(resolved.usedFallback)
    }

    @Test
    func theWindowAverageWeightsEachSlotByThePartItCovers() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let period = ReportPeriod(cadence: .monthly, start: start, end: start.addingTimeInterval(4 * 3_600))
        let points = [
            // Fully inside: 2 kr for 2 hours.
            ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(2 * 3_600), sekPerKwh: 2),
            // Half covered, ends at the window edge: 1 kr for 2 hours → contributes 1 hour.
            ElectricityPricePoint(startDate: start.addingTimeInterval(3 * 3_600),
                                  endDate: start.addingTimeInterval(5 * 3_600), sekPerKwh: 1),
        ]

        let average = try #require(ReportPricing.averageSpot(points, over: period))

        // (2×2h + 1×1h) / 3h = 1.667, not the unweighted 1.5 of the two published prices.
        #expect(abs(average - (5.0 / 3.0)) < 0.0001)
    }

    @Test
    func aWindowWithNoStoredPricesHasNoAverage() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let period = ReportPeriod(cadence: .weekly, start: start, end: start.addingTimeInterval(86_400))

        #expect(ReportPricing.averageSpot([], over: period) == nil)
        #expect(ReportPricing.averageSpot(
            [ElectricityPricePoint(startDate: start.addingTimeInterval(86_400),
                                   endDate: start.addingTimeInterval(90_000), sekPerKwh: 1)],
            over: period) == nil)
    }
}
