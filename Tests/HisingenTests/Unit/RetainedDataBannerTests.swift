import Foundation
import Testing
@testable import Hisingen

/// The last-known banner must clear when fresh data arrives. It used to pin forever on domains a
/// provider structurally never serves, because those are reported unavailable on every refresh and
/// were unioned into the retained set regardless of whether anything could be shown for them.
struct RetainedDataBannerTests {

    @Test("A domain the provider never serves does not pin the last-known banner")
    func structurallyUnavailableIsNotRetained() {
        let features = FeatureSelection(enabled: [
            .vehicleWeather, .softwareUpdates, .chargingSchedule, .vehicleLocation
        ])
        let previous = vehicle(brand: .volvo)
        var incoming = vehicle(brand: .volvo)
        incoming.freshness.unavailableFeatures = [.vehicleWeather, .softwareUpdates, .chargingSchedule]

        let merged = incoming.mergingLastKnown(from: previous, features: features)

        #expect(merged.freshness.retainedDataCategories.isEmpty)
    }

    @Test("A domain that had data still earns a last-known mark when its refresh fails")
    func realFailureKeepsMark() {
        let features = FeatureSelection(enabled: [.vehicleLocation])
        let previous = vehicle(
            brand: .polestar,
            location: VehicleLocation(latitude: 57.7, longitude: 11.9)
        )
        var incoming = vehicle(brand: .polestar)
        incoming.freshness.unavailableFeatures = [.vehicleLocation]

        let merged = incoming.mergingLastKnown(from: previous, features: features)

        #expect(merged.freshness.retainedDataCategories.contains(.vehicleLocation))
    }

    @Test("A snapshot with nothing to stand in for never reports a retained value")
    func presencePredicateMatchesContent() {
        let empty = vehicle(brand: .volvo)
        #expect(empty.hasRetainedValue(for: .vehicleWeather) == false)
        #expect(empty.hasRetainedValue(for: .softwareUpdates) == false)
        #expect(empty.hasRetainedValue(for: .chargingSchedule) == false)
        #expect(empty.hasRetainedValue(for: .vehicleLocation) == false)

        let located = vehicle(brand: .polestar, location: VehicleLocation(latitude: 1, longitude: 2))
        #expect(located.hasRetainedValue(for: .vehicleLocation))
    }
}
