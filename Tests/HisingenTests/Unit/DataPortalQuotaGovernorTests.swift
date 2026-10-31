import Foundation
import Testing
@testable import Hisingen

struct DataPortalQuotaGovernorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let dayLength: TimeInterval = 86_400

    @Test
    func testNoPressureLeavesIntervalUnchanged() {
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: 600, used: 100, secondsUntilReset: 40_000, now: now)

        #expect(pacing.interval == 600)
        #expect(!pacing.isStretched)
        #expect(pacing.projection.used == 100)
        #expect(pacing.projection.projectedEndOfDay == 100 + 66 * 14)
    }

    @Test
    func testChargingCadenceOverBudgetIsStretched() {
        // 720 refreshes of 14 reads would spend 10 080 calls, past the 9 000 safety budget.
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: 120, used: 0, secondsUntilReset: dayLength, now: now)

        #expect(pacing.isStretched)
        #expect(pacing.interval > 120)
        #expect(abs(pacing.interval - dayLength / 642) < 0.001)
        #expect(pacing.projection.projectedEndOfDay <= 9_000)
        #expect(pacing.projection.projectedEndOfDay > 8_900)
    }

    @Test
    func testNearResetStretchesOnlyALittle() {
        // 20 minutes left, 100 calls of headroom: seven refreshes fit, not ten.
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: 120, used: 8_900, secondsUntilReset: 1_200, now: now)

        #expect(pacing.isStretched)
        #expect(pacing.interval > 120)
        #expect(pacing.interval < 200)
        #expect(pacing.projection.projectedEndOfDay <= 9_000)
    }

    @Test
    func testExhaustedBudgetWaitsUntilReset() {
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: 120, used: 9_500, secondsUntilReset: 3_600, now: now)

        #expect(pacing.interval == 3_600)
        #expect(pacing.projection.projectedEndOfDay == 9_500)
        #expect(pacing.projection.resetDate == now.addingTimeInterval(3_600))
    }

    @Test
    func testExhaustedJustBeforeResetDoesNotSpin() {
        let pacing = DataPortalQuotaGovernor.pace(
            requestedInterval: 120, used: 9_500, secondsUntilReset: 5, now: now)

        #expect(pacing.interval == DataPortalQuotaGovernor.minimumExhaustedWait)
    }

    @Test
    func testSecondsUntilResetCountsToUTCMidnight() {
        // 1_800_000_000 is 08:00:00 UTC, so 16 hours remain in the quota day.
        #expect(DataPortalQuotaGovernor.secondsUntilReset(now: now) == 57_600)
    }
}
