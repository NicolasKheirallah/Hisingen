import Charts
import SwiftUI

// `HistoryDashboardView` – tyre pressure over the selected period. Only numeric readings are
// drawn. Vehicles that report warning levels alone (indirect TPMS) store no rows here, so the
// card stays hidden for them rather than showing an empty chart.
extension HistoryDashboardView {
    var tyreRecords: [VehicleDatabase.TyrePressureRecord] { snapshot.tyrePressureRecords }

    /// The four tyres in a fixed order, with theme chart colours. Four series is the most the
    /// palette can separate, so no further hues are introduced here.
    private var tyreSeriesColors: [TyrePosition: Color] {
        [
            .frontLeft: HisingenTheme.chartInfo,
            .frontRight: HisingenTheme.chartPositive,
            .rearLeft: HisingenTheme.chartAttention,
            .rearRight: HisingenTheme.chartHealth
        ]
    }

    var tyrePressureCard: some View {
        let unit = preferences.pressureUnit
        let chronological = tyreRecords.sorted { $0.timestamp < $1.timestamp }
        let leak = TyrePressureTrend.slowLeak(in: tyreRecords)
        let positions = TyrePosition.allCases.filter { position in
            chronological.contains { $0.position == position }
        }
        return Card {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "gauge.medium", title: L10n.text("Tyre Pressure"), color: HisingenTheme.chartInfo)
                if let leak {
                    Text(L10n.format("Possible slow leak: %@", leak.position.displayName))
                        .hisType(.caption, weight: .semibold)
                        .foregroundStyle(HisingenTheme.semanticWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Chart {
                    ForEach(positions, id: \.self) { position in
                        ForEach(chronological.filter { $0.position == position }, id: \.id) { record in
                            LineMark(
                                x: .value(L10n.text("Date"), record.timestamp),
                                y: .value(L10n.text("Tyre Pressure"), unit.convert(kilopascals: record.kilopascals)),
                                series: .value(L10n.text("Tyre"), position.displayName)
                            )
                            .foregroundStyle(tyreSeriesColors[position] ?? HisingenTheme.chartInfo)
                            .lineStyle(chartSeriesStroke(
                                index: TyrePosition.allCases.firstIndex(of: position) ?? 0,
                                differentiateWithoutColor: differentiateWithoutColor,
                                width: 1.4
                            ))
                            .interpolationMethod(.catmullRom)
                        }
                    }
                }
                .chartYAxisLabel(unit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Tyre pressure trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: chronological.map { unit.convert(kilopascals: $0.kilopascals) }))
                .hisAnimation(Motion.progress, value: periodDataKey)
                HStack(spacing: 10) {
                    ForEach(Array(positions.enumerated()), id: \.element) { index, position in
                        legendSwatch(tyreSeriesColors[position] ?? HisingenTheme.chartInfo,
                                     position.displayName,
                                     dashed: chartSeriesIsDashed(index: TyrePosition.allCases.firstIndex(of: position) ?? 0,
                                                                 differentiateWithoutColor: differentiateWithoutColor))
                    }
                }
                Text(L10n.text("A reading is kept when a tyre's pressure changes or once an hour. A possible slow leak is a pattern to check, not a diagnosis."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
