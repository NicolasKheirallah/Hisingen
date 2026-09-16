import SwiftUI
import Charts

/// Compact 48-hour spot-price bar chart for the Charging Planner card. Bars inside the
/// planned charging window carry the semantic good colour; the rest shade from neutral
/// (cheap) toward warning (expensive) so the shape of the day reads at a glance without
/// axis clutter.
@MainActor
struct PriceCurveView: View {
    let points: [ElectricityPricePoint]
    let plan: ChargingPlan?
    var now: Date = Date()

    private var futurePoints: [ElectricityPricePoint] {
        points.filter { $0.endDate > now }.sorted { $0.startDate < $1.startDate }
    }

    var body: some View {
        let series = futurePoints
        guard series.count >= 2,
              let minimum = series.map(\.sekPerKwh).min(),
              let maximum = series.map(\.sekPerKwh).max(), maximum > minimum else {
            return AnyView(EmptyView())
        }
        let span = maximum - minimum
        return AnyView(
            Chart {
                ForEach(series, id: \.startDate) { point in
                    BarMark(
                        x: .value("Time", point.startDate),
                        y: .value("Price", point.sekPerKwh),
                        width: .fixed(2)
                    )
                    .foregroundStyle(barColor(for: point, minimum: minimum, span: span))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { (value: AxisValue) in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: Date.FormatStyle.dateTime.hour())
                                .hisType(.micro, weight: .medium)
                                .monospacedDigit()
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { (value: AxisValue) in
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            // The y axis carries the only measurable information on the chart, so
                            // it is no longer the smallest type on it, and it names its unit.
                            Text(L10n.format("%@ kr", String(format: "%.1f", price)))
                                .hisType(.micro, weight: .medium)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    AxisGridLine()
                }
            }
            .frame(height: 56)
            // The chart had no unit and no way to read an individual hour: the bars carried the
            // information and nothing could be asked of them.
            .chartYAxisLabel(L10n.text("kr per kWh"))
            .accessibilityLabel(L10n.text("Electricity price outlook"))
            .accessibilityValue(accessibilitySummary(minimum: minimum, maximum: maximum))
        )
    }

    /// The bands are absolute, not relative to the window on screen.
    ///
    /// The scale was `(price - minimum) / span` over the visible period, so the same 1.20 kr/kWh
    /// rendered red on a flat day and grey on a volatile one, and two cards showing different
    /// periods disagreed about the same hour. These thresholds are the Swedish spot-price bands a
    /// reader actually plans around.
    private func barColor(for point: ElectricityPricePoint, minimum: Double, span: Double) -> Color {
        if let plan, point.startDate >= plan.start && point.endDate <= plan.end {
            return HisingenTheme.semanticGood
        }
        switch point.sekPerKwh {
        case ..<1.0: return Color.secondary.opacity(0.4)
        case ..<2.0: return HisingenTheme.semanticWarning.opacity(0.45)
        default: return HisingenTheme.semanticWarning.opacity(0.8)
        }
    }

    private func accessibilitySummary(minimum: Double, maximum: Double) -> String {
        let range = plan.map { plan in
            L10n.format("Planned window from %@", Format.shortTime(date: plan.start))
        } ?? ""
        return L10n.format("Between %@ and %@ kr per kWh. %@", Format.number(minimum, decimals: 2), Format.number(maximum, decimals: 2), range)
    }
}
