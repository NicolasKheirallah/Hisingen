import Foundation

extension ChargingSessionLedger {
    // MARK: - Row mapping

    /// Shared column mapping for the `charging_sessions` SELECT shape used by every session
    /// query. The field mapping and the row loop live together, so a column change is one edit.
    static func sessionRow(from stmt: SQLiteStatement,
                                   endedAt: Date?, endSoc: Double?, energy: Double?,
                                   peak: Double?, average: Double?, location: String?) -> HistoricalChargingSession? {
        guard let id = stmt.columnText(at: 0),
              let vin = stmt.columnText(at: 1),
              let startedAt = stmt.columnDate(at: 2),
              let startSoc = stmt.columnDouble(at: 4),
              let createdAt = stmt.columnDate(at: 10) else { return nil }
        return HistoricalChargingSession(
            id: id, vin: vin, startedAt: startedAt, endedAt: endedAt,
            startSoc: startSoc, endSoc: endSoc ?? stmt.columnDouble(at: 5),
            energyDeliveredKwh: energy ?? (stmt.columnDouble(at: 6) ?? 0.0),
            peakPowerKw: peak ?? (stmt.columnDouble(at: 7) ?? 0.0),
            averagePowerKw: average ?? (stmt.columnDouble(at: 8) ?? 0.0),
            locationName: location ?? stmt.columnText(at: 9), createdAt: createdAt,
            lifecycleState: stmt.columnText(at: 11).flatMap(ChargingSessionLifecycleState.init(rawValue:))
                ?? (endedAt == nil ? .active : .completed),
            completionReason: stmt.columnText(at: 12).flatMap(ChargingSessionCompletionReason.init(rawValue:)),
            energySource: stmt.columnText(at: 13).flatMap(ChargingSessionEnergySource.init(rawValue:)) ?? .legacyEstimate,
            confidence: stmt.columnText(at: 14).flatMap(ChargingSessionConfidence.init(rawValue:)) ?? .low,
            sampleCoverage: stmt.columnDouble(at: 15),
            usableCapacityKwh: stmt.columnDouble(at: 16),
            tariffPricePerKwh: stmt.columnDouble(at: 17),
            nightTariffEnabled: (stmt.columnInt64(at: 18) ?? 0) != 0,
            nightTariffPricePerKwh: stmt.columnDouble(at: 19),
            nightTariffStartHour: stmt.columnInt64(at: 20).map(Int.init),
            nightTariffEndHour: stmt.columnInt64(at: 21).map(Int.init),
            currencySymbol: stmt.columnText(at: 22),
            targetSoc: stmt.columnDouble(at: 23),
            lastObservedAt: stmt.columnDate(at: 24),
            summaryVersion: Int(stmt.columnInt64(at: 25) ?? 1),
            pendingStopCount: Int(stmt.columnInt64(at: 26) ?? 0),
            estimatedCost: stmt.columnDouble(at: 27),
            spotEstimatedCost: stmt.columnDouble(at: 28),
            wallbox: wallboxMeasurement(from: stmt)
        )
    }

    /// Decode every row of a `chargingSessionColumns` SELECT. Callers own only their `WHERE`
    /// clause; this is the one loop that turns rows into sessions.
    static func sessionRows(_ stmt: SQLiteStatement) throws -> [HistoricalChargingSession] {
        try HistoryRowDecoder.rows(stmt) { row in
            sessionRow(from: row, endedAt: row.columnDate(at: 3),
                       endSoc: row.columnDouble(at: 5),
                       energy: row.columnDouble(at: 6),
                       peak: row.columnDouble(at: 7),
                       average: row.columnDouble(at: 8),
                       location: row.columnText(at: 9))
        }
    }

    /// The wallbox columns, `nil` unless a charger's measurement is recorded on the row.
    private static func wallboxMeasurement(from stmt: SQLiteStatement) -> WallboxMeasurement? {
        guard let chargerID = stmt.columnText(at: 29),
              let key = stmt.columnText(at: 30),
              let energy = stmt.columnDouble(at: 32) else { return nil }
        let assumptions = stmt.columnText(at: 42)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        return WallboxMeasurement(
            chargerID: chargerID, sessionKey: key,
            keyKind: stmt.columnText(at: 31) ?? HomeChargingSessionCandidate.KeyKind.history.rawValue,
            energyKwh: energy, energySource: stmt.columnText(at: 33) ?? "",
            measuredAt: stmt.columnDate(at: 34) ?? Date(timeIntervalSince1970: 0),
            startedAt: stmt.columnDate(at: 35), endedAt: stmt.columnDate(at: 36),
            peakPowerKw: stmt.columnDouble(at: 37),
            cost: stmt.columnDouble(at: 38), partialCost: stmt.columnDouble(at: 39),
            costMethod: stmt.columnText(at: 40), priceSource: stmt.columnText(at: 41),
            costAssumptions: assumptions, missingKwh: stmt.columnDouble(at: 43),
            currency: stmt.columnText(at: 44), attribution: stmt.columnText(at: 45)
        )
    }

    static let chargingSessionColumns = """
        id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
        peak_power_kw, average_power_kw, location_name, created_at, lifecycle_state,
        completion_reason, energy_source, confidence, sample_coverage,
        usable_capacity_kwh, tariff_price_per_kwh, night_tariff_enabled,
        night_tariff_price_per_kwh, night_tariff_start_hour, night_tariff_end_hour,
        currency_symbol, target_soc, last_observed_at, summary_version,
        pending_stop_count, estimated_cost, spot_estimated_cost,
        wallbox_charger_id, wallbox_session_key, wallbox_key_kind, wallbox_energy_kwh,
        wallbox_energy_source, wallbox_measured_at, wallbox_started_at, wallbox_ended_at,
        wallbox_peak_kw, wallbox_cost, wallbox_partial_cost, wallbox_cost_method,
        wallbox_price_source, wallbox_cost_assumptions, wallbox_missing_kwh,
        wallbox_currency, wallbox_attribution
        """
}
