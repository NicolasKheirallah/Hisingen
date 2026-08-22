import Foundation

/// Shared rendering of the charging-history CSV used by both the popover's charging card and
/// the status-item context menu (previously two verbatim copies that were drifting).
enum ChargingHistoryExport {
    static func csv(sessions: [ChargingSession], tariffPricePerKwh: Double, currencySymbol: String) -> String {
        let headers = "Date,Start Battery %,End Battery %,Battery Added %,kWh Delivered,Peak Power (kW),Duration (min),Estimated Cost,Currency\n"
        let rows = sessions.map { session in
            let dateStr = Format.iso8601.string(from: session.startDate)
            let costStr = session.estimatedCost(tariff: tariffPricePerKwh).map { String(format: "%.2f", $0) } ?? ""
            let peakKw = session.peakPowerWatts.map { String(format: "%.1f", Double($0) / 1000.0) } ?? ""
            return "\(dateStr),\(session.startBatteryPercentage),\(session.endBatteryPercentage),\(session.percentageAdded),\(session.kwhDelivered),\(peakKw),\(session.durationMinutes),\(costStr),\(currencySymbol)"
        }.joined(separator: "\n")
        return headers + rows
    }
}
