import SwiftUI

// `HistoryDashboardView` – when each vehicle warning appeared and when a report stopped showing
// it. An entry is open while the warning is still active; it closes only on a report that covers
// that warning, so a report that omits the category leaves the entry as it was.
extension HistoryDashboardView {
    var warningEvents: [VehicleDatabase.WarningEventRecord] { snapshot.warningEvents }

    var warningTimelineCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "exclamationmark.triangle", title: L10n.text("Warning Timeline"), color: HisingenTheme.semanticWarning)
                PaginatedSection(items: warningEvents, pageSize: 10, resetKeys: [periodLoadKey],
                                 emptyMessage: L10n.text("No warnings were reported in this period.")) { visible, footer in
                    ForEach(visible) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.warning.displayName)
                                .hisType(.caption, weight: .semibold)
                            HStack(spacing: 6) {
                                Text(L10n.text("Since"))
                                Text(event.firstSeen, style: .date)
                                if let clearedAt = event.clearedAt {
                                    Text("·")
                                    Text(L10n.text("Cleared"))
                                    Text(clearedAt, style: .date)
                                } else {
                                    Text("·")
                                    Text(L10n.text("Still reported"))
                                }
                            }
                            .hisType(.caption).foregroundStyle(.secondary)
                        }
                    }
                    footer
                }
                Text(L10n.text("An entry starts when a warning first appears in a report and ends when a later report covering it no longer shows it. A report that leaves a warning out does not clear it."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
