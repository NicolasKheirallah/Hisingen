import Foundation

struct WallboxRecordResult: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A new row: no vehicle-side record existed and the session was added.
        case inserted
        /// The vehicle's own row for this charge gained the charger's measurement.
        case enriched
        /// Same key as before; measurements refreshed.
        case updated
        /// Same key and same figures: nothing to write.
        case unchanged
        /// A different key described the same physical session; the rows were joined.
        case merged
    }

    var rowID: String
    var kind: Kind
}

/// The charger side of a charging session, stored on the same row as the vehicle's record.
///
/// One physical charge is one row. A session is found by its key first (a repeated sync, a
/// reconnect or a sleeping Mac lands here and changes nothing), then by overlap on the same
/// charger (the same charge seen through a different source), and only then added.
extension ChargingSessionLedger {
    /// Wallbox attribution labels stored with the row.
    enum WallboxAttribution {
        static let overlap = "overlap"
        static let dedicated = "dedicated_pairing"
        static let sharedWithoutOverlap = "unassigned_shared_charger"
        static let anotherVehicle = "unassigned_other_vehicle"
    }

    private struct WallboxRowRef {
        var id: String
        var keyKind: String?
        var key: String?
        var measuredAt: Date?
        var energyKwh: Double?
        var cost: Double?
        var start: Date
        var end: Date
    }

    /// Vehicle-observed sessions near a window, for matching. Rows the charger created are not
    /// vehicle evidence and are left out.
    func observedVehicleSessions(from start: Date, to end: Date) -> [ObservedVehicleSession] {
        let query = """
        SELECT id, vin, started_at, COALESCE(ended_at, last_observed_at, started_at)
        FROM charging_sessions
        WHERE vin != '' AND energy_source != 'wallbox_only'
          AND lifecycle_state != 'abandoned'
          AND started_at <= ? AND COALESCE(ended_at, last_observed_at, started_at) >= ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindDate(end, at: 1)
            try stmt.bindDate(start, at: 2)
        } process: { stmt -> [ObservedVehicleSession] in
            var rows: [ObservedVehicleSession] = []
            while try stmt.stepOrThrow() {
                guard let id = stmt.columnText(at: 0), let vin = stmt.columnText(at: 1),
                      let started = stmt.columnDate(at: 2), let ended = stmt.columnDate(at: 3) else { continue }
                rows.append(ObservedVehicleSession(id: id, vin: vin, start: started, end: ended))
            }
            return rows
        }) ?? []
    }

    /// Writes one charger session. Idempotent: calling it again with the same candidate changes nothing.
    @discardableResult
    func recordWallboxSession(
        _ candidate: HomeChargingSessionCandidate,
        decision: HomeSessionAttribution.Decision,
        cost: HomeSessionCost?,
        locationName: String?
    ) -> WallboxRecordResult? {
        var result: WallboxRecordResult?
        logOnFailure("wallbox session write") {
            result = try sql.withTransaction { try upsertWallbox(candidate, decision: decision, cost: cost, locationName: locationName) }
        }
        return result
    }

    private func upsertWallbox(_ candidate: HomeChargingSessionCandidate, decision: HomeSessionAttribution.Decision,
                               cost: HomeSessionCost?, locationName: String?) throws -> WallboxRecordResult {
        // 1. The same key: a repeated sync.
        if let existing = try wallboxRow(key: candidate.key) {
            let same = Self.sameFigures(existing, candidate, cost: cost)
            if !same { try writeWallboxColumns(rowID: existing.id, candidate: candidate, cost: cost, attribution: nil) }
            return WallboxRecordResult(rowID: existing.id, kind: same ? .unchanged : .updated)
        }

        // 2. The same charge under another key: join rather than add.
        if let twin = try wallboxRowOverlapping(chargerID: candidate.chargerID, start: candidate.startedAt, end: candidate.endedAt) {
            let existingRank = twin.keyKind.flatMap(HomeChargingSessionCandidate.KeyKind.init(rawValue:))?.rank ?? 0
            if candidate.keyKind.rank > existingRank {
                try writeWallboxColumns(rowID: twin.id, candidate: candidate, cost: cost, attribution: nil)
            } else if let measured = twin.measuredAt, candidate.measuredAt > measured {
                // Keep the stronger key, take the fresher figures.
                var refreshed = candidate
                refreshed.key = twin.key ?? candidate.key
                refreshed.keyKind = twin.keyKind.flatMap(HomeChargingSessionCandidate.KeyKind.init(rawValue:)) ?? candidate.keyKind
                try writeWallboxColumns(rowID: twin.id, candidate: refreshed, cost: cost, attribution: nil)
            }
            return WallboxRecordResult(rowID: twin.id, kind: .merged)
        }

        // 3. A genuinely new charge.
        switch decision {
        case .enrich(let rowID, _):
            try writeWallboxColumns(rowID: rowID, candidate: candidate, cost: cost, attribution: WallboxAttribution.overlap)
            return WallboxRecordResult(rowID: rowID, kind: .enriched)
        case .newForVehicle(let vin):
            let id = try insertWallboxRow(candidate, vin: vin, cost: cost, locationName: locationName,
                                          attribution: WallboxAttribution.dedicated)
            return WallboxRecordResult(rowID: id, kind: .inserted)
        case .unassigned(let reason):
            let label = reason == .overlapsAnotherVehicle ? WallboxAttribution.anotherVehicle : WallboxAttribution.sharedWithoutOverlap
            let id = try insertWallboxRow(candidate, vin: "", cost: cost, locationName: locationName, attribution: label)
            return WallboxRecordResult(rowID: id, kind: .inserted)
        }
    }

    private static func sameFigures(_ row: WallboxRowRef, _ candidate: HomeChargingSessionCandidate, cost: HomeSessionCost?) -> Bool {
        guard let energy = row.energyKwh, abs(energy - candidate.energyKwh) < 0.0005,
              let measured = row.measuredAt, abs(measured.timeIntervalSince(candidate.measuredAt)) < 0.5 else { return false }
        switch (row.cost, cost?.amount) {
        case (nil, nil): return true
        case let (a?, b?): return abs(a - b) < 0.005
        default: return false
        }
    }

    private func wallboxRow(key: String) throws -> WallboxRowRef? {
        try sql.query(sql: Self.wallboxRefSelect + " WHERE wallbox_session_key = ? LIMIT 1;") { stmt in
            try stmt.bindText(key, at: 1)
        } process: { stmt -> WallboxRowRef? in
            guard try stmt.stepOrThrow() else { return nil }
            return Self.wallboxRef(stmt)
        }
    }

    private func wallboxRowOverlapping(chargerID: String, start: Date, end: Date) throws -> WallboxRowRef? {
        let rows = try sql.query(sql: Self.wallboxRefSelect + """
             WHERE wallbox_charger_id = ?
               AND COALESCE(wallbox_started_at, started_at) <= ?
               AND COALESCE(wallbox_ended_at, ended_at, started_at) >= ?;
            """) { stmt in
            try stmt.bindText(chargerID, at: 1)
            try stmt.bindDate(end, at: 2)
            try stmt.bindDate(start, at: 3)
        } process: { stmt -> [WallboxRowRef] in
            var refs: [WallboxRowRef] = []
            while try stmt.stepOrThrow() { if let ref = Self.wallboxRef(stmt) { refs.append(ref) } }
            return refs
        }
        let candidateSession = HomeChargingSessionCandidate(
            key: "", keyKind: .history, chargerID: chargerID, startedAt: start, endedAt: end,
            energyKwh: 0, energySource: "", measuredAt: end
        )
        return rows.first { ref in
            HomeSessionAttribution.overlapFraction(
                candidate: candidateSession,
                session: ObservedVehicleSession(id: ref.id, vin: "", start: ref.start, end: ref.end)
            ) >= HomeSessionAttribution.requiredOverlap
        }
    }

    private static let wallboxRefSelect = """
        SELECT id, wallbox_key_kind, wallbox_session_key, wallbox_measured_at, wallbox_energy_kwh, wallbox_cost,
               COALESCE(wallbox_started_at, started_at),
               COALESCE(wallbox_ended_at, ended_at, started_at)
        FROM charging_sessions
        """

    private static func wallboxRef(_ stmt: SQLiteStatement) -> WallboxRowRef? {
        guard let id = stmt.columnText(at: 0), let start = stmt.columnDate(at: 6), let end = stmt.columnDate(at: 7) else { return nil }
        return WallboxRowRef(id: id, keyKind: stmt.columnText(at: 1), key: stmt.columnText(at: 2),
                             measuredAt: stmt.columnDate(at: 3), energyKwh: stmt.columnDouble(at: 4),
                             cost: stmt.columnDouble(at: 5), start: start, end: end)
    }

    private func writeWallboxColumns(rowID: String, candidate: HomeChargingSessionCandidate,
                                     cost: HomeSessionCost?, attribution: String?) throws {
        try sql.query(sql: """
            UPDATE charging_sessions SET
                wallbox_charger_id = ?, wallbox_session_key = ?, wallbox_key_kind = ?,
                wallbox_energy_kwh = ?, wallbox_energy_source = ?, wallbox_measured_at = ?,
                wallbox_started_at = ?, wallbox_ended_at = ?, wallbox_peak_kw = ?, wallbox_intervals = ?,
                wallbox_cost = ?, wallbox_partial_cost = ?, wallbox_cost_method = ?, wallbox_price_source = ?,
                wallbox_cost_assumptions = ?, wallbox_missing_kwh = ?, wallbox_currency = ?,
                wallbox_attribution = COALESCE(?, wallbox_attribution)
            WHERE id = ?;
            """) { stmt in
            try Self.bindWallbox(stmt, candidate: candidate, cost: cost, from: 1)
            try stmt.bindText(attribution, at: 18)
            try stmt.bindText(rowID, at: 19)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    private func insertWallboxRow(_ candidate: HomeChargingSessionCandidate, vin: String, cost: HomeSessionCost?,
                                  locationName: String?, attribution: String) throws -> String {
        let id = UUID().uuidString
        try sql.query(sql: """
            INSERT INTO charging_sessions (
                id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, peak_power_kw,
                average_power_kw, location_name, created_at, lifecycle_state, completion_reason, energy_source,
                confidence, summary_version, pending_stop_count, last_observed_at,
                wallbox_charger_id, wallbox_session_key, wallbox_key_kind, wallbox_energy_kwh,
                wallbox_energy_source, wallbox_measured_at, wallbox_started_at, wallbox_ended_at,
                wallbox_peak_kw, wallbox_intervals, wallbox_cost, wallbox_partial_cost, wallbox_cost_method,
                wallbox_price_source, wallbox_cost_assumptions, wallbox_missing_kwh, wallbox_currency,
                wallbox_attribution
            ) VALUES (
                ?, ?, ?, ?, ?, ?, 0.0, ?, 0.0, ?, ?, 'completed', 'stopped', 'wallbox_only', 'medium', 2, 0, ?,
                ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            );
            """) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(candidate.startedAt, at: 3)
            try stmt.bindDate(candidate.endedAt, at: 4)
            // -1 is "no battery reading": every reader that compares start and end percent skips it.
            try stmt.bindDouble(candidate.vehicleStartPercent ?? -1, at: 5)
            try stmt.bindDouble(candidate.vehicleEndPercent, at: 6)
            try stmt.bindDouble(candidate.peakPowerKw ?? 0, at: 7)
            try stmt.bindText(locationName, at: 8)
            try stmt.bindDate(Date(), at: 9)
            try stmt.bindDate(candidate.endedAt, at: 10)
            try Self.bindWallbox(stmt, candidate: candidate, cost: cost, from: 11)
            try stmt.bindText(attribution, at: 28)
            try stmt.executeUpdate()
        } process: { _ in }
        return id
    }

    /// Binds the seventeen shared wallbox values, in column order, starting at `index`.
    private static func bindWallbox(_ stmt: SQLiteStatement, candidate: HomeChargingSessionCandidate,
                                    cost: HomeSessionCost?, from index: Int32) throws {
        var i = index
        func next() -> Int32 { defer { i += 1 }; return i }
        try stmt.bindText(candidate.chargerID, at: next())
        try stmt.bindText(candidate.key, at: next())
        try stmt.bindText(candidate.keyKind.rawValue, at: next())
        try stmt.bindDouble(candidate.energyKwh, at: next())
        try stmt.bindText(candidate.energySource, at: next())
        try stmt.bindDate(candidate.measuredAt, at: next())
        try stmt.bindDate(candidate.startedAt, at: next())
        try stmt.bindDate(candidate.endedAt, at: next())
        try stmt.bindDouble(candidate.peakPowerKw, at: next())
        let intervals = (try? JSONEncoder.sortedISO.encode(candidate.intervals)).map { String(decoding: $0, as: UTF8.self) }
        try stmt.bindText(intervals, at: next())
        try stmt.bindDouble(cost?.amount, at: next())
        try stmt.bindDouble(cost?.partialAmount, at: next())
        try stmt.bindText(cost?.method.rawValue, at: next())
        try stmt.bindText(cost?.priceSource, at: next())
        let assumptions = cost.flatMap { try? JSONEncoder().encode($0.assumptions) }.map { String(decoding: $0, as: UTF8.self) }
        try stmt.bindText(assumptions, at: next())
        try stmt.bindDouble(cost?.missingKwh, at: next())
        try stmt.bindText(cost?.currency, at: next())
    }

    // MARK: - Reads

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

    /// How many rows carry a given wallbox key. Used by tests and by the sync summary.
    func wallboxSessionCount(chargerID: String) -> Int {
        (try? sql.query(sql: "SELECT COUNT(*) FROM charging_sessions WHERE wallbox_charger_id = ?;") { stmt in
            try stmt.bindText(chargerID, at: 1)
        } process: { stmt -> Int in
            try stmt.stepOrThrow() ? Int(stmt.columnInt64(at: 0) ?? 0) : 0
        }) ?? 0
    }

    /// The newest wallbox session end for a charger, so a sync can ask Home Assistant only for newer history.
    func latestWallboxEnd(chargerID: String) -> Date? {
        (try? sql.query(sql: "SELECT MAX(COALESCE(wallbox_ended_at, ended_at)) FROM charging_sessions WHERE wallbox_charger_id = ?;") { stmt in
            try stmt.bindText(chargerID, at: 1)
        } process: { stmt -> Date? in
            try stmt.stepOrThrow() ? stmt.columnDate(at: 0) : nil
        }) ?? nil
    }
}

extension JSONEncoder {
    /// ISO 8601 dates and stable key order, for values stored as text.
    static var sortedISO: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
