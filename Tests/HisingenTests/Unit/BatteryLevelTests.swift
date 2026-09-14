import Foundation
import Testing
@testable import Hisingen

/// `VehicleState.batteryLevel` is the one threshold answer the hero gauge, the menu bar and
/// the fleet list read, so the thresholds are pinned here rather than through any renderer.
/// Each renderer's palette is deliberately not asserted: the point of the split is that a
/// palette can change without touching the rule.
struct BatteryLevelTests {

    @Test
    func aLowPackEscalatesBeforeChargingSoftensTheReading() {
        #expect(level(10, charging: false) == .critical)
        #expect(level(15, charging: false) == .critical)
        #expect(level(15, charging: true) == .critical)
        #expect(level(16, charging: false) == .low)
        #expect(level(35, charging: false) == .low)
        #expect(level(36, charging: false) == .normal)
    }

    @Test
    func chargingReadsAsProgressUntilItIsNearlyFull() {
        #expect(level(40, charging: true) == .charging)
        #expect(level(79, charging: true) == .charging)
        #expect(level(80, charging: true) == .chargingComplete)
        #expect(level(100, charging: true) == .chargingComplete)
    }

    @Test
    func aMissingReadingIsNotAnAlarm() {
        #expect(vehicle(battery: nil).batteryLevel == .normal)
    }

    private func level(_ percentage: Double, charging: Bool) -> BatteryLevel {
        vehicle(battery: percentage, state: charging ? .charging : .idle).batteryLevel
    }
}
