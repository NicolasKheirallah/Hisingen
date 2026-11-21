import Foundation
import Testing
@testable import Hisingen

/// Volvo refreshes each resource on its own schedule, so one successful refresh can carry today's
/// doors and a day-old odometer. `hasOldData()` judges the whole snapshot by its newest timestamp,
/// which cannot see that; these pin the per-domain statement that can.
@Suite("Stale readings")
struct StaleReadingTests {
    private let now = Date(timeIntervalSince1970: 1_795_260_000)

    @Test("A domain reported long ago is named while the snapshot itself looks fresh")
    func staleDomainIsNamedOnAFreshSnapshot() {
        var state = vehicle(fetchedAt: now, reportedAt: now.addingTimeInterval(-60))
        state.freshness.readingDates = [
            .battery: now.addingTimeInterval(-300),
            .odometer: now.addingTimeInterval(-90_000),
            .location: now.addingTimeInterval(-100_000)
        ]

        // Oldest first, so the banner can quote the worst one.
        #expect(state.staleReadings(at: now) == [.location, .odometer])
        // The snapshot's own timestamp is a minute old, which is why the banner has to come from
        // the per-reading dates rather than from `hasOldData()`.
        #expect(!state.hasOldData(at: now))
    }

    @Test("A reading with no report time is not treated as stale")
    func missingReportTimeIsUnknownNotStale() {
        let state = vehicle(fetchedAt: now, reportedAt: now)
        #expect(state.staleReadings(at: now).isEmpty)
        #expect(StaleReadingNoticeID(state: state) == nil)
    }

    @Test("The notice names the stale domains and the oldest of them")
    func noticeCarriesDomainsAndOldestReading() {
        var state = vehicle(fetchedAt: now, reportedAt: now)
        state.freshness.readingDates = [
            .odometer: now.addingTimeInterval(-90_000),
            .health: now.addingTimeInterval(-95_000)
        ]

        let notice = StaleReadingNoticeID(state: state)
        #expect(notice?.readings == ["health", "odometer"])
        #expect(notice?.oldest == now.addingTimeInterval(-95_000))
        // The titles the banner prints come from the readings it names.
        #expect(notice?.readings.compactMap { VehicleReading(rawValue: $0)?.title }.count == 2)
    }

    @Test("A reading at the threshold edge is not stale")
    func thresholdIsExclusive() {
        var state = vehicle(fetchedAt: now, reportedAt: now)
        state.freshness.readingDates = [.odometer: now.addingTimeInterval(-12 * 60 * 60)]
        #expect(state.staleReadings(at: now).isEmpty)
        state.freshness.readingDates = [.odometer: now.addingTimeInterval(-12 * 60 * 60 - 1)]
        #expect(state.staleReadings(at: now) == [.odometer])
    }
}
