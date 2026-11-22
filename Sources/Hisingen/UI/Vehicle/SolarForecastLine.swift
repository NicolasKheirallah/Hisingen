import Charts
import SwiftUI

/// The solar forecast beside the charging plan: one line of Open-Meteo radiation for the next
/// day, with its peak time. Radiation is the honest unit here — the app knows no panel array,
/// so it never presents this as expected kWh.
@MainActor
struct SolarForecastLine: View {
    let forecast: SolarForecast
    var now: Date = Date()

    private var points: [SolarForecastPoint] { forecast.upcoming(after: now) }
    private var peak: SolarForecastPoint? { forecast.peak(after: now) }

    var body: some View {
        if let peak, !points.isEmpty {
            let summary = L10n.format(
                "Peak %@ at %@",
                L10n.format("%@ W/m²", Format.number(peak.wattsPerSquareMeter, decimals: 0)),
                Format.shortTime(date: peak.time)
            )
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(L10n.text("Solar forecast"), systemImage: "sun.max")
                        .hisType(.label, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                    Spacer()
                    Text(summary)
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .monospacedDigit()
                }
                Chart(points) { point in
                    AreaMark(
                        x: .value(L10n.text("Time"), point.time),
                        y: .value(L10n.text("Solar forecast"), point.wattsPerSquareMeter)
                    )
                    .foregroundStyle(HisingenTheme.semanticWarning.opacity(0.16))
                    .interpolationMethod(.monotone)
                    LineMark(
                        x: .value(L10n.text("Time"), point.time),
                        y: .value(L10n.text("Solar forecast"), point.wattsPerSquareMeter)
                    )
                    .foregroundStyle(HisingenTheme.semanticWarning)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                    .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 38)
                .accessibilityLabel(L10n.text("Solar forecast chart"))
                .accessibilityValue(summary)
                Text(L10n.text("Open-Meteo radiation at the car's location; it is not panel output."))
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
