import AppKit
import Charts
import SwiftUI

// MARK: - VoiceOver: expose a line chart's numbers instead of an opaque "chart"

/// Wraps a `(Date, Double)` series so the VoiceOver chart rotor can read individual values.
/// Attach with `.accessibilityChartDescriptor(TimeSeriesAXDescriptor(...))`.
/// Spoken summary of a numeric series, for the charts that carry a label but no descriptor.
///
/// This lived as an instance method on `InfoTabView`, so the History charts could not reach it and
/// announced a title with no data: a VoiceOver user heard "Energy consumption trend chart" and
/// nothing else, which is the element's entire purpose. A free function puts it where every chart
/// can use it.
func chartAccessibilityValue(points: [Double]) -> String {
    guard let first = points.first, let last = points.last, !points.isEmpty else {
        return L10n.text("No samples")
    }
    let lo = Int((points.min() ?? first).rounded())
    let hi = Int((points.max() ?? first).rounded())
    let latest = Int(last.rounded())
    let trendKey = last > first ? "rising" : (last < first ? "falling" : "steady")
    return L10n.format("%d samples, latest %d, range %d to %d, %@",
                       points.count, latest, lo, hi, L10n.text(trendKey))
}

/// Stroke for one series of a multi-series chart.
///
/// The two series that share axes in History (voltage with current, PM2.5 with PM10) were told
/// apart by hue alone, and `accessibilityDifferentiateWithoutColor` appeared nowhere in the app.
/// Hue is exactly what a colour-blind reader cannot use, in exactly the chart that exists to be
/// read, so the second series also carries a dash pattern whenever the system setting is on. The
/// default path is unchanged, down to the stroke width.
@MainActor
func chartSeriesStroke(index: Int, differentiateWithoutColor: Bool, width: CGFloat) -> StrokeStyle {
    guard differentiateWithoutColor, index > 0 else { return StrokeStyle(lineWidth: width) }
    return StrokeStyle(lineWidth: width, dash: index.isMultiple(of: 2) ? [5, 3] : [2, 2])
}

/// Whether series `index` of a multi-series chart is drawn dashed, so a legend can say the same
/// thing the chart does instead of contradicting it.
@MainActor
func chartSeriesIsDashed(index: Int, differentiateWithoutColor: Bool) -> Bool {
    differentiateWithoutColor && index > 0
}

struct TimeSeriesAXDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let points: [(date: Date, value: Double)]
    }

    let title: String
    let yLabel: String
    let series: [Series]
    var valueFormat: @Sendable (Double) -> String

    init(title: String,
         yLabel: String,
         points: [(date: Date, value: Double)],
         valueFormat: @escaping @Sendable (Double) -> String = {
             String(format: "%.1f", locale: L10n.displayLocale, $0)
         }) {
        self.title = title
        self.yLabel = yLabel
        self.series = [Series(name: title, points: points)]
        self.valueFormat = valueFormat
    }

    /// The same rotor for a chart that draws more than one line over the same time axis.
    init(title: String,
         yLabel: String,
         series: [Series],
         valueFormat: @escaping @Sendable (Double) -> String = {
             String(format: "%.1f", locale: L10n.displayLocale, $0)
         }) {
        self.title = title
        self.yLabel = yLabel
        self.series = series
        self.valueFormat = valueFormat
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = series.flatMap { $0.points.map { $0.date.timeIntervalSince1970 } }
        let values = series.flatMap { $0.points.map(\.value) }
        let xLow = dates.min() ?? 0
        let xHigh = max(dates.max() ?? xLow + 1, xLow + 1)
        let yLow = values.min() ?? 0
        let yHigh = max(values.max() ?? yLow + 1, yLow + 1)

        let xAxis = AXNumericDataAxisDescriptor(
            title: L10n.text("Time"),
            range: xLow...xHigh,
            gridlinePositions: []
        ) { Format.dateTimeFormatter.string(from: Date(timeIntervalSince1970: $0)) }

        let yAxis = AXNumericDataAxisDescriptor(
            title: yLabel,
            range: yLow...yHigh,
            gridlinePositions: []
        ) { [valueFormat] in valueFormat($0) }

        let descriptors = series.map { series in
            AXDataSeriesDescriptor(
                name: series.name,
                isContinuous: true,
                dataPoints: series.points.map {
                    AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value)
                }
            )
        }

        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: descriptors)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}

/// A chart whose X axis is a number rather than a date: minutes into a charging session,
/// ambient temperature, or an hour of the day.
///
/// These charts carried a spoken summary but no rotor data, so a VoiceOver reader could hear
/// "consumption vs temperature" and never the points it plots.
struct NumericSeriesAXDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let points: [(x: Double, y: Double)]
    }

    let title: String
    let xLabel: String
    let yLabel: String
    let series: [Series]
    var xFormat: @Sendable (Double) -> String
    var yFormat: @Sendable (Double) -> String

    init(title: String,
         xLabel: String,
         yLabel: String,
         series: [Series],
         xFormat: @escaping @Sendable (Double) -> String = {
             String(format: "%.0f", locale: L10n.displayLocale, $0)
         },
         yFormat: @escaping @Sendable (Double) -> String = {
             String(format: "%.1f", locale: L10n.displayLocale, $0)
         }) {
        self.title = title
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
        self.xFormat = xFormat
        self.yFormat = yFormat
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let xs = series.flatMap { $0.points.map(\.x) }
        let ys = series.flatMap { $0.points.map(\.y) }
        let xLow = xs.min() ?? 0
        let xHigh = max(xs.max() ?? xLow + 1, xLow + 1)
        let yLow = ys.min() ?? 0
        let yHigh = max(ys.max() ?? yLow + 1, yLow + 1)

        let xAxis = AXNumericDataAxisDescriptor(
            title: xLabel, range: xLow...xHigh, gridlinePositions: []
        ) { [xFormat] in xFormat($0) }
        let yAxis = AXNumericDataAxisDescriptor(
            title: yLabel, range: yLow...yHigh, gridlinePositions: []
        ) { [yFormat] in yFormat($0) }

        let descriptors = series.map { series in
            AXDataSeriesDescriptor(
                name: series.name,
                isContinuous: true,
                dataPoints: series.points.map { AXDataPoint(x: $0.x, y: $0.y) }
            )
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: descriptors)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}

/// A chart whose X axis is a set of named buckets, like the energy-by-time-of-day bars.
struct CategoricalSeriesAXDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        /// One value per category, in the same order as `categories`.
        let values: [Double]
    }

    let title: String
    let categoryLabel: String
    let valueLabel: String
    let categories: [String]
    let series: [Series]
    var valueFormat: @Sendable (Double) -> String

    init(title: String,
         categoryLabel: String,
         valueLabel: String,
         categories: [String],
         series: [Series],
         valueFormat: @escaping @Sendable (Double) -> String = {
             String(format: "%.1f", locale: L10n.displayLocale, $0)
         }) {
        self.title = title
        self.categoryLabel = categoryLabel
        self.valueLabel = valueLabel
        self.categories = categories
        self.series = series
        self.valueFormat = valueFormat
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let values = series.flatMap(\.values)
        let yLow = min(0, values.min() ?? 0)
        let yHigh = max(values.max() ?? yLow + 1, yLow + 1)

        let xAxis = AXCategoricalDataAxisDescriptor(
            title: categoryLabel, categoryOrder: categories
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: valueLabel, range: yLow...yHigh, gridlinePositions: []
        ) { [valueFormat] in valueFormat($0) }

        let descriptors = series.map { series in
            AXDataSeriesDescriptor(
                name: series.name,
                isContinuous: false,
                dataPoints: zip(categories, series.values).map {
                    AXDataPoint(x: $0.0, y: $0.1)
                }
            )
        }
        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: descriptors)
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {}
}

// MARK: - Scrub callout

extension View {
    /// Standard styling for the little floating label a chart shows under the scrub cursor.
    func historyScrubCallout() -> some View {
        self.hisType(.micro, weight: .semibold)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(HisingenTheme.chipFill, in: RoundedRectangle(cornerRadius: 0))
            .overlay(RoundedRectangle(cornerRadius: 0).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: HisingenTheme.elevationShadow.opacity(0.15), radius: 3, y: 1)
    }
}

// MARK: - Clipboard / print / period-scoped export

enum HistoryExport {
    /// Copies plain text to the general pasteboard.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Prints monospaced text through the standard macOS print panel – which also offers
    /// "Save as PDF", covering both the print and PDF asks without a bespoke renderer.
    @MainActor
    static func printText(_ text: String, jobTitle: String) {
        let longestLine = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(\.count)
            .max() ?? 80
        let readableWidth = max(540, CGFloat(longestLine) * 6.2)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: readableWidth, height: 720))
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable = false
        // A copy, not `NSPrintInfo.shared`: mutating the shared instance means one CSV export
        // permanently changes the margins, pagination and paper for every print the app makes
        // afterwards, including ones the reader configures themselves in the print panel.
        let info = NSPrintInfo.shared.copy() as? NSPrintInfo ?? NSPrintInfo()
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        // Preserve a readable font and paginate wide CSV horizontally instead of shrinking
        // 25 columns to a few points on one sheet.
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = jobTitle
        operation.run()
    }

    static func tripsCSV(_ trips: [TripHistoryEntry]) -> String {
        var rows = [CSV.tripHistoryHeader]
        for trip in trips {
            rows.append(HistoryCSVRows.trip(trip, number: HistoryCSVRows.localized)
                .map(CSV.field).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func chargingSessionsCSV(_ sessions: [HistoricalChargingSession]) -> String {
        var rows = [CSV.chargingHistoryHeader]
        for s in sessions {
            let fields = HistoryCSVRows.chargingSession(s, number: HistoryCSVRows.localized, location: { $0 })
                + WallboxCSV.fields(s.wallbox)
            rows.append(fields.map(CSV.field).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

// MARK: - Shared axes

/// How a Date axis words its ticks. One rule for every History chart, driven by the span the
/// chart covers and by the reader's Time Format setting (`L10n.clockLocale`). The automatic axis
/// ignored that setting and printed bare hour numbers ("18 19 20") for a session curve.
enum HistoryTimeAxis {
    static func format(span: TimeInterval, monthly: Bool = false) -> Date.FormatStyle {
        let base = Date.FormatStyle().locale(L10n.clockLocale)
        if monthly { return span > 400 * 86_400 ? base.month(.abbreviated).year() : base.month(.abbreviated) }
        if span <= 86_400 { return base.hour().minute() }
        if span <= 3 * 86_400 { return base.month(.abbreviated).day().hour() }
        if span > 365 * 86_400 { return base.month(.abbreviated).year() }
        return base.month(.abbreviated).day()
    }
}

/// One colour per quantity across the charging charts, so a hue means the same thing on every
/// card. Power and current used to share the attention colour on the same card.
@MainActor
enum HistoryChartColor {
    static var chargeLevel: Color { HisingenTheme.chartPositive }
    static var power: Color { HisingenTheme.chartAttention }
    static var current: Color { HisingenTheme.chartInfo }
    static var voltage: Color { HisingenTheme.chartHealth }
}

extension View {
    /// Date x-axis for a chart that spans `domain`. Labels at the edges anchor inward so the
    /// first and last tick are never clipped to "…".
    @MainActor
    func historyTimeAxis(domain: ClosedRange<Date>, monthly: Bool = false, showsLabels: Bool = true) -> some View {
        let span = max(1, domain.upperBound.timeIntervalSince(domain.lowerBound))
        let format = HistoryTimeAxis.format(span: span, monthly: monthly)
        return chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(HisingenTheme.hairline)
                AxisTick().foregroundStyle(HisingenTheme.hairline)
                if showsLabels, let date = value.as(Date.self) {
                    let fraction = date.timeIntervalSince(domain.lowerBound) / span
                    let anchor: UnitPoint = fraction < 0.12 ? .topLeading : fraction > 0.88 ? .topTrailing : .top
                    AxisValueLabel(centered: false, anchor: anchor, collisionResolution: .greedy) {
                        Text(date.formatted(format))
                            .hisType(.caption)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize()
                    }
                }
            }
        }
    }

    /// Date x-axis for a chart whose domain is whatever its data covers.
    @MainActor
    func historyTimeAxis(spanning dates: [Date], monthly: Bool = false, showsLabels: Bool = true) -> some View {
        let lower = dates.min() ?? Date()
        let upper = max(dates.max() ?? lower, lower.addingTimeInterval(60))
        return historyTimeAxis(domain: lower...upper, monthly: monthly, showsLabels: showsLabels)
    }

    /// Trailing value axis with the unit above it. Every History chart used its own side, title
    /// and font; this is the one rule. `labelWidth` pins the label column so charts stacked on a
    /// shared time axis keep identical plot widths.
    @MainActor
    func historyYAxis(_ unit: String? = nil, values: AxisMarkValues = .automatic(desiredCount: 4),
                      labelWidth: CGFloat? = nil) -> some View {
        chartYAxis {
            AxisMarks(position: .trailing, values: values) { value in
                AxisGridLine().foregroundStyle(HisingenTheme.hairline)
                AxisValueLabel {
                    if let number = value.as(Double.self) ?? value.as(Int.self).map(Double.init) {
                        Text(Format.number(number, decimals: abs(number) < 10 && number != number.rounded() ? 1 : 0))
                            .hisType(.caption)
                            .monospacedDigit()
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .frame(width: labelWidth, alignment: .trailing)
                    }
                }
            }
        }
        .chartYAxisLabel(position: .top, alignment: .trailing, spacing: 2) {
            if let unit {
                Text(unit).hisType(.caption).foregroundStyle(HisingenTheme.inkMuted)
            }
        }
    }
}

// MARK: - Legend

/// A legend entry drawn as the mark it names: a solid or dashed stroke, or a filled square for a band.
struct HistoryChartLegendItem: View {
    let color: Color
    let label: String
    var dashed = false
    var band = false

    var body: some View {
        HStack(spacing: 4) {
            Group {
                if band {
                    Rectangle().fill(color).frame(width: 10, height: 10)
                } else if dashed {
                    Rectangle().stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: [3, 2]))
                        .frame(width: 14, height: 2.5)
                } else {
                    Rectangle().fill(color).frame(width: 14, height: 2.5)
                }
            }
            .accessibilityHidden(true)
            Text(label).hisType(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Units for plotted values

extension EnergyConsumptionUnit {
    /// The canonical kWh/100 km reading in the unit the reader chose, so the axis, the scrub
    /// callout and the header agree. The charts plotted the raw value under a header that had
    /// already been converted.
    func plotValue(kwhPer100Km value: Double) -> Double {
        switch self {
        case .kwhPer100Km: return value
        case .kwhPer100Miles: return value * 1.609344
        case .milesPerKwh: return value > 0 ? 62.1371192 / value : 0
        }
    }
}

extension FuelEconomyUnit {
    func plotValue(lPer100Km value: Double) -> Double {
        switch self {
        case .litersPer100Km: return value
        case .milesPerGallonUS: return value > 0 ? 235.214583 / value : 0
        case .milesPerGallonUK: return value > 0 ? 282.481 / value : 0
        case .kmPerLiter: return value > 0 ? 100.0 / value : 0
        }
    }
}

// MARK: - Scrubbing

/// A time-series chart with a scrub cursor and callout. The selection lives here, not in the
/// dashboard: it used to be `@State` on the whole `HistoryDashboardView`, so every pointer move
/// re-ran the body of every card (seasonal efficiency, range estimate, tariff split).
struct HistoryScrubChart<Item: Identifiable, Marks: ChartContent>: View {
    let items: [Item]
    let date: (Item) -> Date
    var ruleUnit: Calendar.Component? = nil
    let callout: (Item) -> String
    @ChartContentBuilder let marks: () -> Marks

    @State private var scrub: Date?

    var body: some View {
        Chart {
            marks()
            if let scrub, let hit = HistoryInsights.nearest(to: scrub, in: items, timestamp: date) {
                if let ruleUnit {
                    cursor(PlottableValue.value(L10n.text("Date"), date(hit), unit: ruleUnit), text: callout(hit))
                } else {
                    cursor(PlottableValue.value(L10n.text("Date"), date(hit)), text: callout(hit))
                }
            }
        }
        .chartXSelection(value: $scrub)
    }

    @ChartContentBuilder
    private func cursor(_ x: PlottableValue<Date>, text: String) -> some ChartContent {
        RuleMark(x: x)
            .foregroundStyle(Color.primary.opacity(0.25))
            .annotation(position: .top, spacing: 0,
                        overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                Text(text).historyScrubCallout()
            }
    }
}
