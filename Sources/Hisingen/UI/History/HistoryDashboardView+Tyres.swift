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
        return HistoryCardSurface {
            VStack(alignment: .leading, spacing: 8) {
                HistorySectionHeading(symbol: "gauge.medium", title: L10n.text("Tyre Pressure"), color: HisingenTheme.chartInfo)
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
                            .lineStyle(tyreStroke(position, leaking: leak?.position == position))
                            .interpolationMethod(.linear)
                        }
                    }
                }
                .historyTimeAxis(spanning: chronological.map(\.timestamp))
                .historyYAxis(unit.suffix)
                .frame(height: chartHeight)
                .accessibilityLabel(L10n.text("Tyre pressure trend chart"))
                .accessibilityValue(chartAccessibilityValue(points: chronological.map { unit.convert(kilopascals: $0.kilopascals) }))
                .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
                    title: L10n.text("Tyre pressure trend chart"),
                    yLabel: unit.suffix,
                    series: positions.map { position in
                        .init(name: position.displayName,
                              points: chronological.filter { $0.position == position }
                                  .map { ($0.timestamp, unit.convert(kilopascals: $0.kilopascals)) })
                    }
                ))
                .hisAnimation(Motion.progress, value: periodDataKey)
                HStack(spacing: 10) {
                    ForEach(positions, id: \.self) { position in
                        legendSwatch(tyreSeriesColors[position] ?? HisingenTheme.chartInfo,
                                     position.displayName,
                                     dashed: tyreIsRear(position))
                    }
                }
                Text(L10n.text("A reading is kept when a tyre's pressure changes or once an hour. A possible slow leak is a pattern to check, not a diagnosis."))
                    .hisType(.micro).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension HistoryDashboardView {
    func tyreIsRear(_ position: TyrePosition) -> Bool {
        position == .rearLeft || position == .rearRight
    }

    /// Front tyres draw solid and rear tyres dashed, always. Two of the four theme colours are
    /// near-identical greys in Monochrome Precision, so colour alone cannot carry the identity;
    /// the pair that shares a grey differs in stroke. The tyre the leak check suspects is
    /// drawn heavier.
    func tyreStroke(_ position: TyrePosition, leaking: Bool) -> StrokeStyle {
        let width: CGFloat = leaking ? 2.6 : 1.4
        if tyreIsRear(position) { return StrokeStyle(lineWidth: width, dash: [5, 3]) }
        if differentiateWithoutColor, position == .frontRight { return StrokeStyle(lineWidth: width, dash: [2, 2]) }
        return StrokeStyle(lineWidth: width)
    }
}
