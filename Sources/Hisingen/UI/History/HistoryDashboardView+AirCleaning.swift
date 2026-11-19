import SwiftUI

extension HistoryDashboardView {
    var airCleaningCyclesCard: some View {
        let cycles = HistoryInsights.airCleaningCycles(from: snapshot.activities, vin: state.identity.vin)
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HistorySectionHeading(symbol: "wind", title: L10n.text("Observed Air-Cleaning Runs"), color: HisingenTheme.chartPositive)
                PaginatedSection(items: cycles, pageSize: preferences.historyPageSize(for: .historyAirCleaning),
                                 resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No air-cleaning cycles were recorded in this period.")) { visible, footer in
                    ForEach(visible) { cycle in
                        HStack {
                            Text(cycle.startedAt, style: .date)
                            Text(Format.shortTime(date: cycle.startedAt))
                            Spacer()
                            Text(Format.shortDuration(minutes: cycle.observedMinutes))
                        }.hisType(.caption)
                    }
                    footer
                }
                Text(L10n.text("Intervals between observed running and stopped states, not exact cycle duration or proof of successful cleaning. Runs crossing the selected period or a two-hour gap are excluded."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
