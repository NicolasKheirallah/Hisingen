import Foundation

enum CSV {
    static let tripHistoryHeader = [
        "Trip ID", "VIN", "Started At", "Ended At", "Duration (min)", "Distance (km)",
        "Average Consumption", "Ambient Temperature (C)", "Start Latitude", "Start Longitude",
        "End Latitude", "End Longitude"
    ].joined(separator: ",")

    static let chargingHistoryHeader = ([
        "Session ID", "VIN", "Started At", "Ended At", "Start SoC (%)", "End SoC (%)",
        "Estimated Energy Added (kWh)", "Observed Peak Power (kW)", "Sample Average Power (kW)",
        "Location", "Lifecycle", "Completion Reason", "Energy Source", "Confidence",
        "Sample Coverage", "Usable Capacity (kWh)", "Day Tariff", "Night Tariff Enabled",
        "Night Tariff", "Night Start Hour", "Night End Hour", "Estimated Cost", "Currency",
        "Target SoC", "Summary Version"
    ] + WallboxCSV.header).joined(separator: ",")

    /// Quotes a CSV cell containing a comma, quote or newline, doubling embedded quotes.
    static func field(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return value.contains(",") || value.contains("\"") || value.contains("\n")
            ? "\"\(escaped)\"" : value
    }
}
