import Foundation
import Testing
@testable import Hisingen

/// The two reference-capacity rules are separate on purpose: money figures use the configured
/// reference and never the provider's report, while health and the capacity display prefer the
/// report. Both are asserted through one interface, and the display label comes back with the
/// number rather than being re-derived.
struct CapacityReferenceTests {

    @Test
    func theConfiguredReferenceNeverUsesTheProviderReport() {
        let state = polestar2(reported: 71)
        #expect(state.factoryUsableBatteryCapacityKwh > 0)
        #expect(state.configuredCapacityReference(specification: nil)
            == .modelReference(state.factoryUsableBatteryCapacityKwh))
    }

    @Test
    func aUserEnteredCapacityWinsInBothRules() {
        let state = polestar2(reported: 71)
        let entered = VehicleSpecificationOverride(usableBatteryCapacityKwh: 77, wltpRangeKm: nil)
        #expect(state.configuredCapacityReference(specification: entered).kwh == 77)
        #expect(state.measuredCapacityReference(specification: entered) == .userEntered(77))
    }

    @Test
    func theMeasuredReferencePrefersTheProviderReportOverTheModelTable() {
        #expect(polestar2(reported: 71).measuredCapacityReference(specification: nil) == .providerReported(71))
    }

    @Test
    func anUnusableReportFallsThroughToTheModelTable() {
        let state = polestar2(reported: 0)
        #expect(state.measuredCapacityReference(specification: nil)
            == .modelReference(state.factoryUsableBatteryCapacityKwh))
    }

    @Test
    func anUnknownModelWithNoReportHasNoMeasuredReference() {
        #expect(vehicle(battery: 50, modelName: "Not A Known Model").measuredCapacityReference(specification: nil) == nil)
    }

    private func polestar2(reported: Double?) -> VehicleState {
        vehicle(battery: 50, modelName: "Polestar 2", reportedBatteryCapacityKwh: reported)
    }
}
