import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
struct PlannerPriceProviderTests {
    /// 2026-11-18 10:00 Stockholm, before the 14:15 publication: a cache reaching the end of
    /// today is complete.
    private static let morning: Date = {
        var components = DateComponents()
        components.year = 2026; components.month = 11; components.day = 18; components.hour = 10
        return ElectricityPriceService.stockholmCalendar.date(from: components)!
    }()

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var current: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
    }

    private actor Tibber {
        private(set) var calls = 0
        var failing = false
        let series: [HomePricePoint]
        init(series: [HomePricePoint]) { self.series = series }
        func setFailing(_ value: Bool) { failing = value }
        func fetch() throws -> [HomePricePoint] {
            calls += 1
            if failing { throw DirectChargerError.unreachable }
            return series
        }
    }

    private actor Spot: ChargingPlannerPriceSource {
        let series: [ElectricityPricePoint]
        let fetched: Date
        private(set) var calls = 0
        init(series: [ElectricityPricePoint], fetched: Date) { self.series = series; self.fetched = fetched }
        func prices(for zone: ElspotZone) async -> [ElectricityPricePoint] { calls += 1; return series }
        func fetchedAt(for zone: ElspotZone) async -> Date? { fetched }
    }

    /// Quarter-hours from the start of the day for `days` days at a flat price.
    private static func tibberSeries(price: Double, days: Int = 2) -> [HomePricePoint] {
        let start = ElectricityPriceService.stockholmCalendar.startOfDay(for: morning)
        return (0..<(days * 96)).map {
            let from = start.addingTimeInterval(Double($0) * 900)
            return HomePricePoint(start: from, end: from.addingTimeInterval(900), pricePerKwh: price)
        }
    }

    private static func spotSeries(price: Double) -> [ElectricityPricePoint] {
        tibberSeries(price: price).map { ElectricityPricePoint(startDate: $0.start, endDate: $0.end, sekPerKwh: $0.pricePerKwh) }
    }

    private func provider(tibber: Tibber?, clock: Clock, homeID: String = "home-1") async -> (PlannerPriceProvider, Spot) {
        let spot = Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning)
        let provider = PlannerPriceProvider(spot: spot, now: { clock.current })
        provider.setTibberSource {
            guard let tibber else { return nil }
            return PlannerPriceProvider.TibberSource(homeID: homeID, fetch: { _, _ in try await tibber.fetch() })
        }
        return (provider, spot)
    }

    @Test
    func connectedTibberSuppliesThePrices() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let (provider, _) = await provider(tibber: tibber, clock: Clock(Self.morning))

        let result = await provider.resolve(zone: .se3)

        #expect(result.origin == .tibber)
        #expect(result.isAllIn)
        #expect(result.isFallback == false)
        #expect(result.points.count == 192)
        #expect(result.points.allSatisfy { $0.sekPerKwh == 1.80 })
        #expect(result.fetchedAt == Self.morning)
    }

    @Test
    func theNetworkFeeIsAddedToTibberPricesAndNotToTheMarketSeries() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let spot = Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning)
        let provider = PlannerPriceProvider(spot: spot, now: { Self.morning })
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: "h", networkFeeSekPerKwh: 0.35, fetch: { _, _ in try await tibber.fetch() })
        }

        let result = await provider.resolve(zone: .se3)
        let market = await provider.marketPrices(for: .se3)

        #expect(result.includesNetworkFee)
        #expect(result.points.allSatisfy { abs($0.sekPerKwh - 2.15) < 1e-9 })
        #expect(market.allSatisfy { $0.sekPerKwh == 0.50 })
    }

    @Test
    func tibberLevelsSurviveTheNetworkFee() async {
        let rated = Self.tibberSeries(price: 1.80).map { point -> HomePricePoint in
            var point = point
            point.level = .expensive
            return point
        }
        let tibber = Tibber(series: rated)
        let provider = PlannerPriceProvider(spot: Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning), now: { Self.morning })
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: "h", networkFeeSekPerKwh: 0.35, fetch: { _, _ in try await tibber.fetch() })
        }

        let result = await provider.resolve(zone: .se3)

        #expect(result.level(at: Self.morning) == .expensive)
        #expect(result.points.allSatisfy { $0.level == .expensive })
    }

    @Test
    func aTimeOfUseTariffChangesTheFeeSlotBySlot() async {
        // Every month, 06:00 to 22:00, every day: so the result does not depend on the date the test runs.
        var tariff = GridTariff.vattenfall(.vattenfallTime)
        tariff.kind = .custom
        tariff.priceYear = nil
        tariff.peakMonths = Set(1...12)
        tariff.peakWeekdaysOnly = false
        tariff.peakOrePerKwh = 100
        tariff.offPeakOrePerKwh = 20
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let provider = PlannerPriceProvider(spot: Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning), now: { Self.morning })
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: "h", gridTariff: tariff, fetch: { _, _ in try await tibber.fetch() })
        }

        let result = await provider.resolve(zone: .se3)
        let calendar = ElectricityPriceService.stockholmCalendar

        #expect(result.includesNetworkFee)
        let midnight = result.points.first { calendar.component(.hour, from: $0.startDate) == 0 }
        let noon = result.points.first { calendar.component(.hour, from: $0.startDate) == 12 }
        #expect(abs((midnight?.sekPerKwh ?? 0) - 2.00) < 1e-9)
        #expect(abs((noon?.sekPerKwh ?? 0) - 2.80) < 1e-9)
        // The window's edges land on slot edges, so no slot is a blend.
        #expect(result.points.allSatisfy { abs($0.sekPerKwh - 2.00) < 1e-9 || abs($0.sekPerKwh - 2.80) < 1e-9 })
    }

    @Test
    func theFallbackCarriesWhyTibberFailed() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        await tibber.setFailing(true)
        let (provider, _) = await provider(tibber: tibber, clock: Clock(Self.morning))

        let result = await provider.resolve(zone: .se3)

        #expect(result.isFallback)
        #expect(result.tibberProblem?.isEmpty == false)
    }

    @Test
    func aHealthyTibberCarriesNoProblem() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let (provider, _) = await provider(tibber: tibber, clock: Clock(Self.morning))

        let result = await provider.resolve(zone: .se3)

        #expect(result.tibberProblem == nil)
        #expect(result.includesNetworkFee == false)
    }

    @Test
    func withoutTibberTheMarketSeriesIsUsed() async {
        let (provider, _) = await provider(tibber: nil, clock: Clock(Self.morning))

        let result = await provider.resolve(zone: .se3)

        #expect(result.origin == .elpriser)
        #expect(result.tibberConnected == false)
        #expect(result.isFallback == false)
        #expect(result.points.allSatisfy { $0.sekPerKwh == 0.50 })
    }

    @Test
    func aFailingTibberFallsBackToTheMarketSeriesAndSaysSo() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        await tibber.setFailing(true)
        let (provider, _) = await provider(tibber: tibber, clock: Clock(Self.morning))

        let result = await provider.resolve(zone: .se3)

        #expect(result.origin == .elpriser)
        #expect(result.isFallback)
        #expect(result.points.allSatisfy { $0.sekPerKwh == 0.50 })
    }

    @Test
    func aTibberSeriesThatEndsWithinTheHourIsNotUsed() async {
        let start = ElectricityPriceService.stockholmCalendar.startOfDay(for: Self.morning)
        let clock = Clock(Self.morning)
        // Ends at 10:30, 30 minutes ahead: no plan fits.
        let short = (0..<42).map {
            let from = start.addingTimeInterval(Double($0) * 900)
            return HomePricePoint(start: from, end: from.addingTimeInterval(900), pricePerKwh: 1.80)
        }
        let (provider, _) = await provider(tibber: Tibber(series: short), clock: clock)

        let result = await provider.resolve(zone: .se3)

        #expect(result.origin == .elpriser)
        #expect(result.isFallback)
    }

    @Test
    func aCompleteTibberCacheIsNotFetchedAgain() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let clock = Clock(Self.morning)
        let (provider, _) = await provider(tibber: tibber, clock: clock)

        _ = await provider.resolve(zone: .se3)
        clock.advance(600)
        _ = await provider.resolve(zone: .se3)

        #expect(await tibber.calls == 1)
    }

    @Test
    func aFailedFetchIsRetriedOnlyAfterTheRetryInterval() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        await tibber.setFailing(true)
        let clock = Clock(Self.morning)
        let (provider, _) = await provider(tibber: tibber, clock: clock)

        _ = await provider.resolve(zone: .se3)
        clock.advance(300)
        _ = await provider.resolve(zone: .se3)
        #expect(await tibber.calls == 1)

        await tibber.setFailing(false)
        clock.advance(PlannerPriceProvider.retryInterval)
        let recovered = await provider.resolve(zone: .se3)

        #expect(await tibber.calls == 2)
        #expect(recovered.origin == .tibber)
    }

    @Test
    func theLastGoodTibberSeriesKeepsServingWhileARetryFails() async {
        // 14:30, after publication: today's prices alone are incomplete, so every retry interval
        // asks Tibber again for tomorrow's.
        let afternoon = Self.morning.addingTimeInterval(4.5 * 3_600)
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80, days: 1))
        let clock = Clock(afternoon)
        let (provider, _) = await provider(tibber: tibber, clock: clock)
        _ = await provider.resolve(zone: .se3)

        await tibber.setFailing(true)
        clock.advance(PlannerPriceProvider.retryInterval + 60)
        let result = await provider.resolve(zone: .se3)

        #expect(await tibber.calls == 2)
        #expect(result.origin == .tibber)
        #expect(result.points.count == 96)
    }

    @Test
    func switchingTibberHomeDropsTheOldCache() async {
        let first = Tibber(series: Self.tibberSeries(price: 1.80))
        let clock = Clock(Self.morning)
        let spot = Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning)
        let provider = PlannerPriceProvider(spot: spot, now: { clock.current })
        let home = HomeBox("home-1")
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: home.id, fetch: { _, _ in try await first.fetch() })
        }
        _ = await provider.resolve(zone: .se3)

        home.id = "home-2"
        let second = Tibber(series: Self.tibberSeries(price: 2.20))
        provider.setTibberSource {
            PlannerPriceProvider.TibberSource(homeID: home.id, fetch: { _, _ in try await second.fetch() })
        }
        let result = await provider.resolve(zone: .se3)

        #expect(result.points.allSatisfy { $0.sekPerKwh == 2.20 })
        #expect(await first.calls == 1)
    }

    @Test
    func disconnectingTibberReturnsToTheMarketSeries() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let clock = Clock(Self.morning)
        let spot = Spot(series: Self.spotSeries(price: 0.50), fetched: Self.morning)
        let provider = PlannerPriceProvider(spot: spot, now: { clock.current })
        provider.setTibberSource { PlannerPriceProvider.TibberSource(homeID: "h", fetch: { _, _ in try await tibber.fetch() }) }
        #expect(await provider.resolve(zone: .se3).origin == .tibber)

        provider.setTibberSource { nil }

        let result = await provider.resolve(zone: .se3)
        #expect(result.origin == .elpriser)
        #expect(result.tibberConnected == false)
    }

    @Test
    func marketPricesIgnoreTibber() async {
        let tibber = Tibber(series: Self.tibberSeries(price: 1.80))
        let (provider, _) = await provider(tibber: tibber, clock: Clock(Self.morning))

        let market = await provider.marketPrices(for: .se3)

        #expect(market.allSatisfy { $0.sekPerKwh == 0.50 })
        #expect(await tibber.calls == 0)
    }

    @Test
    func anAllInPriceIsNotMarkedUpAgain() {
        let policy = ElectricityRatePolicy(mode: .automatic, provider: .tibber, contract: .quarterHour,
                                           markupOrePerKwh: 10, otherChargesOrePerKwh: 0, includesVAT: true)
        let slot = ElectricityPricePoint(startDate: Self.morning.addingTimeInterval(-60),
                                         endDate: Self.morning.addingTimeInterval(840), sekPerKwh: 1.00)
        let allIn = PlannerPrices(points: [slot], origin: .tibber, fetchedAt: nil, tibberConnected: true)
        let market = PlannerPrices(points: [slot], origin: .elpriser, fetchedAt: nil, tibberConnected: false)

        #expect(allIn.currentRate(policy: policy, at: Self.morning) == 1.00)
        #expect(market.currentRate(policy: policy, at: Self.morning) == (1.00 + 0.10) * 1.25)
    }
}

private final class HomeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String
    init(_ value: String) { self.value = value }
    var id: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}
