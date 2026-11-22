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
    func theEntitysOwnRangeNarrowsTheOuterBound() {
        let attributes: [String: HAJSONValue] = ["min": .number(6), "max": .number(16)]
        let range = HomeChargingModel.currentLimitRange(fromEntityAttributes: attributes)
        #expect(range == 6...16)
        #expect(HomeChargingModel.clampedCurrentLimit(32, within: range) == 16)
        #expect(HomeChargingModel.clampedCurrentLimit(10, within: range) == 10)
    }

    @Test
    func anEntityRangeNeverWidensTheOuterBound() {
        let wide: [String: HAJSONValue] = ["min": .number(0), "max": .number(63)]
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: wide) == 6...32)
        let narrowLow: [String: HAJSONValue] = ["min": .number(10.2), "max": .number(24.9)]
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: narrowLow) == 11...24)
    }

    @Test
    func aMissingOrContradictoryEntityRangeFallsBackToTheOuterBound() {
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: [:]) == 6...32)
        let reversed: [String: HAJSONValue] = ["min": .number(40), "max": .number(50)]
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: reversed) == 6...32)
        let huge: [String: HAJSONValue] = ["min": .number(1e300), "max": .number(.infinity)]
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: huge) == 6...32)
        let text: [String: HAJSONValue] = ["min": .string("low"), "max": .string("high")]
        #expect(HomeChargingModel.currentLimitRange(fromEntityAttributes: text) == 6...32)
    }

    @Test
    func theRangeComesFromTheEntityTheModelAlreadyPolled() {
        let table = ["number.limit": HAEntityState(
            entityID: "number.limit", state: "10", attributes: ["min": .number(6), "max": .number(16)])]

        #expect(HomeChargingModel.currentLimitRange(in: table, entity: "number.limit") == 6...16)
    }

    @Test
    func anEntityThePollHasNotReadYetGetsTheOuterBound() {
        let table = ["number.other": HAEntityState(entityID: "number.other", state: "10")]

        #expect(HomeChargingModel.currentLimitRange(in: table, entity: "number.limit") == 6...32)
        #expect(HomeChargingModel.currentLimitRange(in: table, entity: nil) == 6...32)
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
