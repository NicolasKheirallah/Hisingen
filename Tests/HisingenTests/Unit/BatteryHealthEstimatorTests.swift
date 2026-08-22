import Foundation
import Testing
@testable import Hisingen

struct BatteryHealthEstimatorTests {
    @Test("SoH is explicitly calculated from available signals")
    func calculatedEstimateDisclosesMethod() throws {
        let state = vehicle(battery: 50)
        let estimate = try #require(BatteryHealthEstimator.estimate(
            state: state,
            chargingSessions: [],
            specification: VehicleSpecificationOverride(
                usableBatteryCapacityKwh: 78,
                wltpRangeKm: 500
            )
        ))
        #expect(estimate.stateOfHealthPercent >= 55)
        #expect(estimate.stateOfHealthPercent <= 100)
        #expect(estimate.signals.contains { $0.id == "range" })
        #expect(estimate.methodologySummary.contains("not a battery-management-system measurement"))
    }

    /// Builds a synthetic 20%→40% session with constant power, sized so `chargeIntegratedCapacity`
    /// (with a 0.90 loss factor) lands on `targetCapacityKwh`: capacity = (power_kW / 3) × 4.5.
    private func chargingSession(vin: String = "SOH_TEST", targetCapacityKwh: Double, chargingType: ChargingType = .unknown) -> ChargingSession {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let powerWatts = Int((targetCapacityKwh / 1.5) * 1_000)
        let samples = [
            ChargingSample(timestamp: start, batteryPercentage: 20, powerWatts: powerWatts, chargingType: chargingType),
            ChargingSample(timestamp: start.addingTimeInterval(600), batteryPercentage: 30, powerWatts: powerWatts, chargingType: chargingType),
            ChargingSample(timestamp: start.addingTimeInterval(1_200), batteryPercentage: 40, powerWatts: powerWatts, chargingType: chargingType)
        ]
        return ChargingSession(
            id: UUID(), vin: vin, startDate: start, endDate: start.addingTimeInterval(1_200),
            startBatteryPercentage: 20, endBatteryPercentage: 40,
            kwhDelivered: 0, peakPowerWatts: powerWatts, cost: nil, samples: samples
        )
    }

    @Test("Charging power integration estimates usable capacity")
    func powerIntegrationUsesObservedEnergyAndSOCDelta() throws {
        let session = chargingSession(targetCapacityKwh: 75)
        let result = try #require(BatteryHealthEstimator.chargeIntegratedCapacity(from: [session]))
        #expect(abs(result.capacityKwh - 75) < 0.1)
        #expect(result.sessionCount == 1)
    }

    @Test("DC sessions assume lower charging loss than AC, for identical raw energy")
    func chargingTypeAffectsLossFactor() throws {
        let acCapacity = try #require(BatteryHealthEstimator.chargeIntegratedCapacity(from: [chargingSession(targetCapacityKwh: 75, chargingType: .ac)]))
        let dcCapacity = try #require(BatteryHealthEstimator.chargeIntegratedCapacity(from: [chargingSession(targetCapacityKwh: 75, chargingType: .dc)]))
        let unknownCapacity = try #require(BatteryHealthEstimator.chargeIntegratedCapacity(from: [chargingSession(targetCapacityKwh: 75, chargingType: .unknown)]))
        // Same raw input energy in every case (targetCapacityKwh assumes the 0.90 blended
        // factor); AC's larger onboard-charger loss should read as *less* usable capacity than
        // DC's smaller one, with the unverified/unknown case sitting at today's blended default.
        #expect(acCapacity.capacityKwh < unknownCapacity.capacityKwh)
        #expect(dcCapacity.capacityKwh > unknownCapacity.capacityKwh)
        #expect(abs(unknownCapacity.capacityKwh - 75) < 0.1)
    }

    @Test("A single qualifying session carries less weight than five that agree")
    func sessionCountAndAgreementScaleConfidence() throws {
        let state = vehicle(battery: 50)
        let single = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: [chargingSession(targetCapacityKwh: 75)],
            specification: VehicleSpecificationOverride(usableBatteryCapacityKwh: 78, wltpRangeKm: nil)
        ))
        let singleWeight = try #require(single.signals.first { $0.id == "charge-power" }?.weight)
        #expect(abs(singleWeight - 0.22) < 0.01)

        let fiveConsistent = (0..<5).map { chargingSession(vin: "V\($0)", targetCapacityKwh: 75) }
        let consistent = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: fiveConsistent,
            specification: VehicleSpecificationOverride(usableBatteryCapacityKwh: 78, wltpRangeKm: nil)
        ))
        let consistentWeight = try #require(consistent.signals.first { $0.id == "charge-power" }?.weight)
        #expect(abs(consistentWeight - 0.55) < 0.01)

        let fiveScattered = zip((0..<5), [60.0, 70.0, 75.0, 80.0, 100.0]).map {
            chargingSession(vin: "S\($0.0)", targetCapacityKwh: $0.1)
        }
        let scattered = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: fiveScattered,
            specification: VehicleSpecificationOverride(usableBatteryCapacityKwh: 78, wltpRangeKm: nil)
        ))
        let scatteredWeight = try #require(scattered.signals.first { $0.id == "charge-power" }?.weight)
        #expect(scatteredWeight < consistentWeight)
        #expect(scatteredWeight > singleWeight)
    }

    @Test("Volvo's exact reported pack capacity is preferred over the generic model table")
    func reportedCapacityTakesPriorityOverFactoryTable() throws {
        var state = vehicle(battery: 50)
        state.reportedBatteryCapacityKwh = 70
        let estimate = try #require(BatteryHealthEstimator.estimate(state: state, chargingSessions: []))
        // Polestar 2's generic table value is 75 kWh usable; the VIN-specific reported value
        // should win when no manual Settings override exists.
        #expect(estimate.referenceUsableCapacityKwh == 70)
    }

    @Test("An implausible consumption reading is treated as skipped, not trusted")
    func implausibleConsumptionIsRejected() throws {
        var plausible = vehicle(battery: 50)
        plausible.batteryDiagnostics = BatteryDiagnostics(
            timeToTargetMinutes: nil, timeToMinimumSOCMinutes: nil, chargerPowerState: .unknown,
            averageConsumption: 18, averageConsumptionSinceCharge: nil, energyUsedSinceChargeWh: nil
        )
        let plausibleEstimate = try #require(BatteryHealthEstimator.estimate(state: plausible, chargingSessions: []))
        #expect(plausibleEstimate.signals.contains { $0.id == "consumption" })

        var implausible = vehicle(battery: 50)
        implausible.batteryDiagnostics = BatteryDiagnostics(
            timeToTargetMinutes: nil, timeToMinimumSOCMinutes: nil, chargerPowerState: .unknown,
            averageConsumption: 1_800, averageConsumptionSinceCharge: nil, energyUsedSinceChargeWh: nil
        )
        let implausibleEstimate = try #require(BatteryHealthEstimator.estimate(state: implausible, chargingSessions: []))
        #expect(!implausibleEstimate.signals.contains { $0.id == "consumption" })
    }

    @Test("A recent prior estimate is smoothed toward; a stale one is ignored")
    func temporalSmoothingRespectsRecencyOfPriorEstimate() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let state = vehicle(battery: 50)
        let specification = VehicleSpecificationOverride(usableBatteryCapacityKwh: 78, wltpRangeKm: 500)

        let baseline = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: [], specification: specification, now: fixedNow
        ))

        let recentPrior = BatteryHealthPriorEstimate(stateOfHealthPercent: 100, timestamp: fixedNow.addingTimeInterval(-2 * 24 * 60 * 60))
        let smoothed = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: [], specification: specification,
            previous: recentPrior, now: fixedNow
        ))
        #expect(smoothed.stateOfHealthPercent != baseline.stateOfHealthPercent)
        // Blending toward a prior of 100 should only ever pull the result up, never past it.
        #expect(smoothed.stateOfHealthPercent > baseline.stateOfHealthPercent)
        #expect(smoothed.stateOfHealthPercent < 100)

        let stalePrior = BatteryHealthPriorEstimate(stateOfHealthPercent: 100, timestamp: fixedNow.addingTimeInterval(-30 * 24 * 60 * 60))
        let unsmoothed = try #require(BatteryHealthEstimator.estimate(
            state: state, chargingSessions: [], specification: specification,
            previous: stalePrior, now: fixedNow
        ))
        #expect(unsmoothed.stateOfHealthPercent == baseline.stateOfHealthPercent)
    }
}
