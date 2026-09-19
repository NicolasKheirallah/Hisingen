import Foundation
import Testing
@testable import Hisingen

/// The identity merge consumes stored images as `VehicleImageBackfill` data contributed by
/// the caller, never through a persistence type, so image carry-across-merge is a pure
/// value-in/value-out assertion here.
@Suite("VehicleImageBackfill")
struct VehicleImageBackfillTests {

    private func state(vin: String, exterior: Data?, interior: Data?) -> VehicleState {
        var state = vehicle(vin: vin)
        state.identity.imageData = exterior
        state.identity.interiorImageData = interior
        return state
    }

    @Test func backfillFillsMissingExteriorWhenVehicleImageIsRefreshed() {
        let previous = state(vin: "YV1BACKFILL01", exterior: Data("old".utf8), interior: nil)
        var fresh = vehicle(vin: "YV1BACKFILL01")
        fresh.identity.imageData = nil
        fresh.identity.interiorImageData = Data("interior".utf8)

        let merged = fresh.mergingLastKnown(
            from: previous,
            features: FeatureSelection(enabled: [.vehicleImage]),
            refreshedFeatures: [.vehicleImage],
            imageBackfill: VehicleImageBackfill(exterior: Data("stored".utf8), interior: nil)
        )

        #expect(merged.identity.imageData == Data("old".utf8))
        #expect(merged.identity.interiorImageData == Data("interior".utf8))
    }

    @Test func backfillIsUsedOnlyWhenThePreviousSnapshotHasNoImage() {
        let previous = state(vin: "YV1BACKFILL02", exterior: Data("previous".utf8), interior: nil)
        var fresh = vehicle(vin: "YV1BACKFILL02")
        fresh.identity.imageData = nil

        let merged = fresh.mergingLastKnown(
            from: previous,
            features: FeatureSelection(enabled: [.vehicleImage]),
            refreshedFeatures: [.vehicleImage],
            imageBackfill: VehicleImageBackfill(exterior: Data("stored".utf8), interior: nil)
        )

        #expect(merged.identity.imageData == Data("previous".utf8))
    }

    @Test func backfillIsIgnoredWhenVehicleImageIsNotPartOfTheRefresh() {
        let previous = state(vin: "YV1BACKFILL03", exterior: Data("previous".utf8), interior: nil)
        var fresh = vehicle(vin: "YV1BACKFILL03")
        fresh.identity.imageData = nil

        let merged = fresh.mergingLastKnown(
            from: previous,
            features: FeatureSelection(enabled: [.vehicleImage]),
            refreshedFeatures: [.vehicleHealth],
            imageBackfill: VehicleImageBackfill(exterior: Data("stored".utf8), interior: nil)
        )

        #expect(merged.identity.imageData == Data("previous".utf8))
    }

    @Test func emptyBackfillLeavesNoImageRatherThanFabricatingOne() {
        var fresh = vehicle(vin: "YV1BACKFILL04")
        fresh.identity.imageData = nil

        let merged = fresh.mergingLastKnown(
            from: nil,
            features: FeatureSelection(enabled: [.vehicleImage]),
            refreshedFeatures: [.vehicleImage],
            imageBackfill: .empty
        )

        #expect(merged.identity.imageData == nil)
    }
}
