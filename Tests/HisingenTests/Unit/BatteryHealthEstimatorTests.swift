import Foundation
import Testing
@testable import Hisingen

struct BatteryHealthEstimatorTests {
    private let specification = VehicleSpecificationOverride(
        usableBatteryCapacityKwh: 78,
        wltpRangeKm: 400
    )

    @Test("SoH is calculated from full-charge range divided by WLTP range")
    func fullChargeRangeDefinesStateOfHealth() throws {
        let state = vehicle(battery: 100)
        let estimate = try #require(BatteryHealthEstimator.estimate(
            state: state,
            specification: specification
        ))

        #expect(estimate.stateOfHealthPercent == 50)
        #expect(estimate.degradationPercent == 50)
        #expect(estimate.estimatedUsableCapacityKwh == 39)
        #expect(estimate.fullChargeRangeKm == 200)
        #expect(estimate.wltpReferenceRangeKm == 400)
        #expect(!estimate.isRemembered)
        #expect(estimate.methodologySummary.contains("only at 100% charge"))
    }

    @Test("A partial charge never produces a new SoH value")
    func partialChargeIsRejected() {
        #expect(BatteryHealthEstimator.estimate(
            state: vehicle(battery: 99.4),
            specification: specification
        ) == nil)
        #expect(BatteryHealthEstimator.estimate(
            state: vehicle(battery: 50),
            specification: specification
        ) == nil)
    }

    @Test("Only an actual 100 percent reading qualifies")
    func onlyActualFullChargeQualifies() {
        #expect(BatteryHealthEstimator.estimate(
            state: vehicle(battery: 99.9),
            specification: specification
        ) == nil)
        #expect(BatteryHealthEstimator.estimate(
            state: vehicle(battery: BatteryHealthEstimator.fullChargeThreshold),
            specification: specification
        ) != nil)
    }

    @Test("The model WLTP reference is used without a VIN override")
    func modelReferenceIsTheFallback() throws {
        let state = vehicle(battery: 100)
        let estimate = try #require(BatteryHealthEstimator.estimate(state: state))
        let expected = min(100, (200 / state.model.nominalWltpRangeKm * 1000).rounded() / 10)

        #expect(estimate.stateOfHealthPercent == expected)
        #expect(estimate.wltpReferenceRangeKm == state.model.nominalWltpRangeKm)
    }

    @Test("A favorable range estimate cannot raise SoH above 100 percent")
    func stateOfHealthIsCappedAtOneHundred() throws {
        let estimate = try #require(BatteryHealthEstimator.estimate(
            state: vehicle(battery: 100),
            specification: VehicleSpecificationOverride(
                usableBatteryCapacityKwh: 78,
                wltpRangeKm: 150
            )
        ))

        #expect(estimate.stateOfHealthPercent == 100)
        #expect(estimate.degradationPercent == 0)
    }

    @Test("A remembered full-charge result can be displayed without recalculation")
    func rememberedValuePreservesStoredResult() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let estimate = BatteryHealthEstimator.remembered(
            stateOfHealthPercent: 92,
            degradationPercent: 8,
            estimatedUsableCapacityKwh: 71.76,
            recordedAt: date,
            fallbackReferenceCapacityKwh: 75
        )

        #expect(estimate.stateOfHealthPercent == 92)
        #expect(estimate.referenceUsableCapacityKwh == 78)
        #expect(estimate.recordedAt == date)
        #expect(estimate.fullChargeRangeKm == nil)
        #expect(estimate.wltpReferenceRangeKm == nil)
        #expect(estimate.isRemembered)
    }
}
