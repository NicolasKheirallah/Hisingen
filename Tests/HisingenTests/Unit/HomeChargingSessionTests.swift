import Foundation
import Testing
@testable import Hisingen

private let base = Date(timeIntervalSince1970: 1_780_000_000)

/// Energy readings that sit at `floor` until `startMinute`, then rise by `step` every `every` minutes.
private func risingEnergy(startMinute: Double, steps: Int, step: Double = 1.8, every: Double = 15,
                          floor: Double = 0, leadMinutes: Double = 30) -> [HAHistoryPoint] {
    var points = [history(String(floor), minutesFromStart: startMinute - leadMinutes, base: base)]
    points.append(history(String(floor), minutesFromStart: startMinute, base: base))
    for index in 1...steps {
        points.append(history(String(format: "%.2f", floor + step * Double(index)),
                              minutesFromStart: startMinute + every * Double(index), base: base))
    }
    return points
}

private func statusLine(_ entries: [(String, Double)]) -> [HAHistoryPoint] {
    entries.map { history($0.0, minutesFromStart: $0.1, base: base) }
}

@Suite("Home charger session reconstruction")
struct HomeSessionReconstructionTests {
    private let charger = "NX1234567"
    private let settled = base.addingTimeInterval(86_400)

    @Test("A rise in the session-energy counter becomes one session keyed by where the rise began")
    func oneSession() throws {
        let status = statusLine([("idle", -600), ("connected", -30), ("charging", 0), ("finished", 135)])
        let energy = risingEnergy(startMinute: 0, steps: 9)
        let sessions = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: energy, now: settled)
        let session = try #require(sessions.first)
        #expect(sessions.count == 1)
        #expect(session.keyKind == .history)
        #expect(session.key == "ha:NX1234567:\(Int(base.timeIntervalSince1970))")
        #expect(abs(session.energyKwh - 16.2) < 0.0001)
        #expect(session.startedAt == base)
        #expect(session.endedAt == base.addingTimeInterval(135 * 60))
        #expect(session.intervals.count == 9)
        #expect(session.hasPriceableIntervals)
        #expect(abs(session.intervalEnergyKwh - session.energyKwh) < 0.0001)
    }

    @Test("Reading the same history twice, or with more history around it, yields the same key")
    func stableKeyAcrossRepeatedSyncs() throws {
        let status = statusLine([("idle", -600), ("connected", -30), ("charging", 0), ("finished", 135)])
        let energy = risingEnergy(startMinute: 0, steps: 9)
        let first = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: energy, now: settled)
        let second = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: energy, now: settled.addingTimeInterval(3_600))
        #expect(first == second)

        // A wider window that also holds an earlier session, as the next day's sync would fetch.
        let earlier = risingEnergy(startMinute: -2_000, steps: 4, leadMinutes: 60)
        let reset = [history("0.0", minutesFromStart: -900, base: base)]
        let wider = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: earlier + reset + energy, now: settled)
        #expect(wider.contains { $0.key == first[0].key })
        #expect(wider.count == 2)
    }

    @Test("A counter reset starts a new session")
    func resetSplits() {
        var energy = risingEnergy(startMinute: 0, steps: 9)
        energy.append(history("0.0", minutesFromStart: 600, base: base))
        energy.append(history("0.0", minutesFromStart: 640, base: base))
        for step in 1...3 { energy.append(history(String(format: "%.2f", 1.8 * Double(step)), minutesFromStart: 640 + 15 * Double(step), base: base)) }
        let status = statusLine([("charging", 0), ("finished", 135), ("charging", 640), ("finished", 700)])
        let sessions = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: energy, now: settled)
        #expect(sessions.count == 2)
        #expect(abs(sessions[1].energyKwh - 5.4) < 0.0001)
        #expect(sessions[0].key != sessions[1].key)
    }

    @Test("The cable coming out closes a session even when the counter did not reset")
    func unplugSplits() {
        var energy = risingEnergy(startMinute: 0, steps: 9)
        energy.append(history("16.2", minutesFromStart: 900, base: base))
        energy.append(history("18.0", minutesFromStart: 915, base: base))
        let status = statusLine([("charging", 0), ("finished", 135), ("idle", 300), ("connected", 880), ("charging", 900)])
        let sessions = HomeSessionReconstructor.reconstruct(chargerID: charger, status: status, energy: energy, now: settled)
        // The first session is whole; the rise after re-plugging is not attributed to it.
        #expect(sessions.first.map { abs($0.energyKwh - 16.2) < 0.0001 } == true)
        #expect(sessions.allSatisfy { $0.endedAt <= base.addingTimeInterval(135 * 60) || $0.startedAt >= base.addingTimeInterval(300 * 60) })
    }

    @Test("A session already under way at the start of the window is skipped instead of keyed wrongly")
    func partialFirstSessionSkipped() {
        let energy = [history("8.0", minutesFromStart: 0, base: base),
                      history("9.8", minutesFromStart: 15, base: base),
                      history("11.6", minutesFromStart: 30, base: base)]
        let sessions = HomeSessionReconstructor.reconstruct(chargerID: charger, status: [], energy: energy, now: settled)
        #expect(sessions.isEmpty)
    }

    @Test("The newest session is left alone while it may still be running")
    func unsettledSessionWaits() {
        let energy = risingEnergy(startMinute: 0, steps: 4)
        let lastRise = base.addingTimeInterval(60 * 60)
        let charging = statusLine([("charging", 0)])
        #expect(HomeSessionReconstructor.reconstruct(chargerID: charger, status: charging, energy: energy,
                                                      now: lastRise.addingTimeInterval(10 * 60)).isEmpty)
        // Still charging long after the last rise: the charger is just slow to report, not done.
        #expect(HomeSessionReconstructor.reconstruct(chargerID: charger, status: charging, energy: energy,
                                                      now: lastRise.addingTimeInterval(3 * 3_600)).isEmpty)
        let finished = statusLine([("charging", 0), ("finished", 61)])
        #expect(HomeSessionReconstructor.reconstruct(chargerID: charger, status: finished, energy: energy,
                                                      now: lastRise.addingTimeInterval(40 * 60)).count == 1)
    }

    @Test("Unavailable readings are ignored and noise-sized sessions are dropped")
    func noiseAndGaps() {
        var energy = risingEnergy(startMinute: 0, steps: 3)
        energy.insert(history("unavailable", minutesFromStart: 20, base: base), at: 3)
        let sessions = HomeSessionReconstructor.reconstruct(chargerID: charger, status: [], energy: energy, now: settled)
        #expect(sessions.count == 1)
        let tiny = [history("0", minutesFromStart: 0, base: base), history("0.04", minutesFromStart: 15, base: base)]
        #expect(HomeSessionReconstructor.reconstruct(chargerID: charger, status: [], energy: tiny, now: settled).isEmpty)
    }

    @Test("A long gap between readings is a total, not a profile")
    func coarseResolution() throws {
        let energy = [history("0", minutesFromStart: 0, base: base), history("0", minutesFromStart: 30, base: base),
                      history("9.0", minutesFromStart: 150, base: base)]
        let session = try #require(HomeSessionReconstructor.reconstruct(chargerID: charger, status: [], energy: energy, now: settled).first)
        #expect(abs(session.energyKwh - 9.0) < 0.0001)
        #expect(!session.hasPriceableIntervals)
    }

    @Test("The durable capture response decodes sessions and drops entries without an id")
    func captureResponse() throws {
        let response = try JSONDecoder().decode(HAJSONValue.self, from: fixtureData("home-assistant-capture-sessions"))
        let candidates = HomeCaptureSessions.candidates(from: try #require(response.objectValue?["service_response"]), chargerID: "NX1234567")
        #expect(candidates.count == 1)
        let session = try #require(candidates.first)
        #expect(session.key == "capture:NX1234567:c0ffee01")
        #expect(session.keyKind == .captureID)
        #expect(session.vehicleStartPercent == 41)
        #expect(session.intervals.count == 2)
    }
}

@Suite("Home charger session attribution")
struct HomeSessionAttributionTests {
    private func candidate(start: Double = 0, end: Double = 120) -> HomeChargingSessionCandidate {
        HomeChargingSessionCandidate(
            key: "ha:NX1234567:1", keyKind: .history, chargerID: "NX1234567",
            startedAt: base.addingTimeInterval(start * 60), endedAt: base.addingTimeInterval(end * 60),
            energyKwh: 14, energySource: "ha_session_energy_sensor", measuredAt: base.addingTimeInterval(end * 60))
    }

    private func observed(_ vin: String, start: Double, end: Double, id: String = "row") -> ObservedVehicleSession {
        ObservedVehicleSession(id: id, vin: vin, start: base.addingTimeInterval(start * 60), end: base.addingTimeInterval(end * 60))
    }

    @Test("A dedicated charger with no competing evidence belongs to the paired vehicle")
    func dedicated() {
        let decision = HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(), observed: [])
        #expect(decision == .newForVehicle(vin: "YSMTEST"))
    }

    @Test("A shared charger never attributes on its own, however close the vehicle is")
    func sharedChargerNeedsOverlap() {
        let shared = NexBlueFixture.pairing(shared: true)
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: shared, observed: [])
                == .unassigned(.sharedChargerWithoutOverlap))
        // A vehicle session hours away is not evidence.
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: shared,
                                               observed: [observed("YSMTEST", start: 600, end: 700)])
                == .unassigned(.sharedChargerWithoutOverlap))
        // The paired vehicle charging at the same time is.
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: shared,
                                               observed: [observed("YSMTEST", start: 5, end: 115, id: "mine")])
                == .enrich(rowID: "mine", vin: "YSMTEST"))
    }

    @Test("Another vehicle charging at the same time makes the session ambiguous, even on a dedicated charger")
    func ambiguousWithAnotherVehicle() {
        let other = observed("YSMOTHER", start: 0, end: 120, id: "theirs")
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(), observed: [other])
                == .unassigned(.overlapsAnotherVehicle))
        let both = [observed("YSMTEST", start: 0, end: 120, id: "mine"), other]
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(shared: true), observed: both)
                == .unassigned(.overlapsAnotherVehicle))
    }

    @Test("Overlap is judged against the shorter session, and a brush is not a match")
    func overlapThreshold() {
        let brush = observed("YSMTEST", start: 110, end: 400, id: "brush")
        #expect(HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(shared: true), observed: [brush])
                == .unassigned(.sharedChargerWithoutOverlap))
    }
}

@Suite("Home charger session pricing")
struct HomeSessionPricingTests {
    private func session(intervals: [(Double, Double, Double)]) -> HomeChargingSessionCandidate {
        let list = intervals.map { HomeEnergyInterval(start: base.addingTimeInterval($0.0 * 60), end: base.addingTimeInterval($0.1 * 60), kwh: $0.2) }
        return HomeChargingSessionCandidate(
            key: "k", keyKind: .history, chargerID: "NX1234567", startedAt: list.first!.start, endedAt: list.last!.end,
            energyKwh: list.reduce(0) { $0 + $1.kwh }, energySource: "ha_session_energy_sensor",
            measuredAt: list.last!.end, intervals: list)
    }

    private func slots(_ prices: [Double], from startMinute: Double = 0) -> [HomePricePoint] {
        prices.enumerated().map { index, price in
            HomePricePoint(start: base.addingTimeInterval((startMinute + 15 * Double(index)) * 60),
                           end: base.addingTimeInterval((startMinute + 15 * Double(index + 1)) * 60), pricePerKwh: price)
        }
    }

    /// Typed comparison helper: `abs((x ?? 0) - a * (b + c)) < e` inside `#expect` is more than
    /// the pinned Xcode can type-check in reasonable time.
    private func near(_ value: Double?, _ expected: Double) -> Bool {
        abs((value ?? 0) - expected) < 0.0001
    }

    private let fallback = HomeSessionPricer.Fallback(fixedPricePerKwh: 2.0, policy: .fixed, spotPrices: [], currency: "kr")

    @Test("Measured energy is priced per 15-minute interval against Tibber")
    func intervalPricing() {
        let session = session(intervals: [(0, 15, 1.8), (15, 30, 1.8), (30, 45, 1.8)])
        let cost = HomeSessionPricer.price(session, tibber: slots([0.60, 0.40, 0.20]), networkFeeOrePerKwh: 0, fallback: fallback)
        #expect(cost.method == .intervalTibber)
        #expect(near(cost.amount, 1.8 * (0.60 + 0.40 + 0.20)))
        #expect(!cost.isEstimate)
        #expect(cost.missingKwh < 0.0001)
        #expect(cost.priceSource.contains("Tibber"))
    }

    @Test("An interval that straddles two price slots is split by time")
    func straddlingInterval() {
        let session = session(intervals: [(10, 20, 1.2)])
        let cost = HomeSessionPricer.price(session, tibber: slots([0.50, 0.30]), networkFeeOrePerKwh: 0, fallback: fallback)
        // 5 of 10 minutes in each slot: 0.6 kWh at 0.50 and 0.6 kWh at 0.30.
        #expect(near(cost.amount, 0.6 * 0.50 + 0.6 * 0.30))
    }

    @Test("Missing price intervals are missing data: no total, and the gap is stated")
    func missingIntervals() {
        let session = session(intervals: [(0, 15, 1.8), (15, 30, 1.8), (30, 45, 1.8)])
        let cost = HomeSessionPricer.price(session, tibber: slots([0.60, 0.40]), networkFeeOrePerKwh: 0, fallback: fallback)
        #expect(cost.amount == nil)
        #expect(cost.isIncomplete)
        #expect(abs(cost.missingKwh - 1.8) < 0.0001)
        #expect(abs(cost.pricedKwh - 3.6) < 0.0001)
        #expect(near(cost.partialAmount, 1.8 * (0.60 + 0.40)))
        #expect(cost.method == .intervalTibber)
    }

    @Test("Tibber's price already holds taxes and markup, so only the network fee is added")
    func feesOnlyWhereTheSourceLeavesThemOut() {
        let session = session(intervals: [(0, 15, 2.0)])
        let policy = ElectricityRatePolicy(mode: .automatic, provider: .tibber, contract: .quarterHour,
                                           markupOrePerKwh: 10, otherChargesOrePerKwh: 50, includesVAT: true)
        let withPolicy = HomeSessionPricer.Fallback(fixedPricePerKwh: 2, policy: policy, spotPrices: [], currency: "kr")
        let plain = HomeSessionPricer.price(session, tibber: slots([0.50]), networkFeeOrePerKwh: 0, fallback: withPolicy)
        #expect(near(plain.amount, 1.0))
        #expect(plain.assumptions.contains { $0.contains("No variable network fee") })
        let fee = HomeSessionPricer.price(session, tibber: slots([0.50]), networkFeeOrePerKwh: 25, fallback: withPolicy)
        #expect(near(fee.amount, 2.0 * (0.50 + 0.25)))
        #expect(fee.assumptions.contains { $0.contains("25.0") })
    }

    @Test("A session total with no intervals is an estimate and records how it was estimated")
    func totalOnly() {
        var coarse = session(intervals: [(0, 45, 9.0)])
        #expect(!coarse.hasPriceableIntervals)
        let tibber = HomeSessionPricer.price(coarse, tibber: slots([0.60, 0.30, 0.30]), networkFeeOrePerKwh: 0, fallback: fallback)
        #expect(tibber.method == .totalTibberAverage)
        #expect(tibber.isEstimate)
        #expect(near(tibber.amount, 9.0 * 0.40))

        // No Tibber slots: the typed-in tariff, recorded as such.
        let fixed = HomeSessionPricer.price(coarse, tibber: [], networkFeeOrePerKwh: 0, fallback: fallback)
        #expect(fixed.method == .totalFixedTariff)
        #expect(near(fixed.amount, 18.0))
        #expect(fixed.priceSource == HomeSessionPricer.tariffSource)

        // Automatic mode with spot prices: market price plus the Hisingen markup, charges and VAT.
        let policy = ElectricityRatePolicy(mode: .automatic, provider: .tibber, contract: .quarterHour,
                                           markupOrePerKwh: 10, otherChargesOrePerKwh: 40, includesVAT: true)
        let spot = (0..<3).map { index in
            ElectricityPricePoint(startDate: base.addingTimeInterval(Double(index) * 900),
                                  endDate: base.addingTimeInterval(Double(index + 1) * 900), sekPerKwh: 0.40)
        }
        let automatic = HomeSessionPricer.Fallback(fixedPricePerKwh: 2, policy: policy, spotPrices: spot, currency: "kr")
        let policyCost = HomeSessionPricer.price(coarse, tibber: [], networkFeeOrePerKwh: 0, fallback: automatic)
        #expect(policyCost.method == .totalSpotPolicy)
        #expect(near(policyCost.amount, 9.0 * (0.40 + 0.50) * 1.25))
        coarse.intervals = []
        #expect(HomeSessionPricer.price(coarse, tibber: slots([0.4, 0.4, 0.4]), networkFeeOrePerKwh: 0, fallback: fallback).method == .totalTibberAverage)
    }
}
