import Foundation

extension ChargingSessionLedger {
    // MARK: - Exporters

    func exportChargingSessionsCSV(for vin: String? = nil) -> String {
        // Export is uncapped: the file must be complete (tax/business records), unlike the
        // dashboard's bounded, truncation-flagged views. Session rows are small summaries,
        // so an unbounded read is acceptable for a user-initiated export.
        let sessions: [HistoricalChargingSession]
        if let vin {
            sessions = recentChargingSessions(for: vin, limit: .max)
        } else {
            let query = """
            SELECT \(Self.chargingSessionColumns)
            FROM charging_sessions
            WHERE ended_at IS NOT NULL
              AND lifecycle_state IN ('completed', 'interrupted')
              AND (end_soc > start_soc OR energy_delivered_kwh > 0 OR wallbox_energy_kwh > 0)
            ORDER BY started_at DESC;
            """
            sessions = (try? sql.query(sql: query) { _ in } process: { try Self.sessionRows($0) }) ?? []
        }

        var csv = CSV.chargingHistoryHeader + "\n"
        for s in sessions {
            // Commas in the location become spaces rather than quotes; the charger columns are quoted.
            let core = HistoryCSVRows.chargingSession(
                s, number: HistoryCSVRows.posix,
                location: { $0.replacingOccurrences(of: ",", with: " ") })
            csv += core.joined(separator: ",") + ",\(WallboxCSV.fields(s.wallbox).map(CSV.field).joined(separator: ","))\n"
        }
        return csv
    }

    /// Raw per-sample export for one charging session – the curve data exactly as recorded,
    /// for third-party analysis or debugging a misshapen curve.
    func exportChargingSamplesCSV(sessionID: String) -> String {
        let samples = chargingSamples(for: sessionID)
        let formatter = Format.iso8601
        var csv = "Timestamp,SOC (%),Power (kW),Voltage (V),Current (A)\n"
        for sample in samples {
            func cell(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(formatter.string(from: sample.timestamp)),\(String(format: "%.1f", sample.soc)),\(cell(sample.powerKw)),\(cell(sample.voltageVolts)),\(cell(sample.currentAmps))\n"
        }
        return csv
    }
}
