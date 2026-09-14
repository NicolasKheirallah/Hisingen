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
}
