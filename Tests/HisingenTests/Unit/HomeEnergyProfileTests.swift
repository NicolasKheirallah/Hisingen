import Foundation
import Testing
@testable import Hisingen

private let hour0 = Date(timeIntervalSince1970: 1_794_999_600)

private func at(_ minutes: Double) -> Date { hour0.addingTimeInterval(minutes * 60) }

private func hours(_ values: [(Double, Double)]) -> [HomeEnergyProfile.Hour] {
    values.map { HomeEnergyProfile.Hour(start: at($0.0 * 60), kwh: $0.1) }
}

@Suite("Charger energy profile")
struct HomeEnergyProfileTests {
    @Test("Each hour with energy becomes quarter-hour pieces that add back to the hour")
    func slicesHours() throws {
        let result = try #require(HomeEnergyProfile.intervals(from: hours([(0, 10), (1, 10)]),
                                                              startedAt: at(0), endedAt: at(180), energyKwh: 20))
        #expect(result.count == 8)
        #expect(result.allSatisfy { $0.end.timeIntervalSince($0.start) <= HomeChargingSessionCandidate.maximumPriceableInterval })
        #expect(abs(result.reduce(0) { $0 + $1.kwh } - 20) < 1e-9)
        #expect(result.first?.start == at(0) && result.last?.end == at(120))
    }

    @Test("A session starting mid-hour takes that hour's energy over the part it was in")
    func clipsEdges() throws {
        let result = try #require(HomeEnergyProfile.intervals(from: hours([(0, 2)]),
                                                              startedAt: at(49), endedAt: at(300), energyKwh: 2))
        #expect(result.first?.start == at(49))
        #expect(result.last?.end == at(60))
    }

    @Test("Hours that drew nothing are not part of the profile, so idle time costs nothing")
    func skipsIdleHours() throws {
        let result = try #require(HomeEnergyProfile.intervals(from: hours([(0, 5), (6, 0), (7, 5)]),
                                                              startedAt: at(0), endedAt: at(600), energyKwh: 10))
        #expect(result.allSatisfy { $0.start < at(60) || $0.start >= at(420) })
    }

    @Test("Readings are scaled to the session total when they differ by a little")
    func scalesSmallDifference() throws {
        let result = try #require(HomeEnergyProfile.intervals(from: hours([(0, 10)]), startedAt: at(0), endedAt: at(60), energyKwh: 10.3))
        #expect(abs(result.reduce(0) { $0 + $1.kwh } - 10.3) < 1e-9)
    }

    @Test("Readings that do not match the session, such as a second session in the same hours, are refused")
    func refusesMismatch() {
        #expect(HomeEnergyProfile.intervals(from: hours([(0, 10)]), startedAt: at(0), endedAt: at(60), energyKwh: 6) == nil)
        #expect(HomeEnergyProfile.intervals(from: [], startedAt: at(0), endedAt: at(60), energyKwh: 6) == nil)
    }
}

@Suite("Pricing a session by when its energy flowed")
struct HomeEnergyProfilePricingTests {
    private func slot(_ minute: Double, _ price: Double) -> HomePricePoint {
        HomePricePoint(start: at(minute), end: at(minute + 15), pricePerKwh: price)
    }

    private let fallback = HomeSessionPricer.Fallback(fixedPricePerKwh: 1, policy: .fixed, spotPrices: [], currency: "kr")

    @Test("Energy in cheap hours is not priced at the average of a long plug-in")
    func idleHoursDoNotCount() throws {
        // 10 kWh drawn in the first hour at 1 kr, then six idle hours at 5 kr.
        let slots = (0..<28).map { slot(Double($0) * 15, $0 < 4 ? 1 : 5) }
        var candidate = HomeChargingSessionCandidate(
            key: "k", keyKind: .vendorWindow, chargerID: "c", startedAt: at(0), endedAt: at(420),
            energyKwh: 10, energySource: "nexblue_session_api", measuredAt: at(420))
        let totalOnly = HomeSessionPricer.price(candidate, tibber: slots, gridTariff: .none, fallback: fallback)
        #expect(totalOnly.method == .totalTibberAverage)

        candidate.intervals = try #require(HomeEnergyProfile.intervals(from: hours([(0, 10)]),
                                                                       startedAt: at(0), endedAt: at(420), energyKwh: 10))
        candidate.energyProfileNote = HomeEnergyProfile.note
        let profiled = HomeSessionPricer.price(candidate, tibber: slots, gridTariff: .none, fallback: fallback)
        #expect(profiled.method == .intervalTibber)
        #expect(abs((profiled.amount ?? 0) - 10) < 1e-9)
        #expect((totalOnly.amount ?? 0) > 40)
        #expect(profiled.assumptions.contains(HomeEnergyProfile.note))
    }
}
