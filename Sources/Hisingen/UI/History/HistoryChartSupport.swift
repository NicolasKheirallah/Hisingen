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
    let title: String
    let yLabel: String
    let points: [(date: Date, value: Double)]
    var valueFormat: @Sendable (Double) -> String = { String(format: "%.1f", locale: L10n.displayLocale, $0) }

    func makeChartDescriptor() -> AXChartDescriptor {
        let dates = points.map { $0.date.timeIntervalSince1970 }
        let values = points.map(\.value)
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

        let series = AXDataSeriesDescriptor(
            name: title,
            isContinuous: true,
            dataPoints: points.map { AXDataPoint(x: $0.date.timeIntervalSince1970, y: $0.value) }
        )

        return AXChartDescriptor(title: title, summary: nil, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: [series])
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
