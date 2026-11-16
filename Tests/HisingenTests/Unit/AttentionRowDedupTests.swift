import Foundation
import Testing
@testable import Hisingen

/// One fault, one row. The service flag and the health warnings list both report a service
/// warning, and the tyre list and the warnings list both report low pressure; the attention
/// card counted each of those twice.
@MainActor
@Suite("Needs Attention rows")
struct AttentionRowDedupTests {
    private let features = FeatureSelection(enabled: [.vehicleHealth, .tyreAndWarnings])

    private func rows(_ state: VehicleState) -> [KVRow] {
        ExceptionsCard.attentionRows(state: state, features: features, dismissedSoftwareEventIdentifier: nil)
    }

    @Test func serviceWarningReportedTwiceShowsOnce() {
        var state = vehicle(serviceWarning: true)
        state.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [.service])
        let result = rows(state)
        #expect(result.count == 1)
        #expect(result.first?.key == L10n.text("Service Inspection Warning"))
    }

    @Test func tyreWarningReportedTwiceShowsOnce() {
        var state = vehicle()
        state.maintenance.details = VehicleHealthDetails(
            tyres: [TyrePressure(position: .frontLeft, kilopascals: 180, warning: .low)],
            warnings: [.tyrePressure]
        )
        let result = rows(state)
        #expect(result.count == 1)
        #expect(result.first?.key == L10n.text("Tyre Pressure"))
    }

    @Test func warningOnlyInHealthListStillShows() {
        var state = vehicle()
        state.maintenance.details = VehicleHealthDetails(tyres: [], warnings: [.service, .washerFluid])
        let keys = rows(state).map(\.key)
        #expect(keys == [VehicleWarning.service.displayName, VehicleWarning.washerFluid.displayName])
    }
}
