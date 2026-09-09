import SwiftUI

extension HistoryDashboardView {
    var airCleaningCyclesCard: some View {
        let cycles = HistoryInsights.airCleaningCycles(from: snapshot.activities, vin: state.vin)
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "wind", title: L10n.text("Observed Air-Cleaning Runs"), color: .mint)
                if cycles.isEmpty {
                    Text(L10n.text("No paired running and stopped readings in this period."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(cycles.prefix(10))) { cycle in
                    HStack {
                        Text(cycle.startedAt, style: .date)
                        Text(cycle.startedAt, style: .time)
                        Spacer()
                        Text(Format.shortDuration(minutes: cycle.observedMinutes))
                    }.font(.caption)
                }
                Text(L10n.text("Intervals between observed running and stopped states, not exact cycle duration or proof of successful cleaning. Runs crossing the selected period or a two-hour gap are excluded. Showing up to 10 runs."))
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
