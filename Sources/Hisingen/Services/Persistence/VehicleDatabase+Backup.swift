import Foundation

extension VehicleDatabase {
    /// Complete local-history export as one JSON document – every table for every vehicle.
    /// Intended for backup/migration between Macs. Coordinates are included only when the
    /// caller explicitly opts in, mirroring the location-history preference elsewhere.
    /// Note: this is a snapshot for humans/backup tooling; there is deliberately no import,
    /// to keep a tampered file from injecting fake telemetry.
    func exportBackupJSON(includeCoordinates: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        var payload: [String: Any] = [
            "schema": "hisingen-backup-v1",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "includesCoordinates": includeCoordinates,
        ]

        if includeCoordinates {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: true)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(includeCoordinates: true)))
        } else {
            payload["chargingSessions"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupChargingSessions(includeCoordinates: false)))
            payload["telemetry"] = try JSONSerialization.jsonObject(
                with: encoder.encode(backupTelemetry(includeCoordinates: false)))
        }
        payload["chargingSamples"] = try JSONSerialization.jsonObject(
            with: encoder.encode(chargingSamplesAll()))
        payload["batteryHealth"] = try JSONSerialization.jsonObject(
            with: encoder.encode(batteryHealthHistoryAll()))
        payload["airQuality"] = try JSONSerialization.jsonObject(
            with: encoder.encode(airQualityAll()))
        payload["tyrePressure"] = try JSONSerialization.jsonObject(
            with: encoder.encode(tyrePressureAll()))
        payload["warningEvents"] = try JSONSerialization.jsonObject(
            with: encoder.encode(warningEventsAll()))
        payload["remoteCommands"] = try JSONSerialization.jsonObject(
            with: encoder.encode(commandAuditsAll()))
        payload["connectivity"] = try JSONSerialization.jsonObject(
            with: encoder.encode(connectivityAll()))
        payload["cabinClimate"] = try JSONSerialization.jsonObject(
            with: encoder.encode(cabinClimateAll()))
        payload["fuelEntries"] = try JSONSerialization.jsonObject(
            with: encoder.encode(fuelEntriesAll()))
        return try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Backup internals

    private struct BackupSession: Encodable {
        let vin: String
        let startedAt: String
        let endedAt: String?
        let startSoc: Double
        let endSoc: Double?
        let energyKwh: Double
        let peakKw: Double
        let averageKw: Double
        let locationName: String?
        let lifecycle: String
        let completionReason: String?
        let energySource: String
        let confidence: String
        let sampleCoverage: Double?
        let usableCapacityKwh: Double?
        let tariffPricePerKwh: Double?
        let nightTariffEnabled: Bool
        let nightTariffPricePerKwh: Double?
        let nightTariffStartHour: Int?
        let nightTariffEndHour: Int?
        let estimatedCost: Double?
        let currency: String?
        let targetSoc: Double?
        let summaryVersion: Int
    }

    private func backupChargingSessions(includeCoordinates: Bool) throws -> [BackupSession] {
        let sql = """
        SELECT vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
               peak_power_kw, average_power_kw, location_name, lifecycle_state,
               completion_reason, energy_source, confidence, sample_coverage,
               usable_capacity_kwh, tariff_price_per_kwh, night_tariff_enabled,
               night_tariff_price_per_kwh, night_tariff_start_hour,
               night_tariff_end_hour, estimated_cost, currency_symbol, target_soc,
               summary_version
        FROM charging_sessions ORDER BY started_at DESC;
        """
        let df = ISO8601DateFormatter()
        return try db.query(sql: sql) { _ in } process: { stmt -> [BackupSession] in
            var out: [BackupSession] = []
            while try stmt.stepOrThrow() {
                guard let vin = stmt.columnText(at: 0), let startedAt = stmt.columnDate(at: 1),
                      let startSoc = stmt.columnDouble(at: 3) else { continue }
                out.append(BackupSession(
                    vin: vin,
                    startedAt: df.string(from: startedAt),
                    endedAt: stmt.columnDate(at: 2).map { df.string(from: $0) },
                    startSoc: startSoc,
                    endSoc: stmt.columnDouble(at: 4),
                    energyKwh: stmt.columnDouble(at: 5) ?? 0,
                    peakKw: stmt.columnDouble(at: 6) ?? 0,
                    averageKw: stmt.columnDouble(at: 7) ?? 0,
                    locationName: includeCoordinates ? stmt.columnText(at: 8) : nil,
                    lifecycle: stmt.columnText(at: 9) ?? "legacy",
                    completionReason: stmt.columnText(at: 10),
                    energySource: stmt.columnText(at: 11) ?? "legacy_estimate",
                    confidence: stmt.columnText(at: 12) ?? "low",
                    sampleCoverage: stmt.columnDouble(at: 13),
                    usableCapacityKwh: stmt.columnDouble(at: 14),
                    tariffPricePerKwh: stmt.columnDouble(at: 15),
                    nightTariffEnabled: (stmt.columnInt64(at: 16) ?? 0) != 0,
                    nightTariffPricePerKwh: stmt.columnDouble(at: 17),
                    nightTariffStartHour: stmt.columnInt64(at: 18).map(Int.init),
                    nightTariffEndHour: stmt.columnInt64(at: 19).map(Int.init),
                    estimatedCost: stmt.columnDouble(at: 20),
                    currency: stmt.columnText(at: 21),
                    targetSoc: stmt.columnDouble(at: 22),
                    summaryVersion: Int(stmt.columnInt64(at: 23) ?? 1)
                ))
            }
            return out
        }
    }

    private struct BackupTelemetry: Encodable {
        let vin: String
        let timestamp: String
        let odometerKm: Double?
        let averageConsumption: Double?
        let unit: String?
        let ambientTempC: Double?
        let latitude: Double?
        let longitude: Double?
    }

    private func backupTelemetry(includeCoordinates: Bool) throws -> [BackupTelemetry] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.telemetry)
        FROM telemetry_logs ORDER BY timestamp DESC;
        """
        let df = ISO8601DateFormatter()
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.telemetry).map { row in
                // Coordinates are dropped here rather than at the query, which is where the
                // guarantee has always lived: `includeCoordinates` decides what reaches the
                // file, and the file is what leaves the machine.
                BackupTelemetry(
                    vin: row.vin, timestamp: df.string(from: row.timestamp),
                    odometerKm: row.odometerKm,
                    averageConsumption: row.averageConsumption,
                    unit: row.averageConsumptionUnit,
                    ambientTempC: row.ambientTemperatureCelsius,
                    latitude: includeCoordinates ? row.latitude : nil,
                    longitude: includeCoordinates ? row.longitude : nil
                )
            }
        }
    }

    private func chargingSamplesAll() throws -> [HistoricalChargingSample] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.chargingSample)
        FROM charging_samples ORDER BY timestamp ASC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.chargingSample)
        }
    }

    private func connectivityAll() throws -> [ConnectivityRecord] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.connectivity)
        FROM connectivity_history ORDER BY timestamp DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.connectivity)
        }
    }

    private func cabinClimateAll() throws -> [CabinClimateRecord] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.cabinClimate)
        FROM cabin_climate_history ORDER BY timestamp DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.cabinClimate)
        }
    }

    private func tyrePressureAll() throws -> [TyrePressureRecord] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.tyrePressure)
        FROM tyre_pressure_history ORDER BY timestamp DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.tyrePressure)
        }
    }

    private func warningEventsAll() throws -> [WarningEventRecord] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.warningEvent)
        FROM vehicle_warning_events ORDER BY first_seen DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.warningEvent)
        }
    }

    private func fuelEntriesAll() throws -> [FuelEntry] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.fuelEntry)
        FROM fuel_entries ORDER BY date DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.fuelEntry)
        }
    }

    private struct BackupBatteryHealth: Encodable {
        let vin: String
        let timestamp: String
        let odometerKm: Double
        let stateOfHealthPct: Double
        let degradationPct: Double
        let effectiveUsableKwh: Double
        let measurementSource: String
    }

    private func batteryHealthHistoryAll() throws -> [BackupBatteryHealth] {
        try batteryHealthHistoryAllRows().map { row in
            BackupBatteryHealth(
                vin: row.vin, timestamp: Format.iso8601.string(from: row.timestamp),
                odometerKm: row.odometerKm, stateOfHealthPct: row.stateOfHealthPct,
                degradationPct: row.degradationPct, effectiveUsableKwh: row.effectiveUsableKwh,
                measurementSource: row.measurementSource)
        }
    }

    private func batteryHealthHistoryAllRows() throws -> [BatteryHealthRecord] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.batteryHealth)
        FROM battery_health_history
        WHERE \(BatteryHealthRecord.measurementSourceFilter)
        ORDER BY timestamp DESC;
        """
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.batteryHealth)
        }
    }

    private struct BackupAirQuality: Encodable {
        let vin: String
        let timestamp: String
        let aqi: Double?
        let pm25: Double?
        let pm10: Double?
        let filterPercent: Double?
    }

    private func airQualityAll() throws -> [BackupAirQuality] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.airQuality)
        FROM air_quality_history ORDER BY timestamp DESC;
        """
        let df = ISO8601DateFormatter()
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.airQuality).map { row in
                BackupAirQuality(
                    vin: row.vin, timestamp: df.string(from: row.timestamp),
                    aqi: row.airQualityIndex, pm25: row.particulateMatter25,
                    pm10: row.particulateMatter10, filterPercent: row.filterRemainingPercent)
            }
        }
    }

    private struct BackupCommandAudit: Encodable {
        let vin: String
        let command: String
        let status: String
        let executedAt: String
        let durationMs: Int?
        let errorMessage: String?
    }

    private func commandAuditsAll() throws -> [BackupCommandAudit] {
        let sql = """
        SELECT \(HistoryRowDecoder.Columns.commandAudit)
        FROM remote_commands_log ORDER BY executed_at DESC;
        """
        let iso = ISO8601DateFormatter()
        return try db.query(sql: sql) { _ in } process: { stmt in
            try HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.commandAudit).map { row in
                BackupCommandAudit(
                    vin: row.vin, command: row.command, status: row.status,
                    executedAt: iso.string(from: row.executedAt),
                    durationMs: row.durationMs, errorMessage: row.errorMessage)
            }
        }
    }
}
