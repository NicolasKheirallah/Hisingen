import Charts
import SwiftUI

/// The arithmetic and wording behind the solar chart, kept apart from the view so it can be tested.
enum SolarForecastChart {
    /// Value-axis range and gridlines in W/m². The bars start at zero so their heights compare
    /// honestly. The top is the strongest hour with a little headroom, but never below 100 W/m²,
    /// so a dull winter day reads as dull and not as a full-height chart of noise.
    nonisolated static func axis(peak: Double) -> (domain: ClosedRange<Double>, ticks: [Double]) {
        let top = max(peak * 1.08, 100)
        let step = [50.0, 100, 200, 250, 500, 1_000].first { top / $0 <= 4 } ?? 1_000
        let ticks = stride(from: 0.0, through: top, by: step).map { $0 }
        return (0...top, ticks)
    }

    /// "11:00–12:00" on the place's clock. When that clock differs from this Mac's, the zone is
    /// named, so a forecast for a place in another zone does not read as local time.
    @MainActor
    static func hourRange(_ point: SolarForecastPoint, zone: TimeZone, deviceZone: TimeZone = .current) -> String {
        let range = "\(Format.shortTime(date: point.start, timeZone: zone))–\(Format.shortTime(date: point.end, timeZone: zone))"
        guard zone.secondsFromGMT(for: point.start) != deviceZone.secondsFromGMT(for: point.start),
              let name = zone.abbreviation(for: point.start) else { return range }
        return "\(range) \(name)"
    }
}

/// A saved charge location the forecast can be drawn for.
struct SolarForecastPlaceChoice: Identifiable, Equatable {
    let id: String
    let alias: String
}

/// The solar forecast beside the charging plan: hourly radiation bars for the rest of today and
/// tomorrow on the same clock as the price chart, with the charging window and now marked on it.
/// Radiation is the honest unit here. The app knows no panel array, so it never presents this as
/// expected kWh.
@MainActor
struct SolarForecastLine: View {
    let forecast: SolarForecast
    let place: SolarForecastPlace
    var plan: ChargingPlan?
    /// The reader's own panels. With them each hour also reads an estimated output, a figure that
    /// comes from their typed size, so it is labelled as an estimate wherever it appears.
    var array: SolarArray?
    /// Where the chart ends: the end of tomorrow, the last day the price chart ever shows.
    var outlookEnd: Date?
    var places: [SolarForecastPlaceChoice] = []
    var onSelectPlace: (String?) -> Void = { _ in }
    var now: Date = Date()

    @State private var scrubDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    private var horizon: TimeInterval {
        outlookEnd.map { max(3_600, $0.timeIntervalSince(now)) } ?? SolarForecast.horizon
    }

    private var points: [SolarForecastPoint] { forecast.upcoming(after: now, horizon: horizon) }

    private var peak: SolarForecastPoint? {
        points.max { $0.wattsPerSquareMeter < $1.wattsPerSquareMeter }
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.timeZone = forecast.timeZone
        return calendar
    }

    var body: some View {
        if let peak, let first = points.first, let last = points.last {
            let selected = scrubDate.flatMap {
                HistoryInsights.nearest(to: $0, in: points, timestamp: \.midpoint)
            }
            let axis = SolarForecastChart.axis(peak: peak.wattsPerSquareMeter)
            let summary = L10n.format("Peak %@ · %@", wattsText(peak.wattsPerSquareMeter), rangeText(peak))
            VStack(alignment: .leading, spacing: 6) {
                header
                // The summary and the readout share one line, so the chart does not move when a
                // bar is picked and the readout never clips against the card above the plot.
                Group {
                    if let selected {
                        let text = readout(for: selected)
                        Text(text)
                            .hisTelemetryValue(text, reduceMotion: reduceMotion)
                            .historyScrubCallout()
                    } else {
                        Text(summary)
                            .hisType(.caption)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .monospacedDigit()
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)

                chart(first: first, last: last, selected: selected, axis: axis, summary: summary)
                legend
                dayFigures
                Text(footnote)
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label(L10n.text("Solar forecast"), systemImage: "sun.max")
                .hisType(.label, weight: .medium)
                .foregroundStyle(HisingenTheme.inkMuted)
            Spacer()
            if !places.isEmpty { placeMenu }
        }
    }

    private var placeName: String {
        switch place {
        case .vehicle: return L10n.text("Car's location")
        case .saved(_, let alias, _, _): return alias
        }
    }

    private var selectedPlaceID: String? {
        if case .saved(let id, _, _, _) = place { return id }
        return nil
    }

    private var placeMenu: some View {
        Menu {
            Picker(L10n.text("Solar forecast place"), selection: Binding(
                get: { selectedPlaceID },
                set: { onSelectPlace($0) }
            )) {
                Text(L10n.text("Car's location")).tag(String?.none)
                ForEach(places) { choice in
                    Text(choice.alias).tag(Optional(choice.id))
                }
            }
            .pickerStyle(.inline)
        } label: {
            Text(placeName)
                .hisType(.micro, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(L10n.text("Solar forecast place"))
        .accessibilityValue(placeName)
    }

    private func chart(first: SolarForecastPoint, last: SolarForecastPoint, selected: SolarForecastPoint?,
                       axis: (domain: ClosedRange<Double>, ticks: [Double]), summary: String) -> some View {
        let domainStart = first.start
        let domainEnd = last.end
        let hourCount = Int((domainEnd.timeIntervalSince(domainStart) / 3_600).rounded())
        let ticks = PriceOutlook.timeTicks(from: domainStart, to: domainEnd, hourCount: hourCount, calendar: calendar)
        let inset = min(5 * 60, SolarForecastPoint.interval / 6)
        return Chart {
            if let plan {
                RectangleMark(
                    xStart: .value("Window start", max(plan.start, domainStart)),
                    xEnd: .value("Window end", min(plan.end, domainEnd)),
                    yStart: .value("Floor", axis.domain.lowerBound),
                    yEnd: .value("Ceiling", axis.domain.upperBound)
                )
                .foregroundStyle(HisingenTheme.liveSignal.opacity(0.14))
            }
            ForEach(points) { point in
                RectangleMark(
                    xStart: .value("Hour start", point.start.addingTimeInterval(inset)),
                    xEnd: .value("Hour end", point.end.addingTimeInterval(-inset)),
                    yStart: .value("Zero", 0),
                    yEnd: .value(L10n.text("Solar forecast"), point.wattsPerSquareMeter)
                )
                .foregroundStyle(barColor(for: point, selected: selected))
            }
            if now > domainStart && now < domainEnd {
                RuleMark(x: .value("Now", now))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(HisingenTheme.ink)
            }
        }
        .chartXScale(domain: domainStart...domainEnd)
        .chartYScale(domain: axis.domain)
        .chartXSelection(value: $scrubDate)
        .chartXAxis {
            AxisMarks(values: ticks) { value in
                if let date = value.as(Date.self), calendar.component(.hour, from: date) == 0 {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(HisingenTheme.hairline)
                }
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        Text(timeLabel(for: date))
                            .hisType(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                    .foregroundStyle(HisingenTheme.hairline)
                AxisValueLabel(anchor: .trailing) {
                    if let watts = value.as(Double.self) {
                        Text(Format.number(watts, decimals: 0))
                            .hisType(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
            }
        }
        .frame(height: 96)
        .accessibilityLabel(L10n.text("Solar forecast chart"))
        .accessibilityValue(summary)
        // The pass that gave every chart a rotor descriptor ran before this line existed,
        // and the guardrail in AccessibilityPassTests is what caught it.
        .accessibilityChartDescriptor(TimeSeriesAXDescriptor(
            title: L10n.text("Solar forecast chart"),
            yLabel: L10n.text("Watts per square metre"),
            points: points.map { ($0.start, Double($0.wattsPerSquareMeter)) },
            valueFormat: { String(format: "%.0f", locale: L10n.displayLocale, $0) }
        ))
    }

    /// The price chart's colours: one grey, the planned hours in the live colour, the picked bar in ink.
    private func barColor(for point: SolarForecastPoint, selected: SolarForecastPoint?) -> Color {
        if point == selected { return HisingenTheme.ink }
        return inPlannedWindow(point) ? HisingenTheme.liveSignal : HisingenTheme.inkMuted
    }

    private func inPlannedWindow(_ point: SolarForecastPoint) -> Bool {
        guard let plan else { return false }
        return point.start < plan.end && point.end > plan.start
    }

    private var legend: some View {
        HStack(spacing: 14) {
            if plan != nil {
                legendItem(HisingenTheme.liveSignal, title: L10n.text("Charging Window"), width: 10, height: 8)
            }
            legendItem(HisingenTheme.ink, title: L10n.text("Now"), width: 1, height: 12)
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ color: Color, title: String, width: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: width, height: height)
            Text(title)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    /// The day's total radiation, today and tomorrow, and with panels typed in the output they
    /// would estimate. Each is left out when the forecast has gaps in that day, rather than shown
    /// as a smaller number.
    @ViewBuilder
    private var dayFigures: some View {
        let totals = forecast.dayTotals(at: now)
        let estimates = array.map { forecast.dayEstimates(at: now, array: $0) }
        if totals.today != nil || totals.tomorrow != nil {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 28))
            layout {
                if let today = totals.today {
                    dayFigure(today, estimate: estimates?.today, label: L10n.text("Today"))
                }
                if let tomorrow = totals.tomorrow {
                    dayFigure(tomorrow, estimate: estimates?.tomorrow, label: L10n.text("Tomorrow"))
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func dayFigure(_ kwh: Double, estimate: Double?, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format("%@ kWh/m²", Format.number(kwh, decimals: 1)))
                .hisType(size: 17, relativeTo: .title3)
                .foregroundStyle(HisingenTheme.ink)
                .monospacedDigit()
            if let estimate {
                Text(L10n.format("≈ %@ kWh from your panels", Format.number(estimate, decimals: 0)))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.ink)
                    .monospacedDigit()
            }
            Text(label)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
    }

    private var footnote: String {
        let base: String
        switch place {
        case .vehicle:
            base = L10n.text("Open-Meteo radiation at the car's location; it is not panel output.")
        case .saved(_, let alias, _, _):
            base = L10n.format("Open-Meteo radiation at %@; it is not panel output.", alias)
        }
        guard array != nil else { return base }
        return base + " " + L10n.text("Estimated output uses your panel settings and assumes 80% system efficiency.")
    }

    /// The hour and its radiation, with the estimated output when the reader has typed in panels.
    private func readout(for point: SolarForecastPoint) -> String {
        let base = L10n.format("%@ · %@", rangeText(point), wattsText(point.wattsPerSquareMeter))
        guard let kw = estimatedKw(point) else { return base }
        return L10n.format("%@ · %@", base, L10n.format("≈ %@ kW", Format.number(kw, decimals: 1)))
    }

    private func estimatedKw(_ point: SolarForecastPoint) -> Double? {
        guard let array, let tilted = point.tiltedWattsPerSquareMeter else { return nil }
        return array.estimatedKw(tiltedWattsPerSquareMeter: tilted)
    }

    private func wattsText(_ watts: Double) -> String {
        L10n.format("%@ W/m²", Format.number(watts, decimals: 0))
    }

    private func rangeText(_ point: SolarForecastPoint) -> String {
        SolarForecastChart.hourRange(point, zone: forecast.timeZone)
    }

    /// Hour labels use the reader's clock style on the place's clock; the label at midnight names
    /// the weekday that starts there, which is what marks the change of day.
    private func timeLabel(for date: Date) -> String {
        if calendar.component(.hour, from: date) == 0 {
            return date.formatted(Date.FormatStyle(timeZone: forecast.timeZone)
                .weekday(.abbreviated).locale(L10n.displayLocale))
        }
        return Format.localizedDateFormatter(timeZone: forecast.timeZone, hourOnly: true).string(from: date)
    }
}

/// The line in place of the chart when the forecast cannot be drawn, so a missing chart says why.
@MainActor
struct SolarForecastStatusLine: View {
    let outcome: SolarForecastOutcome

    private var message: String? {
        switch outcome {
        case .forecast: return nil
        case .needsVehicleWeather: return L10n.text("Turn on Vehicle Weather to see the solar forecast")
        case .needsLocation: return L10n.text("The solar forecast needs the car's location")
        case .unavailable: return L10n.text("The solar forecast is unavailable right now")
        }
    }

    var body: some View {
        if let message {
            Text(message)
                .hisType(.micro)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
