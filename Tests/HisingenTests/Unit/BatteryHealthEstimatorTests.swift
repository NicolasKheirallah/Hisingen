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

    @Test("Charging power integration estimates usable capacity")
    func powerIntegrationUsesObservedEnergyAndSOCDelta() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        let samples = [
            ChargingSample(timestamp: start, batteryPercentage: 20, powerWatts: 50_000),
            ChargingSample(timestamp: start.addingTimeInterval(600), batteryPercentage: 30, powerWatts: 50_000),
            ChargingSample(timestamp: start.addingTimeInterval(1_200), batteryPercentage: 40, powerWatts: 50_000)
        ]
        let session = ChargingSession(
            id: UUID(), vin: "SOH_TEST", startDate: start,
            endDate: start.addingTimeInterval(1_200),
            startBatteryPercentage: 20, endBatteryPercentage: 40,
            kwhDelivered: 0, peakPowerWatts: 50_000, cost: nil,
            samples: samples
        )
        let capacity = try #require(BatteryHealthEstimator.chargeIntegratedCapacity(from: [session]))
        #expect(abs(capacity - 75) < 0.1)
    }
}
