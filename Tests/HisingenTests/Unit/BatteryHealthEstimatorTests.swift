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
        #expect(estimate.rawStateOfHealthPercent == 50)
        #expect(estimate.method == BatteryHealthEstimator.fullChargeRangeMethod)
        #expect(estimate.methodologySummary.contains("not a battery-management-system measurement"))
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
        #expect(estimate.rawStateOfHealthPercent == 133.3)
        #expect(estimate.degradationPercent == 0)
    }

    @Test("A plug-in hybrid never produces a range SoH value")
    func phevIsRejected() {
        let state = vehicle(battery: 100, modelName: "V60 Recharge", modelYear: "2021", powertrain: .phev)
        #expect(BatteryHealthEstimator.estimate(
            state: state,
            specification: specification
        ) == nil)
    }

    @Test("An unknown model never produces SoH without a VIN override")
    func unknownModelNeedsOverride() {
        let state = vehicle(battery: 100, modelName: "Unknown Prototype")
        #expect(BatteryHealthEstimator.estimate(state: state) == nil)
        #expect(BatteryHealthEstimator.estimate(state: state, specification: specification) != nil)
    }

    @Test("A wide high-confidence session yields a session SoH value")
    func sessionEnergyDefinesStateOfHealth() throws {
        let session = HistoricalChargingSession(
            id: "s1", vin: "YSMTEST", startedAt: Date(), endedAt: Date(),
            startSoc: 20, endSoc: 80, energyDeliveredKwh: 40,
            peakPowerKw: 11, averagePowerKw: 10, locationName: nil, createdAt: Date(),
            lifecycleState: .completed, energySource: .observedPowerIntegration,
            confidence: .high
        )
        let estimate = try #require(BatteryHealthEstimator.estimateFromChargingSession(
            session: session, referenceCapacityKwh: 75
        ))
        #expect(estimate.method == BatteryHealthEstimator.sessionEnergyMethod)
        #expect(estimate.stateOfHealthPercent == 79.1)
        #expect(estimate.fullChargeRangeKm == nil)
    }

    @Test("Narrow, weak, or legacy sessions never produce SoH")
    func weakSessionsAreRejected() {
        func session(startSoc: Double, endSoc: Double?, energy: Double,
                     source: ChargingSessionEnergySource = .observedPowerIntegration,
                     confidence: ChargingSessionConfidence = .high) -> HistoricalChargingSession {
            HistoricalChargingSession(
                id: UUID().uuidString, vin: "YSMTEST", startedAt: Date(), endedAt: Date(),
                startSoc: startSoc, endSoc: endSoc, energyDeliveredKwh: energy,
                peakPowerKw: 11, averagePowerKw: 10, locationName: nil, createdAt: Date(),
                lifecycleState: .completed, energySource: source, confidence: confidence
            )
        }
        #expect(BatteryHealthEstimator.estimateFromChargingSession(
            session: session(startSoc: 70, endSoc: 90, energy: 13), referenceCapacityKwh: 75) == nil)
        #expect(BatteryHealthEstimator.estimateFromChargingSession(
            session: session(startSoc: 20, endSoc: 80, energy: 40, confidence: .low),
            referenceCapacityKwh: 75) == nil)
        #expect(BatteryHealthEstimator.estimateFromChargingSession(
            session: session(startSoc: 20, endSoc: 80, energy: 40, source: .socCapacityEstimate),
            referenceCapacityKwh: 75) == nil)
        #expect(BatteryHealthEstimator.estimateFromChargingSession(
            session: session(startSoc: 20, endSoc: 80, energy: 200),
            referenceCapacityKwh: 75) == nil)
    }

    @Test("Fusion agrees when methods agree and refuses when they conflict")
    func fusedSoHRequiresAgreement() {
        #expect(BatteryHealthEstimator.fusedSoH(rangeSoH: 92, sessionSoH: 93) == 92.5)
        #expect(BatteryHealthEstimator.fusedSoH(rangeSoH: 92, sessionSoH: 70) == nil)
        #expect(BatteryHealthEstimator.fusedSoH(rangeSoH: nil, sessionSoH: 90) == 90)
        #expect(BatteryHealthEstimator.fusedSoH(rangeSoH: nil, sessionSoH: nil) == nil)
    }

    @Test("The stable SoH is the median of recent milestones")
    func stableMedianIgnoresOutliers() throws {
        func record(id: Int64, soh: Double, day: Double) -> BatteryHealthRecord {
            BatteryHealthRecord(id: id, vin: "YSMTEST",
                                timestamp: Date(timeIntervalSince1970: day * 86_400),
                                odometerKm: 50_000 + day * 100,
                                stateOfHealthPct: soh, degradationPct: 100 - soh,
                                effectiveUsableKwh: 75 * soh / 100,
                                measurementSource: BatteryHealthRecord.fullChargeRangeSource)
        }
        let records = [record(id: 1, soh: 92, day: 1), record(id: 2, soh: 60, day: 2), record(id: 3, soh: 91, day: 3)]
        #expect(BatteryHealthEstimator.stableMedianSoH(from: records) == 91)
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
