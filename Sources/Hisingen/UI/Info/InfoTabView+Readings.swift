import SwiftUI

extension InfoTabView {
    /// Sub-minute ingest jitter is noise; anything a reader could act on gets named.
    static let portalIngestDelayVisibility: TimeInterval = 60

    var readingFreshnessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock", title: L10n.text("Reading Freshness"), color: .secondary)
                Text(L10n.text("Vehicle timestamps are separate from when Hisingen refreshed. A missing timestamp cannot confirm a current reading."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(VehicleReading.allCases, id: \.self) { reading in
                    if let date = state.reportedDate(for: reading) {
                        KVRow(reading.title,
                              Self.freshnessValue(reportedAt: date,
                                                  receivedAt: state.freshness.metaReceivedDates?[reading]),
                              symbol: "clock",
                              valueWarning: !state.hasFreshReading(reading))
                    }
                }
                if VehicleReading.allCases.allSatisfy({ state.reportedDate(for: $0) == nil }) {
                    Text(L10n.text("No vehicle timestamps reported.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// One freshness row's value: the vehicle's report time, plus the portal queue time
    /// when that gap is large enough to explain a stale domain next to a fresh one.
    static func freshnessValue(reportedAt: Date, receivedAt: Date?) -> String {
        var value = Format.dateTimeFormatter.string(from: reportedAt)
        if let lag = portalIngestLagMinutes(receivedAt: receivedAt, reportedAt: reportedAt) {
            value += " · " + L10n.format("portal +%d min", lag)
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
