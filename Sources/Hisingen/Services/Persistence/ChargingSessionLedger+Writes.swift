import Foundation

extension ChargingSessionLedger {
    // MARK: - Session storage

    @discardableResult
    func startChargingSession(id: String = UUID().uuidString, vin: String, startSoc: Double,
                              location: String? = nil, startedAt: Date = Date(),
                              usableCapacityKwh: Double? = nil,
                              tariffPricePerKwh: Double? = nil,
                              nightTariffEnabled: Bool = false,
                              nightTariffPricePerKwh: Double? = nil,
                              nightTariffStartHour: Int? = nil,
                              nightTariffEndHour: Int? = nil,
                              currencySymbol: String? = nil,
                              targetSoc: Double? = nil,
                              lifecycleState: ChargingSessionLifecycleState = .active) -> String {
        let statement = """
        INSERT INTO charging_sessions (
            id, vin, started_at, start_soc, energy_delivered_kwh, peak_power_kw,
            average_power_kw, location_name, created_at, lifecycle_state, energy_source,
            confidence, usable_capacity_kwh, tariff_price_per_kwh, currency_symbol,
            night_tariff_enabled, night_tariff_price_per_kwh,
            night_tariff_start_hour, night_tariff_end_hour, target_soc,
            last_observed_at, summary_version, pending_stop_count
        ) VALUES (?, ?, ?, ?, 0.0, 0.0, 0.0, ?, ?, ?, 'soc_capacity_estimate',
                  'low', ?, ?, ?, ?, ?, ?, ?, ?, ?, 2, 0);
        """
        logOnFailure("session start") {
            try sql.query(sql: statement) { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.bindText(vin, at: 2)
                try stmt.bindDate(startedAt, at: 3)
                try stmt.bindDouble(startSoc, at: 4)
                try stmt.bindText(location, at: 5)
                try stmt.bindDate(startedAt, at: 6)
                try stmt.bindText(lifecycleState.rawValue, at: 7)
                try stmt.bindDouble(usableCapacityKwh, at: 8)
                try stmt.bindDouble(tariffPricePerKwh, at: 9)
                try stmt.bindText(currencySymbol, at: 10)
                try stmt.bindInt64(nightTariffEnabled ? 1 : 0, at: 11)
                try stmt.bindDouble(nightTariffPricePerKwh, at: 12)
                try stmt.bindInt64(nightTariffStartHour.map(Int64.init), at: 13)
                try stmt.bindInt64(nightTariffEndHour.map(Int64.init), at: 14)
                try stmt.bindDouble(targetSoc, at: 15)
                try stmt.bindDate(startedAt, at: 16)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        return id
    }

    func recordChargingSample(sessionId: String, vin: String, soc: Double,
                              powerKw: Double?, voltage: Double?, current: Double?,
                              chargingType: String? = nil, timestamp: Date = Date()) {
        let statement = """
        INSERT INTO charging_samples (session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        logOnFailure("sample insert") {
            try sql.query(sql: statement) { stmt in
                try stmt.bindText(sessionId, at: 1)
                try stmt.bindText(vin, at: 2)
                try stmt.bindDate(timestamp, at: 3)
                try stmt.bindDouble(soc, at: 4)
                try stmt.bindDouble(powerKw, at: 5)
                try stmt.bindDouble(voltage, at: 6)
                try stmt.bindDouble(current, at: 7)
                try stmt.bindText(chargingType, at: 8)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    func completeChargingSession(id: String, endSoc: Double, energyDeliveredKwh: Double,
                                 peakPowerKw: Double, averagePowerKw: Double,
                                 endedAt: Date = Date(),
                                 lifecycleState: ChargingSessionLifecycleState = .completed,
                                 completionReason: ChargingSessionCompletionReason = .stopped,
                                 energySource: ChargingSessionEnergySource = .socCapacityEstimate,
                                 confidence: ChargingSessionConfidence = .low,
                                 usableCapacityKwh: Double? = nil,
                                 tariffPricePerKwh: Double? = nil,
                                 nightTariffEnabled: Bool = false,
                                 nightTariffPricePerKwh: Double? = nil,
                                 nightTariffStartHour: Int? = nil,
                                 nightTariffEndHour: Int? = nil,
                                 currencySymbol: String? = nil,
                                 targetSoc: Double? = nil,
                                 sampleCoverage: Double? = nil,
                                 estimatedCost: Double? = nil) {
        let statement = """
        UPDATE charging_sessions SET
            ended_at = ?,
            end_soc = ?,
            energy_delivered_kwh = ?,
            peak_power_kw = ?,
            average_power_kw = ?, lifecycle_state = ?, completion_reason = ?,
            energy_source = ?, confidence = ?,
            sample_coverage = ?,
            usable_capacity_kwh = COALESCE(?, usable_capacity_kwh),
            tariff_price_per_kwh = COALESCE(?, tariff_price_per_kwh),
            night_tariff_enabled = ?,
            night_tariff_price_per_kwh = COALESCE(?, night_tariff_price_per_kwh),
            night_tariff_start_hour = COALESCE(?, night_tariff_start_hour),
            night_tariff_end_hour = COALESCE(?, night_tariff_end_hour),
            currency_symbol = COALESCE(?, currency_symbol),
            target_soc = COALESCE(?, target_soc), last_observed_at = ?,
            summary_version = 2, pending_stop_count = 0,
            estimated_cost = ?
        WHERE id = ?;
        """
        logOnFailure("session completion") {
            try sql.query(sql: statement) { stmt in
                try stmt.bindDate(endedAt, at: 1)
                try stmt.bindDouble(endSoc, at: 2)
                try stmt.bindDouble(energyDeliveredKwh, at: 3)
                try stmt.bindDouble(peakPowerKw, at: 4)
                try stmt.bindDouble(averagePowerKw, at: 5)
                try stmt.bindText(lifecycleState.rawValue, at: 6)
                try stmt.bindText(completionReason.rawValue, at: 7)
                try stmt.bindText(energySource.rawValue, at: 8)
                try stmt.bindText(confidence.rawValue, at: 9)
                try stmt.bindDouble(sampleCoverage, at: 10)
                try stmt.bindDouble(usableCapacityKwh, at: 11)
                try stmt.bindDouble(tariffPricePerKwh, at: 12)
                try stmt.bindInt64(nightTariffEnabled ? 1 : 0, at: 13)
                try stmt.bindDouble(nightTariffPricePerKwh, at: 14)
                try stmt.bindInt64(nightTariffStartHour.map(Int64.init), at: 15)
                try stmt.bindInt64(nightTariffEndHour.map(Int64.init), at: 16)
                try stmt.bindText(currencySymbol, at: 17)
                try stmt.bindDouble(targetSoc, at: 18)
                try stmt.bindDate(endedAt, at: 19)
                try stmt.bindDouble(estimatedCost, at: 20)
                try stmt.bindText(id, at: 21)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    func updateChargingSessionLifecycle(
        id: String, state: ChargingSessionLifecycleState, observedAt: Date,
        pendingStopCount: Int, targetSoc: Double?
    ) {
        logOnFailure("lifecycle update") {
            try sql.query(sql: """
                UPDATE charging_sessions SET lifecycle_state = ?, last_observed_at = ?,
                    pending_stop_count = ?, target_soc = COALESCE(?, target_soc)
                WHERE id = ? AND ended_at IS NULL;
                """) { stmt in
                try stmt.bindText(state.rawValue, at: 1)
                try stmt.bindDate(observedAt, at: 2)
                try stmt.bindInt64(Int64(max(0, pendingStopCount)), at: 3)
                try stmt.bindDouble(targetSoc, at: 4)
                try stmt.bindText(id, at: 5)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    func abandonChargingSession(id: String, endedAt: Date,
                                reason: ChargingSessionCompletionReason) {
        logOnFailure("abandon") {
            try sql.query(sql: """
                UPDATE charging_sessions SET ended_at = ?, lifecycle_state = 'abandoned',
                    completion_reason = ?, last_observed_at = ?, pending_stop_count = 0,
                    summary_version = 2
                WHERE id = ? AND ended_at IS NULL;
                """) { stmt in
                try stmt.bindDate(endedAt, at: 1)
                try stmt.bindText(reason.rawValue, at: 2)
                try stmt.bindDate(endedAt, at: 3)
                try stmt.bindText(id, at: 4)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    /// Removes an unfinished observation that never produced a measurable SoC gain. Keeping
    /// these rows made an interrupted poll look like a completed 0 kWh / 0 cost charge.
    func discardChargingSession(id: String) {
        logOnFailure("discard") {
            try sql.withTransaction {
                try sql.query(sql: "DELETE FROM charging_samples WHERE session_id = ?;") { stmt in
                    try stmt.bindText(id, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
                try sql.query(sql: "DELETE FROM charging_sessions WHERE id = ? AND ended_at IS NULL;") { stmt in
                    try stmt.bindText(id, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        }
    }
}
