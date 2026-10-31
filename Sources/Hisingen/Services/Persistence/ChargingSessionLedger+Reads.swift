import Foundation

extension ChargingSessionLedger {
    // MARK: - Session and sample reads

    func activeChargingSession(for vin: String) -> HistoricalChargingSession? {
        let query = """
        SELECT \(Self.chargingSessionColumns)
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NULL
          AND lifecycle_state IN ('active', 'paused', 'pending_completion')
        ORDER BY started_at DESC LIMIT 1;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> HistoricalChargingSession? in
            guard try stmt.stepOrThrow() else { return nil }
            return Self.sessionRow(from: stmt, endedAt: nil, endSoc: nil, energy: nil,
                                   peak: nil, average: nil, location: nil)
        }) ?? nil
    }

    /// Completed sessions for a VIN with a real SoC gain or recorded energy, newest first.
    func recentChargingSessions(
        for vin: String, limit: Int = 20, since: Date? = nil
    ) -> [HistoricalChargingSession] {
        let dateClause = since == nil ? "" : " AND started_at >= ?"
        let query = """
        SELECT \(Self.chargingSessionColumns)
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NOT NULL
          \(dateClause)
          AND lifecycle_state IN ('completed', 'interrupted')
          AND (
            end_soc > start_soc OR energy_delivered_kwh > 0 OR EXISTS (
              SELECT 1 FROM charging_samples
              WHERE charging_samples.session_id = charging_sessions.id
                AND charging_samples.soc > charging_sessions.start_soc
            )
          )
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            if let since { try stmt.bindDate(since, at: 2) }
            try stmt.bindInt64(Int64(limit), at: since == nil ? 2 : 3)
        } process: { stmt -> [HistoricalChargingSession] in
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

    func chargingSamples(for sessionId: String) -> [HistoricalChargingSample] {
        let query = """
        SELECT \(HistoryRowDecoder.Columns.chargingSample)
        FROM charging_samples WHERE session_id = ? ORDER BY timestamp ASC;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(sessionId, at: 1)
        } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.chargingSample)
        }) ?? []
    }

    /// Lifetime charging energy for a VIN across all stored sessions (kWh).
    func lifetimeChargingEnergyKwh(for vin: String) -> Double {
        var total = 0.0
        try? sql.readQuery(sql: "SELECT COALESCE(SUM(energy_delivered_kwh),0) FROM charging_sessions WHERE vin = ? AND lifecycle_state IN ('completed', 'interrupted');", bindings: { stmt in
            try stmt.bindText(vin, at: 1)
        }, process: { stmt in
            if try stmt.stepOrThrow() { total = stmt.columnDouble(at: 0) ?? 0 }
        })
        return total
    }

    /// Peak power history for prior sessions at the same named location (newest excluded by
    /// the caller passing its id), oldest-first – the baseline for anomaly detection.
    func priorSessionPeaks(vin: String, locationName: String,
                           excludingSessionID: String, limit: Int = 10) -> [Double] {
        guard !locationName.isEmpty else { return [] }
        let query = """
        SELECT peak_power_kw FROM charging_sessions
        WHERE vin = ? AND location_name = ? AND id != ? AND peak_power_kw > 0
          AND lifecycle_state IN ('completed', 'interrupted')
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindText(locationName, at: 2)
            try stmt.bindText(excludingSessionID, at: 3)
            try stmt.bindInt64(Int64(limit), at: 4)
        } process: { stmt -> [Double] in
            var out: [Double] = []
            while try stmt.stepOrThrow(), let v = stmt.columnDouble(at: 0) { out.append(v) }
            return out
        }) ?? []
    }
}
