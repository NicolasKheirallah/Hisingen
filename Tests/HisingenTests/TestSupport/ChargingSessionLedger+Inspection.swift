import Foundation
@testable import Hisingen

/// Reads the tests use to assert what a wallbox sync stored. Nothing in the app calls them.
extension ChargingSessionLedger {
    func wallboxIntervals(rowID: String) -> [HomeEnergyInterval] {
        (try? sql.query(sql: "SELECT wallbox_intervals FROM charging_sessions WHERE id = ?;") { stmt in
            try stmt.bindText(rowID, at: 1)
        } process: { stmt -> [HomeEnergyInterval] in
            guard try stmt.stepOrThrow(), let text = stmt.columnText(at: 0), let data = text.data(using: .utf8) else { return [] }
            return (try? JSONDecoder.iso.decode([HomeEnergyInterval].self, from: data)) ?? []
        }) ?? []
    }

    /// Charger sessions no vehicle could be tied to, newest first.
    func unassignedWallboxSessions(chargerID: String? = nil, limit: Int = 200) -> [HistoricalChargingSession] {
        let filter = chargerID == nil ? "" : " AND wallbox_charger_id = ?"
        let query = """
        SELECT \(Self.chargingSessionColumns) FROM charging_sessions
        WHERE vin = '' AND wallbox_session_key IS NOT NULL\(filter)
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            var index: Int32 = 1
            if let chargerID { try stmt.bindText(chargerID, at: index); index += 1 }
            try stmt.bindInt64(Int64(limit), at: index)
        } process: { try Self.sessionRows($0) }) ?? []
    }

    /// How many rows carry a given wallbox key.
    func wallboxSessionCount(chargerID: String) -> Int {
        (try? sql.query(sql: "SELECT COUNT(*) FROM charging_sessions WHERE wallbox_charger_id = ?;") { stmt in
            try stmt.bindText(chargerID, at: 1)
        } process: { stmt -> Int in
            try stmt.stepOrThrow() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }) ?? 0
    }
}
