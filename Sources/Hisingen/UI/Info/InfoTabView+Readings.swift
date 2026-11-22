import SwiftUI

extension InfoTabView {
    /// Sub-minute ingest jitter is noise; anything a reader could act on gets named.
    static let portalIngestDelayVisibility: TimeInterval = 60

    var readingFreshnessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    CardHeader(symbol: "clock", title: L10n.text("Reading Freshness"), color: .secondary)
                    InformationButton(
                        message: L10n.text("Vehicle timestamps are separate from when Hisingen refreshed. A missing timestamp cannot confirm a current reading."),
                        subject: L10n.text("Reading Freshness")
                    )
                }
                ForEach(VehicleReading.allCases, id: \.self) { reading in
                    if let date = state.reportedDate(for: reading) {
                        KVRow(reading.title,
                              Self.freshnessValue(reportedAt: date,
                                                  receivedAt: state.freshness.metaReceivedDates?[reading],
                                                  source: state.freshness.source(for: reading)),
                              symbol: "clock",
                              valueWarning: Self.readingLags(reading, in: state))
                    }
                }
            }
        }
    }

    /// Whether one reading deserves the warning tint. Every reading of a sleeping car is hours
    /// old, so age alone painted the whole section orange. What a reader can act on is a domain
    /// lagging the car's own latest report by more than an hour, or Hisingen being unable to
    /// re-check at all.
    static func readingLags(_ reading: VehicleReading, in state: VehicleState) -> Bool {
        guard !state.hasFreshReading(reading), let reported = state.reportedDate(for: reading) else { return false }
        if state.freshness.isCached || state.isStale() { return true }
        return state.dataTimestamp.timeIntervalSince(reported) > 60 * 60
    }

    /// One freshness row's value: the vehicle's report time, plus the portal queue time
    /// when that gap is large enough to explain a stale domain next to a fresh one.
    static func freshnessValue(reportedAt: Date, receivedAt: Date?, source: VehicleReadingSource? = nil,
                               now: Date = Date()) -> String {
        // Relative age first, because "how old" is the question this section answers; the clock
        // time follows so the row still lines up with History's timestamps.
        var value = L10n.format("%@ · %@", Format.relativeAge(since: reportedAt, now: now),
                                Format.timeFormatter.string(from: reportedAt))
        if let lag = portalIngestLagMinutes(receivedAt: receivedAt, reportedAt: reportedAt) {
            value += " · " + L10n.format("portal +%d min", lag)
        }
        // Which service served the value, when the app recorded it. Two readings can be the same
        // age but reach the app by different routes, and that decides whether a stale one is
        // worth waiting for.
        if let source {
            value += " · " + source.displayName
        }
        return value
    }

    /// How long a reading sat in the portal's delivery pipeline, in whole minutes, when the
    /// ingest time is known and the gap is large enough to explain a stale domain sitting
    /// next to a fresh one from the same refresh.
    static func portalIngestLagMinutes(receivedAt: Date?, reportedAt: Date) -> Int? {
        guard let receivedAt else { return nil }
        let interval = receivedAt.timeIntervalSince(reportedAt)
        guard interval >= portalIngestDelayVisibility else { return nil }
        return max(1, Int(interval / 60))
    }
}
