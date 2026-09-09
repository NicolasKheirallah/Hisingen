import SwiftUI

extension InfoTabView {
    var readingFreshnessCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "clock", title: L10n.text("Reading Freshness"), color: .secondary)
                Text(L10n.text("Vehicle timestamps are separate from when Hisingen refreshed. A missing timestamp cannot confirm a current reading."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(VehicleReading.allCases, id: \.self) { reading in
                    if let date = state.reportedDate(for: reading) {
                        KVRow(reading.title, Format.dateTimeFormatter.string(from: date), symbol: "clock",
                              valueWarning: !state.hasFreshReading(reading))
                    }
                }
                if VehicleReading.allCases.allSatisfy({ state.reportedDate(for: $0) == nil }) {
                    Text(L10n.text("No vehicle timestamps reported.")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
