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
              AND (end_soc > start_soc OR energy_delivered_kwh > 0)
            ORDER BY started_at DESC;
            """
            sessions = (try? sql.query(sql: query) { _ in } process: { stmt -> [HistoricalChargingSession] in
                var list: [HistoricalChargingSession] = []
                while try stmt.stepOrThrow() {
                    guard let session = Self.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                        endSoc: stmt.columnDouble(at: 5),
                                                        energy: stmt.columnDouble(at: 6),
                                                        peak: stmt.columnDouble(at: 7),
                                                        average: stmt.columnDouble(at: 8),
                                                        location: stmt.columnText(at: 9)) else { continue }
                    list.append(session)
                }
                return list
            }) ?? []
        }

        var csv = "Session ID,VIN,Started At,Ended At,Start SoC (%),End SoC (%),Estimated Energy Added (kWh),Observed Peak Power (kW),Sample Average Power (kW),Location,Lifecycle,Completion Reason,Energy Source,Confidence,Sample Coverage,Usable Capacity (kWh),Day Tariff,Night Tariff Enabled,Night Tariff,Night Start Hour,Night End Hour,Estimated Cost,Currency,Target SoC,Summary Version\n"
        let df = ISO8601DateFormatter()
        for s in sessions {
            let start = df.string(from: s.startedAt)
            let end = s.endedAt.map { df.string(from: $0) } ?? ""
            let endSoc = s.endSoc.map { String(format: "%.1f", $0) } ?? ""
            let loc = (s.locationName ?? "").replacingOccurrences(of: ",", with: " ")
            let coverage = s.sampleCoverage.map { String(format: "%.3f", $0) } ?? ""
            let capacity = s.usableCapacityKwh.map { String(format: "%.2f", $0) } ?? ""
            let tariff = s.tariffPricePerKwh.map { String(format: "%.4f", $0) } ?? ""
            let nightTariff = s.nightTariffPricePerKwh.map { String(format: "%.4f", $0) } ?? ""
            let nightStart = s.nightTariffStartHour.map(String.init) ?? ""
            let nightEnd = s.nightTariffEndHour.map(String.init) ?? ""
            let cost = s.estimatedCost.map { String(format: "%.2f", $0) } ?? ""
            let target = s.targetSoc.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(s.id),\(s.vin),\(start),\(end),\(String(format: "%.1f", s.startSoc)),\(endSoc),\(String(format: "%.2f", s.energyDeliveredKwh)),\(String(format: "%.1f", s.peakPowerKw)),\(String(format: "%.1f", s.averagePowerKw)),\(loc),\(s.lifecycleState.rawValue),\(s.completionReason?.rawValue ?? ""),\(s.energySource.rawValue),\(s.confidence.rawValue),\(coverage),\(capacity),\(tariff),\(s.nightTariffEnabled),\(nightTariff),\(nightStart),\(nightEnd),\(cost),\(s.currencySymbol ?? ""),\(target),\(s.summaryVersion)\n"
        }
        return csv
    }

    /// Raw per-sample export for one charging session – the curve data exactly as recorded,
    /// for third-party analysis or debugging a misshapen curve.
    func exportChargingSamplesCSV(sessionID: String) -> String {
        let samples = chargingSamples(for: sessionID)
        let formatter = ISO8601DateFormatter()
        var csv = "Timestamp,SOC (%),Power (kW),Voltage (V),Current (A)\n"
        for sample in samples {
            func cell(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(formatter.string(from: sample.timestamp)),\(String(format: "%.1f", sample.soc)),\(cell(sample.powerKw)),\(cell(sample.voltageVolts)),\(cell(sample.currentAmps))\n"
        }
        return csv
    }
}
