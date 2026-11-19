import Foundation
import Testing
@testable import Hisingen

private let t0 = Date(timeIntervalSince1970: 1_795_000_000)

private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func slot(_ fromMinute: Double, _ price: Double) -> HomePricePoint {
    HomePricePoint(start: at(fromMinute), end: at(fromMinute + 15), pricePerKwh: price)
}

@Suite("Session price series")
struct SessionPriceSeriesTests {
    @Test("Tibber slots outside the session are dropped and each kept slot carries the grid fee")
    func tibberAddsGridFee() throws {
        let points = [slot(-15, 9), slot(0, 1.00), slot(15, 2.00), slot(30, 9)]
        let series = try #require(SessionPriceSeries.tibber(points, gridTariff: .flat(orePerKwh: 44.5),
                                                            from: at(0), to: at(30)))
        #expect(series.basis == .tibberWithGridFee)
        #expect(series.slots.count == 2)
        #expect(abs(series.slots[0].pricePerKwh - 1.445) < 1e-9)
        #expect(abs(series.slots[1].pricePerKwh - 2.445) < 1e-9)
    }

    @Test("No slot over the session gives no series, so the chart draws nothing")
    func emptyWhenUncovered() {
        #expect(SessionPriceSeries.tibber([slot(60, 1)], gridTariff: .none, from: at(0), to: at(30)) == nil)
    }

    @Test("The price at a moment is the slot it falls in")
    func priceAtMoment() throws {
        let series = try #require(SessionPriceSeries.tibber([slot(0, 1), slot(15, 2)], gridTariff: .none,
                                                            from: at(0), to: at(30)))
        #expect(series.price(at: at(5)) == 1)
        #expect(series.price(at: at(15)) == 2)
        #expect(series.price(at: at(45)) == nil)
    }

    @Test("The average follows the energy, not the clock: idle slots weigh nothing")
    func energyWeightedAverage() throws {
        let series = try #require(SessionPriceSeries.tibber([slot(0, 1), slot(15, 3)], gridTariff: .none,
                                                            from: at(0), to: at(30)))
        // 11 kW through the cheap slot, then a stop: the expensive slot gets no energy.
        let charging: [(Date, Double)] = [(at(0), 11), (at(15), 0)]
        #expect(series.energyWeightedAverage(power: charging, until: at(30)) == 1)
        // Equal power in both slots gives the plain mean.
        let steady: [(Date, Double)] = [(at(0), 11)]
        #expect(series.energyWeightedAverage(power: steady, until: at(30)) == 2)
        #expect(series.energyWeightedAverage(power: [], until: at(30)) == nil)
    }

    @Test("A fixed rate policy shows the bare market price and says so; automatic adds markup and VAT")
    func spotBasis() throws {
        let points = [ElectricityPricePoint(startDate: at(0), endDate: at(15), sekPerKwh: 1)]
        let fixed = ElectricityRatePolicy(mode: .fixed, provider: .tibber, contract: .quarterHour,
                                          markupOrePerKwh: 10, otherChargesOrePerKwh: 0, includesVAT: true)
        let bare = try #require(SessionPriceSeries.spot(points, policy: fixed, from: at(0), to: at(15)))
        #expect(bare.basis == .spot)
        #expect(bare.slots.first?.pricePerKwh == 1)

        let automatic = ElectricityRatePolicy(mode: .automatic, provider: .tibber, contract: .quarterHour,
                                              markupOrePerKwh: 10, otherChargesOrePerKwh: 0, includesVAT: true)
        let retail = try #require(SessionPriceSeries.spot(points, policy: automatic, from: at(0), to: at(15)))
        #expect(retail.basis == .spotWithRates)
        #expect(abs((retail.slots.first?.pricePerKwh ?? 0) - automatic.retailPrice(spotSekPerKwh: 1)) < 1e-9)
    }
}
