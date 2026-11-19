import Foundation
import Testing
@testable import Hisingen

@Suite("House load share")
struct HouseLoadShareTests {
    private let base = Date(timeIntervalSince1970: 1_793_998_800)   // on the hour

    private func hours(_ count: Int, kwh: Double = 2.0, unitPrice: Double? = nil, currency: String? = "SEK") -> [TibberConsumptionHour] {
        (0..<count).map {
            let start = base.addingTimeInterval(Double($0) * 3_600)
            return TibberConsumptionHour(start: start, end: start.addingTimeInterval(3_600), kwh: kwh,
                                         cost: unitPrice.map { $0 * kwh }, currency: unitPrice == nil ? nil : currency)
        }
    }

    private func session(startHour: Double, endHour: Double, wallboxKwh: Double?, estimateKwh: Double = 0) -> HistoricalChargingSession {
        let start = base.addingTimeInterval(startHour * 3_600)
        let end = base.addingTimeInterval(endHour * 3_600)
        let wallbox = wallboxKwh.map {
            WallboxMeasurement(chargerID: "c", sessionKey: "k\(startHour)", keyKind: "test", energyKwh: $0, energySource: "test",
                               measuredAt: end, startedAt: start, endedAt: end, peakPowerKw: nil, cost: nil, partialCost: nil,
                               costMethod: nil, priceSource: nil, costAssumptions: [], missingKwh: nil, currency: nil, attribution: nil)
        }
        return HistoricalChargingSession(id: "s\(startHour)", vin: "VIN", startedAt: start, endedAt: end, startSoc: 20, endSoc: 80,
                                         energyDeliveredKwh: estimateKwh, peakPowerKw: 7, averagePowerKw: 5,
                                         locationName: nil, createdAt: start, wallbox: wallbox)
    }

    @Test("A session's metered energy is spread over its span and added to the hours it covers")
    func spreadsOverTheSpan() throws {
        // 4 kWh over hours 2 to 4; the house drew 2 kWh in each of 8 hours.
        let share = try #require(HouseLoad.share(hours: hours(8), sessions: [session(startHour: 2, endHour: 4, wallboxKwh: 4)]))
        #expect(share.hours == 8)
        #expect(abs(share.houseKwh - 16) < 1e-9)
        #expect(abs(share.carKwh - 4) < 1e-9)
        #expect(abs(share.restKwh - 12) < 1e-9)
        #expect(abs(share.carShare - 0.25) < 1e-9)
        #expect(share.sessions == 1)
    }

    @Test("Only the part of a session inside the metered hours counts")
    func clipsToTheMeteredWindow() throws {
        // 8 kWh over hours 6 to 10, but readings stop at hour 8: half the session is outside them.
        let share = try #require(HouseLoad.share(hours: hours(8), sessions: [session(startHour: 6, endHour: 10, wallboxKwh: 8)]))
        #expect(abs(share.carKwh - 4) < 1e-9)
    }

    @Test("The car cannot draw more than the meter saw in an hour")
    func capsAtTheHour() throws {
        let share = try #require(HouseLoad.share(hours: hours(4, kwh: 1.0), sessions: [session(startHour: 0, endHour: 1, wallboxKwh: 9)]))
        #expect(share.carKwh == 1.0)
        #expect(share.carShare <= 1)
    }

    @Test("An hour the spread overshoots is cut to the meter's reading and the cut is reported")
    func reportsTheCap() throws {
        let share = try #require(HouseLoad.share(hours: hours(4, kwh: 1.0), sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 5)]))
        // 2.5 kWh a hour against a 1 kWh meter, for two hours: 1.5 kWh cut in each.
        #expect(share.cappedHours == 2)
        #expect(abs(share.cappedKwh - 3) < 1e-9)
        #expect(abs(share.carKwh - 2) < 1e-9)
        // A spread that agrees with the meter reports no cut.
        let clean = try #require(HouseLoad.share(hours: hours(4), sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 2)]))
        #expect(clean.cappedHours == 0)
        #expect(clean.cappedKwh == 0)
    }

    @Test("Cost follows the energy: the house's billed total and the car's part at each hour's own price")
    func costs() throws {
        var series = hours(4, kwh: 2.0, unitPrice: 1.0)
        // Hours 2 and 3 cost 3 kr per kWh.
        for index in 2..<4 { series[index].cost = 6.0 }
        let share = try #require(HouseLoad.share(hours: series, sessions: [session(startHour: 1, endHour: 3, wallboxKwh: 4)]))
        // 2 kWh in hour 1 at 1 kr, 2 kWh in hour 2 at 3 kr.
        #expect(abs((share.carCost ?? 0) - 8) < 1e-9)
        #expect(abs((share.houseCost ?? 0) - (2 + 2 + 6 + 6)) < 1e-9)
        #expect(share.currency == "SEK")
    }

    @Test("Costs are left out when an hour has none or the currencies differ, but the energy still counts")
    func costsNeedEveryHour() throws {
        var missing = hours(4, kwh: 2.0, unitPrice: 1.0)
        missing[1].cost = nil
        let partial = try #require(HouseLoad.share(hours: missing, sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 2)]))
        #expect(partial.houseCost == nil && partial.carCost == nil && partial.currency == nil)
        #expect(abs(partial.carKwh - 2) < 1e-9)

        var mixed = hours(4, kwh: 2.0, unitPrice: 1.0)
        mixed[3].currency = "EUR"
        let two = try #require(HouseLoad.share(hours: mixed, sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 2)]))
        #expect(two.houseCost == nil && two.carCost == nil)

        let free = try #require(HouseLoad.share(hours: hours(4), sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 2)]))
        #expect(free.houseCost == nil)
    }

    @Test("Sessions the charger did not measure are not counted, because the house meter never saw them")
    func ignoresUnmeasuredSessions() {
        let share = HouseLoad.share(hours: hours(8), sessions: [session(startHour: 2, endHour: 4, wallboxKwh: nil, estimateKwh: 30)])
        #expect(share == nil)
    }

    @Test("An hour without a reading is not a zero hour, and no readings means no answer")
    func noReadings() {
        #expect(HouseLoad.share(hours: [], sessions: [session(startHour: 0, endHour: 2, wallboxKwh: 3)]) == nil)
        // A session entirely outside the readings reports nothing rather than a share of zero.
        #expect(HouseLoad.share(hours: hours(4), sessions: [session(startHour: 20, endHour: 22, wallboxKwh: 3)]) == nil)
    }

    @Test("Overlapping sessions add up, and each is counted once")
    func severalSessions() throws {
        let share = try #require(HouseLoad.share(hours: hours(10), sessions: [
            session(startHour: 0, endHour: 2, wallboxKwh: 2), session(startHour: 5, endHour: 6, wallboxKwh: 1)]))
        #expect(abs(share.carKwh - 3) < 1e-9)
        #expect(share.sessions == 2)
        #expect(share.coveredFrom == base)
        #expect(share.coveredTo == base.addingTimeInterval(10 * 3_600))
    }
}

@Suite("Tibber price levels")
struct TibberPriceLevelTests {
    private let base = Date(timeIntervalSince1970: 1_794_000_000)

    private func prices(_ levels: [TibberPriceLevel?], origin: PlannerPriceOrigin = .tibber) -> PlannerPrices {
        let points = levels.enumerated().map { index, level in
            ElectricityPricePoint(startDate: base.addingTimeInterval(Double(index) * 900),
                                  endDate: base.addingTimeInterval(Double(index + 1) * 900), sekPerKwh: 1, level: level)
        }
        return PlannerPrices(points: points, origin: origin, fetchedAt: nil, tibberConnected: true, tibberProblem: nil)
    }

    @Test("The level of the slot that covers a moment")
    func currentLevel() {
        let series = prices([.cheap, .expensive])
        #expect(series.level(at: base.addingTimeInterval(60)) == .cheap)
        #expect(series.level(at: base.addingTimeInterval(1_000)) == .expensive)
        #expect(series.level(at: base.addingTimeInterval(5_000)) == nil)
    }

    @Test("Market prices carry no level, so none is shown")
    func marketHasNone() {
        let series = prices([.cheap, .cheap], origin: .elpriser)
        #expect(series.level(at: base) == nil)
        #expect(series.level(from: base, to: base.addingTimeInterval(1_800)) == nil)
    }

    @Test("A window reads as the rounded average of its slots, and as nothing when a slot is unrated")
    func windowLevel() {
        let end = base.addingTimeInterval(4 * 900)
        #expect(prices([.veryCheap, .veryCheap, .cheap, .veryCheap]).level(from: base, to: end) == .veryCheap)
        // Half-way rounds up the scale.
        #expect(prices([.veryCheap, .cheap, .cheap, .veryCheap]).level(from: base, to: end) == .cheap)
        #expect(prices([.cheap, .cheap, .cheap, .cheap]).level(from: base, to: end) == .cheap)
        #expect(prices([.normal, .expensive, .expensive, .expensive]).level(from: base, to: end) == .expensive)
        #expect(prices([.cheap, nil, .cheap, .cheap]).level(from: base, to: end) == nil)
    }

    @Test("Levels run cheapest to dearest and a rank is clamped into the scale")
    func ranks() {
        #expect(TibberPriceLevel.allCases.map(\.rank) == [0, 1, 2, 3, 4])
        #expect(TibberPriceLevel(rank: -3) == .veryCheap)
        #expect(TibberPriceLevel(rank: 9) == .veryExpensive)
    }
}
