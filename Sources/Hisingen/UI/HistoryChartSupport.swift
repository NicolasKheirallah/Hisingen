import AppKit
import Charts
import SwiftUI

// MARK: - VoiceOver: expose a line chart's numbers instead of an opaque "chart"

/// Wraps a `(Date, Double)` series so the VoiceOver chart rotor can read individual values.
/// Attach with `.accessibilityChartDescriptor(TimeSeriesAXDescriptor(...))`.
struct TimeSeriesAXDescriptor: AXChartDescriptorRepresentable {
    let title: String
    let yLabel: String
    let points: [(date: Date, value: Double)]
    var valueFormat: @Sendable (Double) -> String = { String(format: "%.1f", $0) }

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
        self.font(.system(size: 9, weight: .semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
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

    /// Prints monospaced text through the standard macOS print panel — which also offers
    /// "Save as PDF", covering both the print and PDF asks without a bespoke renderer.
    @MainActor
    static func printText(_ text: String, jobTitle: String) {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 720))
        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        textView.isEditable = false
        let info = NSPrintInfo.shared
        info.topMargin = 36; info.bottomMargin = 36
        info.leftMargin = 36; info.rightMargin = 36
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = jobTitle
        operation.run()
    }

    // The two series a user most often wants clipped to the visible period. Column order
    // mirrors `VehicleDatabase.exportTripsCSV` / `exportChargingSessionsCSV` so a period
    // export and a full export open the same way.

    static func tripsCSV(_ trips: [TripHistoryEntry]) -> String {
        let header = "Trip ID,VIN,Started At,Ended At,Duration (min),Distance (km),Average Consumption,Ambient Temperature (C),Start Latitude,Start Longitude,End Latitude,End Longitude"
        let df = ISO8601DateFormatter()
        func opt(_ value: Double?, _ places: Int) -> String { value.map { String(format: "%.\(places)f", $0) } ?? "" }
        func coord(_ value: Double?) -> String { value.map { String($0) } ?? "" }
        var rows: [String] = [header]
        for trip in trips {
            let fields: [String] = [
                trip.id, trip.vin,
                df.string(from: trip.startedAt),
                df.string(from: trip.endedAt),
                String(format: "%.1f", trip.duration / 60),
                String(format: "%.2f", trip.distanceKm),
                opt(trip.averageConsumption, 2),
                opt(trip.ambientTemperatureCelsius, 1),
                coord(trip.startLatitude), coord(trip.startLongitude),
                coord(trip.endLatitude), coord(trip.endLongitude)
            ]
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func chargingSessionsCSV(_ sessions: [HistoricalChargingSession]) -> String {
        let header = "Session ID,VIN,Started At,Ended At,Start SoC (%),End SoC (%),Estimated Energy Added (kWh),Observed Peak Power (kW),Sample Average Power (kW),Location,Lifecycle,Completion Reason,Energy Source,Confidence,Sample Coverage,Usable Capacity (kWh),Day Tariff,Night Tariff Enabled,Night Tariff,Night Start Hour,Night End Hour,Estimated Cost,Currency,Target SoC,Summary Version"
        let df = ISO8601DateFormatter()
        func opt(_ value: Double?, _ places: Int) -> String { value.map { String(format: "%.\(places)f", $0) } ?? "" }
        var rows: [String] = [header]
        for s in sessions {
            let fields: [String] = [
                s.id, s.vin,
                df.string(from: s.startedAt),
                s.endedAt.map { df.string(from: $0) } ?? "",
                String(format: "%.1f", s.startSoc),
                opt(s.endSoc, 1),
                String(format: "%.2f", s.energyDeliveredKwh),
                String(format: "%.1f", s.peakPowerKw),
                String(format: "%.1f", s.averagePowerKw),
                (s.locationName ?? "").replacingOccurrences(of: ",", with: " "),
                s.lifecycleState.rawValue,
                s.completionReason?.rawValue ?? "",
                s.energySource.rawValue,
                s.confidence.rawValue,
                opt(s.sampleCoverage, 3),
                opt(s.usableCapacityKwh, 2),
                opt(s.tariffPricePerKwh, 4),
                String(s.nightTariffEnabled),
                opt(s.nightTariffPricePerKwh, 4),
                s.nightTariffStartHour.map(String.init) ?? "",
                s.nightTariffEndHour.map(String.init) ?? "",
                opt(s.estimatedCost, 2),
                s.currencySymbol ?? "",
                opt(s.targetSoc, 1),
                String(s.summaryVersion)
            ]
            rows.append(fields.joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}
