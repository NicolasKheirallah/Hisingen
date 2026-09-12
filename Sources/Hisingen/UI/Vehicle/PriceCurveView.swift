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
                                .font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { (value: AxisValue) in
                    AxisValueLabel {
                        if let price = value.as(Double.self) {
                            Text(String(format: "%.1f", price))
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                        }
                    }
                    AxisGridLine()
                }
            }
            .frame(height: 56)
            .accessibilityLabel(L10n.text("Electricity price outlook"))
            .accessibilityValue(accessibilitySummary(minimum: minimum, maximum: maximum))
        )
    }

    private func barColor(for point: ElectricityPricePoint, minimum: Double, span: Double) -> Color {
        if let plan, point.startDate >= plan.start && point.endDate <= plan.end {
            return HisingenTheme.semanticGood
        }
        let fraction = span > 0 ? (point.sekPerKwh - minimum) / span : 0
        return fraction > 0.66 ? HisingenTheme.semanticWarning.opacity(0.8)
            : fraction > 0.33 ? Color.orange.opacity(0.45)
            : Color.secondary.opacity(0.4)
    }

    private func accessibilitySummary(minimum: Double, maximum: Double) -> String {
        let range = plan.map { plan in
            L10n.format("Planned window from %@", Format.shortTime(date: plan.start))
        } ?? ""
        return L10n.format("Between %@ and %@ kr per kWh. %@", Format.number(minimum, decimals: 2), Format.number(maximum, decimals: 2), range)
    }
}
