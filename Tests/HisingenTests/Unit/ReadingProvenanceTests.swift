import Foundation
import Testing
@testable import Hisingen

/// Which service served a reading is the difference between "wait, the car will report again"
/// and "this route will never be fresher". The app only says it when it recorded it.
struct ReadingProvenanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func freshness(dates: [VehicleReading: Date]) -> SnapshotFreshness {
        SnapshotFreshness(fetchedAt: now, readingDates: dates)
    }

    @Test
    func stampingRecordsTheProducerForEveryReadingCarried() {
        let stamped = freshness(dates: [.battery: now, .range: now]).recordedSource(.volvo)
        #expect(stamped.source(for: .battery) == .volvo)
        #expect(stamped.source(for: .range) == .volvo)
        // A reading the refresh did not carry stays unknown rather than inheriting a guess.
        #expect(stamped.source(for: .odometer) == nil)
    }

    @Test
    func aMoreSpecificObservationSurvivesStamping() {
        var base = freshness(dates: [.battery: now, .range: now])
        base.readingObservations = [.battery: VehicleReadingObservation(fetchedAt: now, source: .liveStream)]
        let stamped = base.recordedSource(.polestarPortal)
        #expect(stamped.source(for: .battery) == .liveStream)
        #expect(stamped.source(for: .range) == .polestarPortal)
    }

    @Test
    func anUnstampedSnapshotReportsNothing() {
        let plain = freshness(dates: [.battery: now])
        #expect(plain.source(for: .battery) == nil)
    }

    @Test
    @MainActor
    func theFreshnessRowNamesTheServiceWhenKnown() {
        let withSource = InfoTabView.freshnessValue(reportedAt: now, receivedAt: nil, now: now, source: .liveStream)
        #expect(withSource.contains(VehicleReadingSource.liveStream.readoutWord))
        let withoutSource = InfoTabView.freshnessValue(reportedAt: now, receivedAt: nil, now: now, source: nil)
        #expect(!withoutSource.contains(VehicleReadingSource.liveStream.readoutWord))
        #expect(!withoutSource.hasSuffix(" · "))
    }
}
