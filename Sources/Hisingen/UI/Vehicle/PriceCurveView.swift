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
                            Text(date, format: Date.FormatStyle.dateTime.hour().locale(L10n.displayLocale))
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
                            Text(L10n.format("%@ kr", String(format: "%.1f", locale: L10n.displayLocale, price)))
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

    /// Hue stays absolute: the Swedish spot-price bands are what a reader plans around, so
    /// the same hour must read the same whichever period is on screen (a purely relative
    /// scale once rendered 1.20 kr/kWh red on a flat day and grey on a volatile one).
    /// Intensity comes from the visible window's `minimum`/`span` instead, so a window stuck
    /// inside one band, a cheap summer night or an extreme-price day, still shows its shape
    /// instead of rendering every bar identical.
    private func barColor(for point: ElectricityPricePoint, minimum: Double, span: Double) -> Color {
        if let plan, point.startDate >= plan.start && point.endDate <= plan.end {
            return HisingenTheme.semanticGood
        }
        let alpha = Self.barAlpha(price: point.sekPerKwh, minimum: minimum, span: span)
        return point.sekPerKwh < 1.0
            ? Color.secondary.opacity(alpha)
            : HisingenTheme.semanticWarning.opacity(alpha)
    }

    /// Alpha for a price bar: absolute bands pick the formula, the window position
    /// (`(price - minimum) / span`, clamped) picks the intensity within it. Each band's
    /// floor sits at its old flat alpha and ends at or above where the next begins, so
    /// crossing a threshold upward never reads as a cheaper bar. Exposed for tests that pin
    /// the ordering rules.
    nonisolated static func barAlpha(price: Double, minimum: Double, span: Double) -> Double {
        let position = span > 0 ? min(max((price - minimum) / span, 0), 1) : 0
        switch price {
        case ..<1.0: return 0.4 + 0.25 * position
        case ..<2.0: return 0.45 + 0.2 * position
        default: return 0.7 + 0.1 * position
        }
    }

    private func accessibilitySummary(minimum: Double, maximum: Double) -> String {
        let range = plan.map { plan in
            L10n.format("Planned window from %@", Format.shortTime(date: plan.start))
        } ?? ""
        return L10n.format("Between %@ and %@ kr per kWh. %@", Format.number(minimum, decimals: 2), Format.number(maximum, decimals: 2), range)
    }
}
