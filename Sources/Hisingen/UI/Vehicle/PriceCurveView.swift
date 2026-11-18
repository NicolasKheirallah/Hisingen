import SwiftUI
import Charts

/// One hour of the spot-price outlook. Quarter-hour slots are averaged into the hour they sit in,
/// weighted by how long each lasted, so 48 hours read as 48 bars whatever granularity the source
/// published.
struct PriceHour: Identifiable, Equatable, Sendable {
    var start: Date
    var end: Date
    var price: Double

    var id: Date { start }
}

/// The arithmetic behind the price chart, kept apart from the view so it can be tested.
enum PriceOutlook {
    private static let hour: TimeInterval = 3_600

    /// Hourly averages for every hour that has not ended yet. Hour boundaries follow the epoch,
    /// which lines up with local hours in every zone whose offset is a whole number of hours.
    nonisolated static func hourly(_ points: [ElectricityPricePoint], after now: Date) -> [PriceHour] {
        var buckets: [TimeInterval: (weighted: Double, seconds: Double)] = [:]
        for point in points where point.endDate > now && point.endDate > point.startDate && point.sekPerKwh.isFinite {
            var cursor = point.startDate.timeIntervalSince1970
            let end = point.endDate.timeIntervalSince1970
            while cursor < end {
                let bucket = (cursor / hour).rounded(.down) * hour
                let sliceEnd = min(end, bucket + hour)
                let overlap = sliceEnd - cursor
                var running = buckets[bucket] ?? (0, 0)
                running.weighted += overlap * point.sekPerKwh
                running.seconds += overlap
                buckets[bucket] = running
                cursor = sliceEnd
            }
        }
        return buckets.keys.sorted().compactMap { key in
            guard let total = buckets[key], total.seconds > 0 else { return nil }
            let start = Date(timeIntervalSince1970: key)
            let end = start.addingTimeInterval(hour)
            return end > now ? PriceHour(start: start, end: end, price: total.weighted / total.seconds) : nil
        }
    }

    /// Value-axis range and gridlines. The bars always start at zero so their heights compare
    /// honestly, a negative spot price extends below it, and the gridline step is the smallest
    /// round number that keeps the count at four or fewer.
    nonisolated static func priceAxis(minimum: Double, maximum: Double) -> (domain: ClosedRange<Double>, ticks: [Double], step: Double) {
        let lower = min(0, minimum)
        let upper = max(maximum, 0)
        let range = upper - lower
        guard range > 0 else { return (0...1, [0, 0.5, 1], 0.5) }
        let step = [0.05, 0.1, 0.2, 0.25, 0.5, 1, 2, 2.5, 5, 10, 20, 50]
            .first { range / $0 <= 4 } ?? 100
        let domain = (lower < 0 ? lower * 1.06 : 0)...(upper * 1.06)
        var ticks: [Double] = []
        var value = (domain.lowerBound / step).rounded(.up) * step
        while value <= domain.upperBound + step * 1e-9 {
            ticks.append((value / step).rounded() * step)
            value += step
        }
        return (domain, ticks, step)
    }

    /// Decimals that show every gridline value exactly: none for whole kronor, one for tenths.
    nonisolated static func decimals(forStep step: Double) -> Int {
        if step >= 1 { return 0 }
        return abs(step * 10 - (step * 10).rounded()) < 1e-9 ? 1 : 2
    }

    /// Time-axis ticks on whole local hours, spaced so the labels never touch: every six hours
    /// across a full outlook, every three or two as it shortens. A tick closer than half a
    /// stride to either end is left out, because its label would be clipped by the chart edge.
    nonisolated static func timeTicks(from start: Date, to end: Date, hourCount: Int, calendar: Calendar = .current) -> [Date] {
        let stride = hourCount > 26 ? 6 : (hourCount > 12 ? 3 : 2)
        let margin = Double(stride) / 2 * hour
        var ticks: [Date] = []
        var cursor = start
        while cursor <= end {
            let parts = calendar.dateComponents([.hour, .minute], from: cursor)
            if parts.minute == 0, let clock = parts.hour, clock % stride == 0,
               cursor.timeIntervalSince(start) >= margin, end.timeIntervalSince(cursor) >= margin {
                ticks.append(cursor)
            }
            cursor = cursor.addingTimeInterval(hour)
        }
        return ticks
    }
}

/// The spot-price outlook for the Charging Planner. Height is the only encoding of price, and
/// the gridlines carry real kronor values, so a bar can be read off the axis. The planned hours
/// take the live colour on a faint band of the same colour; everything else is one grey.
@MainActor
struct PriceCurveView: View {
    let points: [ElectricityPricePoint]
    let plan: ChargingPlan?
    /// The instant the series should reach by now (end of tomorrow once tomorrow's prices are due).
    /// Where the series stops short of it, the chart keeps the room and says the prices are missing,
    /// so a short outlook reads as "not published yet" and not as a plan with no later hours.
    var expectedEnd: Date?
    var now: Date = Date()
    @State private var scrubDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A gap between neighbouring bars, split across both sides of each.
    private static let barInset: TimeInterval = 5 * 60

    var body: some View {
        let hours = PriceOutlook.hourly(points, after: now)
        if let first = hours.first, let last = hours.last,
           let low = hours.map(\.price).min(), let high = hours.map(\.price).max() {
            chart(hours: hours, domainStart: first.start, dataEnd: last.end,
                  domainEnd: max(last.end, expectedEnd ?? last.end), low: low, high: high)
        }
    }

    private func chart(hours: [PriceHour], domainStart: Date, dataEnd: Date, domainEnd: Date, low: Double, high: Double) -> some View {
        let axis = PriceOutlook.priceAxis(minimum: low, maximum: high)
        let hourCount = Int((domainEnd.timeIntervalSince(domainStart) / 3_600).rounded())
        let ticks = PriceOutlook.timeTicks(from: domainStart, to: domainEnd, hourCount: hourCount)
        let missing = domainEnd.timeIntervalSince(dataEnd) >= 3_600
        let selected = scrubDate.flatMap { HistoryInsights.nearest(to: $0, in: hours, timestamp: \.start) }
        let calendar = Calendar.current
        return VStack(alignment: .leading, spacing: 6) {
            // The caption and the readout share one line, so the chart does not move when a bar
            // is picked and the readout never clips against the card above the plot.
            Group {
                if let selected {
                    let text = readout(for: selected)
                    Text(text)
                        .hisTelemetryValue(text, reduceMotion: reduceMotion)
                        .historyScrubCallout()
                } else {
                    Text(L10n.format("%@ · %@", L10n.text("Hourly price"), L10n.text("kr per kWh")))
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)

            Chart {
                if let plan {
                    RectangleMark(
                        xStart: .value("Window start", max(plan.start, domainStart)),
                        xEnd: .value("Window end", min(plan.end, domainEnd)),
                        yStart: .value("Floor", axis.domain.lowerBound),
                        yEnd: .value("Ceiling", axis.domain.upperBound)
                    )
                    .foregroundStyle(HisingenTheme.liveSignal.opacity(0.14))
                }
                if missing {
                    RectangleMark(
                        xStart: .value("Missing from", dataEnd),
                        xEnd: .value("Missing to", domainEnd),
                        yStart: .value("Floor", axis.domain.lowerBound),
                        yEnd: .value("Ceiling", axis.domain.upperBound)
                    )
                    .foregroundStyle(HisingenTheme.inkMuted.opacity(0.08))
                    .annotation(position: .overlay, alignment: .center) {
                        Text(L10n.text("Not published yet"))
                            .hisType(.caption)
                            .foregroundStyle(HisingenTheme.inkMuted)
                    }
                }
                ForEach(hours) { hour in
                    RectangleMark(
                        xStart: .value("Hour start", hour.start.addingTimeInterval(Self.barInset)),
                        xEnd: .value("Hour end", hour.end.addingTimeInterval(-Self.barInset)),
                        yStart: .value("Zero", 0),
                        yEnd: .value("Price", hour.price)
                    )
                    .foregroundStyle(barColor(for: hour, selected: selected))
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
                            Text(timeLabel(for: date, calendar: calendar))
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
                        if let price = value.as(Double.self) {
                            Text(Format.number(price, decimals: PriceOutlook.decimals(forStep: axis.step)))
                                .hisType(.caption)
                                .monospacedDigit()
                                .foregroundStyle(HisingenTheme.inkMuted)
                        }
                    }
                }
            }
            .frame(height: 112)
            .accessibilityLabel(L10n.text("Electricity price outlook"))
            .accessibilityValue(accessibilitySummary(minimum: low, maximum: high)
                + (missing ? " " + L10n.text("Later prices are not published yet.") : ""))

            legend
        }
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

    private func inWindow(_ hour: PriceHour) -> Bool {
        guard let plan else { return false }
        return hour.start < plan.end && hour.end > plan.start
    }

    private func barColor(for hour: PriceHour, selected: PriceHour?) -> Color {
        if hour == selected { return HisingenTheme.ink }
        return inWindow(hour) ? HisingenTheme.liveSignal : HisingenTheme.inkMuted
    }

    /// Hour labels use the reader's clock style; the label at midnight names the weekday that
    /// starts there, which is what marks the change of day.
    private func timeLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.component(.hour, from: date) == 0 {
            return date.formatted(Date.FormatStyle().weekday(.abbreviated).locale(L10n.displayLocale))
        }
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: date)
    }

    /// The hour and price of one bar, in the unit the caption already names. Says so when the
    /// bar falls inside the planned window, the same test that colours it.
    private func readout(for hour: PriceHour) -> String {
        let time = Format.shortTime(date: hour.start)
        let price = Format.number(hour.price, decimals: 2)
        guard inWindow(hour) else {
            return L10n.format("%@ · %@ kr per kWh", time, price)
        }
        return L10n.format("%@ · %@ kr per kWh · planned charging", time, price)
    }

    private func accessibilitySummary(minimum: Double, maximum: Double) -> String {
        let range = plan.map { plan in
            L10n.format("Planned window from %@", Format.shortTime(date: plan.start))
        } ?? ""
        return L10n.format("Between %@ and %@ kr per kWh. %@", Format.number(minimum, decimals: 2), Format.number(maximum, decimals: 2), range)
    }
}
