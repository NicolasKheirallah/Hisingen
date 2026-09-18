import Foundation
import Testing

@testable import Hisingen

/// The unavailable-features bookkeeping shared by both provider telemetry paths: only
/// requested features that their reading failed to produce are listed, first report wins,
/// and one failed reading can mark every feature it serves.
struct SnapshotAssemblyTests {
    @Test
    func marksOnlyFailedReadings() {
        var unavailable = SnapshotAssembly.UnavailableFeatures()
        unavailable.mark(.tripMeters, when: true)
        unavailable.mark(.climateStatus, when: false)
        #expect(unavailable.features == [.tripMeters])
    }

    @Test
    func keepsFirstReportAndDropsRepeats() {
        var unavailable = SnapshotAssembly.UnavailableFeatures()
        unavailable.mark(.remoteSchedules, when: true)
        unavailable.mark(.remoteSchedules, when: true)
        unavailable.mark(.remoteSchedules, when: false)
        #expect(unavailable.features == [.remoteSchedules])
    }

    @Test
    func oneFailedReadingMarksEveryFeatureItServes() {
        var unavailable = SnapshotAssembly.UnavailableFeatures()
        unavailable.mark([.exteriorStatus, .remoteLocks, .remoteWindows], when: true)
        #expect(unavailable.features == [.exteriorStatus, .remoteLocks, .remoteWindows])
    }

    @Test
    func failedBatchMarksNothingWhenReadingSucceeded() {
        var unavailable = SnapshotAssembly.UnavailableFeatures()
        unavailable.mark([.exteriorStatus, .remoteLocks], when: false)
        #expect(unavailable.features.isEmpty)
    }

    @Test
    func departureFromChargeLocationClearsLocationNameAndArrivalDate() {
        let arrival = Date(timeIntervalSince1970: 1700000000)
        let previous = EnergyAndChargingSnapshot(
            isAtChargeLocation: true,
            currentChargeLocationName: "Home Garage",
            arrivedAtLocationDate: arrival
        )
        let policy = SnapshotMergePolicy(
            features: FeatureSelection(enabled: AppFeature.permittedFeatures),
            refreshedFeatures: nil,
            failedFeatures: [],
            isCommandLocked: false,
            fetchedAt: Date()
        )

        // When the vehicle departs, isAtChargeLocation is false
        let departureSnapshot = EnergyAndChargingSnapshot(isAtChargeLocation: false)
        let merged = departureSnapshot.merging(previous: previous, policy: policy)

        #expect(merged.isAtChargeLocation == false)
        #expect(merged.currentChargeLocationName == nil)
        #expect(merged.arrivedAtLocationDate == nil)
    }

    @Test
    func incrementalUpdatePreservesChargeLocationWhenStillAtLocation() {
        let arrival = Date(timeIntervalSince1970: 1700000000)
        let previous = EnergyAndChargingSnapshot(
            isAtChargeLocation: true,
            currentChargeLocationName: "Work Depot",
            arrivedAtLocationDate: arrival
        )
        let policy = SnapshotMergePolicy(
            features: FeatureSelection(enabled: AppFeature.permittedFeatures),
            refreshedFeatures: nil,
            failedFeatures: [],
            isCommandLocked: false,
            fetchedAt: Date()
        )

        // Incremental battery update where isAtChargeLocation wasn't returned (nil)
        let incrementalSnapshot = EnergyAndChargingSnapshot(
            batteryPercentage: 78.0,
            isAtChargeLocation: nil,
            currentChargeLocationName: nil,
            arrivedAtLocationDate: nil
        )
        let merged = incrementalSnapshot.merging(previous: previous, policy: policy)

        #expect(merged.batteryPercentage == 78.0)
        #expect(merged.isAtChargeLocation == true)
        #expect(merged.currentChargeLocationName == "Work Depot")
        #expect(merged.arrivedAtLocationDate == arrival)
    }
}
