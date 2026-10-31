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
    func incrementalUpdateKeepsTheReadingsThisRefreshOmitted() {
        let previous = EnergyAndChargingSnapshot(batteryPercentage: 78.5, rangeKm: 420)
        let policy = SnapshotMergePolicy(
            features: FeatureSelection(enabled: AppFeature.permittedFeatures),
            refreshedFeatures: nil,
            failedFeatures: [],
            isCommandLocked: false,
            fetchedAt: Date()
        )

        // A partial reading (battery only) must not blank the fields it did not carry.
        let incrementalSnapshot = EnergyAndChargingSnapshot(batteryPercentage: 78.0)
        let merged = incrementalSnapshot.merging(previous: previous, policy: policy)

        #expect(merged.batteryPercentage == 78.0)
        #expect(merged.rangeKm == 420)
    }
}
