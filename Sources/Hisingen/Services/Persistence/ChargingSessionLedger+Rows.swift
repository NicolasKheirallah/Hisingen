import Foundation

extension ChargingSessionLedger {
    // MARK: - Row mapping

    /// Shared column mapping for the `charging_sessions` SELECT shape used by every session
    /// query (previously duplicated in four readers with drift risk).
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
            spotEstimatedCost: stmt.columnDouble(at: 28)
        )
    }

    static let chargingSessionColumns = """
        id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
        peak_power_kw, average_power_kw, location_name, created_at, lifecycle_state,
        completion_reason, energy_source, confidence, sample_coverage,
        usable_capacity_kwh, tariff_price_per_kwh, night_tariff_enabled,
        night_tariff_price_per_kwh, night_tariff_start_hour, night_tariff_end_hour,
        currency_symbol, target_soc, last_observed_at, summary_version,
        pending_stop_count, estimated_cost, spot_estimated_cost
        """
}
