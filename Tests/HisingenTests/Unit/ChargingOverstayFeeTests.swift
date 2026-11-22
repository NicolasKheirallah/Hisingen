import Foundation
import Testing
@testable import Hisingen

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: hour, minute: minute))!
}

private func wallbox(chargerID: String = "CHARGER-1", endedAt: Date?) -> WallboxMeasurement {
    WallboxMeasurement(
        chargerID: chargerID, sessionKey: "key", keyKind: "vendor_session_id",
        energyKwh: 10, energySource: "easee_session_api", measuredAt: endedAt ?? at(12),
        startedAt: at(8), endedAt: endedAt, peakPowerKw: 7,
        cost: nil, partialCost: nil, costMethod: nil, priceSource: nil,
        costAssumptions: [], missingKwh: nil, currency: "kr", attribution: "overlap",
        startReason: nil, stopReason: nil
    )
}

private func session(
    finished: Date? = at(10),
    lifecycle: ChargingSessionLifecycleState = .completed,
    location: String? = "Home",
    wallboxEndedAt: Date? = at(12),
    estimatedCost: Double? = 20,
    energyKwh: Double = 10
) -> HistoricalChargingSession {
    HistoricalChargingSession(
        id: "s", vin: "VIN", startedAt: at(8), endedAt: finished,
        startSoc: 20, endSoc: 60, energyDeliveredKwh: energyKwh,
        peakPowerKw: 7, averagePowerKw: 7, locationName: location, createdAt: at(8),
        lifecycleState: lifecycle, estimatedCost: estimatedCost,
        wallbox: wallboxEndedAt.map { wallbox(endedAt: $0) }
    )
}

private func rule(scope: ChargingOverstayRule.Scope = .charger, target: String = "CHARGER-1",
                  graceMinutes: Int = 10, amount: Double = 60, unit: ChargingOverstayRule.Unit = .perHour,
                  currency: String = "kr") -> ChargingOverstayRule {
    ChargingOverstayRule(id: "r", scope: scope, target: target, graceMinutes: graceMinutes,
                         amount: amount, unit: unit, currencySymbol: currency)
}

struct ChargingOverstayFeeTests {
    // 08:00 to 10:00 charging finished; the charger session ran to 12:00.
    @Test
    func feeIsChargedForTheTimeTheChargerRanPastTheFinish() throws {
        let fee = ChargingOverstayFee.resolve(session: session(), rules: [rule()])
        let resolved = try #require(fee)
        #expect(resolved.overstay == 2 * 3_600)
        #expect(resolved.billableMinutes == 110) // 120 minutes minus 10 minutes grace
        // 60 kr/h for 110 minutes = 110.00
        #expect(abs(resolved.amount - 110) < 0.0001)
    }

    @Test
    func perMinuteRateMultipliesTheBilledMinutes() throws {
        let fee = ChargingOverstayFee.resolve(
            session: session(wallboxEndedAt: at(10).addingTimeInterval(25 * 60)),
            rules: [rule(graceMinutes: 0, amount: 0.10, unit: .perMinute)]
        )
        let resolved = try #require(fee)
        #expect(resolved.billableMinutes == 25)
        #expect(abs(resolved.amount - 2.50) < 0.0001)
    }

    @Test
    func partialMinutesRoundUp() throws {
        let fee = ChargingOverstayFee.resolve(
            session: session(wallboxEndedAt: at(10).addingTimeInterval(10 * 60 + 31)),
            rules: [rule(graceMinutes: 10, amount: 6, unit: .perHour)]
        )
        let resolved = try #require(fee)
        #expect(resolved.billableMinutes == 1) // one started minute after the grace
        #expect(abs(resolved.amount - 0.10) < 0.0001) // 6 kr/h for one minute
    }

    @Test
    func endingInsideTheGracePeriodEarnsNoFee() {
        #expect(ChargingOverstayFee.resolve(
            session: session(wallboxEndedAt: at(10).addingTimeInterval(10 * 60)),
            rules: [rule(graceMinutes: 10)]
        ) == nil)
    }

    @Test
    func timestampNoiseShorterThanThirtySecondsIsNotABillableMinute() {
        #expect(ChargingOverstayFee.resolve(
            session: session(wallboxEndedAt: at(10).addingTimeInterval(20)),
            rules: [rule(graceMinutes: 0)]
        ) == nil)
    }

    @Test
    func aSessionWithoutAChargerRecordKeepsNoFee() {
        #expect(ChargingOverstayFee.resolve(session: session(wallboxEndedAt: nil), rules: [rule()]) == nil)
    }

    @Test
    func aChargerSessionThatEndedBeforeTheVehicleFinishedKeepsNoFee() {
        #expect(ChargingOverstayFee.resolve(
            session: session(wallboxEndedAt: at(9)), rules: [rule()]
        ) == nil)
    }

    @Test
    func activeSessionKeepsNoFee() {
        #expect(ChargingOverstayFee.resolve(
            session: session(finished: nil, lifecycle: .active, wallboxEndedAt: at(12)),
            rules: [rule()]
        ) == nil)
    }

    @Test
    func staleAbandonedSessionKeepsNoFee() {
        // An abandoned row's end is the last observation, not the moment charging really finished,
        // so a fee worked from it would charge for time the app never saw.
        #expect(ChargingOverstayFee.resolve(
            session: session(lifecycle: .abandoned), rules: [rule()]
        ) == nil)
    }

    @Test
    func aZeroOrMissingRateKeepsNoFee() {
        #expect(ChargingOverstayFee.resolve(session: session(), rules: [rule(amount: 0)]) == nil)
        #expect(ChargingOverstayFee.resolve(session: session(), rules: [rule(amount: .nan)]) == nil)
    }

    @Test
    func theChargerRuleWinsOverALocationRule() {
        let chargerRule = rule(amount: 60)
        let locationRule = rule(scope: .location, target: "home", amount: 120)
        let fee = ChargingOverstayFee.resolve(session: session(), rules: [locationRule, chargerRule])
        #expect(fee?.rule.id == chargerRule.id)
    }

    @Test
    func aLocationRuleMatchesTheSessionsLocationIgnoringCaseAndWhitespace() {
        let fee = ChargingOverstayFee.resolve(
            session: session(location: "  work "),
            rules: [rule(scope: .location, target: "WORK")]
        )
        #expect(fee != nil)
    }

    @Test
    func aLocationRuleDoesNotMatchAnotherLocation() {
        #expect(ChargingOverstayFee.resolve(
            session: session(location: "Work"),
            rules: [rule(scope: .location, target: "Home")]
        ) == nil)
    }

    @Test
    func theEnergyFigureStillComesFromTheRatePolicy() {
        let stored = session(estimatedCost: 20)
        let policy = ElectricityRatePolicy.fixed
        let before = stored.resolvedCost(policy: policy, fallbackPricePerKwh: 2.0).amount
        let fee = ChargingOverstayFee.resolve(session: stored, rules: [rule()])
        let after = stored.resolvedCost(policy: policy, fallbackPricePerKwh: 2.0).amount
        #expect(fee != nil)
        #expect(before == after)
        #expect(before == 20)
    }

    @Test
    func theCostSplitDoesNotFoldTheFeeIntoItsTotal() {
        let stored = session(estimatedCost: 20)
        let split = ChargingCostSplit.resolve(
            sessions: [stored], policy: .fixed, fallbackPricePerKwh: 2.0, defaultCurrency: "kr"
        )
        #expect(split?.totalAmount == 20)
    }
}
