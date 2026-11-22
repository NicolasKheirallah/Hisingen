import Foundation
import Testing
@testable import Hisingen

/// The one charger write beyond charge/pause. Its range and its refusals are the whole contract:
/// the app must never send an amperage the charger would reject, and must never claim success
/// without an entity to send to. The unpaired case is covered by the model's own inert-by-design
/// behaviour; these tests pin the range and the entity map that the write depends on.
@MainActor
struct ChargerCurrentLimitTests {
    @Test
    func theRangeIsClampedInBothDirections() {
        #expect(HomeChargingModel.clampedCurrentLimit(0) == 6)
        #expect(HomeChargingModel.clampedCurrentLimit(6) == 6)
        #expect(HomeChargingModel.clampedCurrentLimit(16) == 16)
        #expect(HomeChargingModel.clampedCurrentLimit(32) == 32)
        #expect(HomeChargingModel.clampedCurrentLimit(80) == 32)
        #expect(HomeChargingModel.clampedCurrentLimit(-5) == 6)
    }

    @Test
    func theWritableEntityIsCarriedInTheMap() {
        let map = HomeChargerEntityMap(currentLimit: "sensor.limit", currentLimitNumber: "number.limit")
        #expect(map.allEntityIDs.contains("number.limit"))
        // Reading and writing stay separate entities.
        #expect(map.currentLimit == "sensor.limit")
        #expect(map.currentLimitNumber == "number.limit")
    }
}
