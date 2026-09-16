import Foundation

/// One row → one record, defined once per history table.
///
/// Every history table is read from more than one direction: a per-VIN read, a cross-vehicle
/// read behind CSV export and the JSON backup, and a row count. Each direction owns its own
/// `WHERE` clause, and that is the only thing it should own — the mapping from column index to
/// record field is a single rule, and it was written two or three times per table, in different
/// files. A schema change therefore had to be applied to the reader *and* remembered in the
/// backup, with nothing making the two agree. The failure mode is silent: the reader is fixed,
/// the backup keeps reading the old index, and the exported file is wrong in a way no test
/// covered.
///
/// `ChargingSessionLedger` already had the right shape (`chargingSessionColumns` plus
/// `sessionRow(from:)`); this module gives the remaining history tables that shape and, unlike
/// the session table, shares the decoder with the backup so the two cannot drift apart.
///
/// Callers compose their query from the canonical column list and hand the statement to the
/// matching decoder:
///
/// ```swift
/// let query = """
/// SELECT \(HistoryRowDecoder.Columns.telemetry)
/// FROM telemetry_logs WHERE vin = ? AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?;
/// """
/// ```
enum HistoryRowDecoder {

    /// Canonical `SELECT` column lists, in the exact order the matching decoder reads them.
    ///
    /// The list and the decoder sit next to each other deliberately: together they are the rule
    /// for what a row of that table is. A caller that adds a column here must add it to the
    /// decoder in the same edit.
    enum Columns {
        static let batteryHealth = """
            id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct,
            effective_usable_kwh, measurement_source
            """
        static let airQuality = """
            id, vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10,
            filter_remaining_percent
            """
        static let telemetry = """
            id, vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption,
            ambient_temp_c, latitude, longitude, avg_consumption_unit
            """
        static let commandAudit = """
            id, vin, command_name, status, executed_at, duration_ms, error_message
            """
        static let connectivity = """
            id, vin, timestamp, network_type, signal_bars, wake_reason
            """
        static let cabinClimate = """
            id, vin, timestamp, interior_c, requested_c
            """
        static let fuelEntry = """
            id, vin, date, liters, price_per_liter, odometer_km
            """
        static let chargingSample = """
            id, session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps,
            charging_type
            """
    }

    // MARK: - Row drivers

    /// Decode every remaining row of an already-prepared statement.
    ///
    /// Cancellation is deliberately not consulted. Most of the callers are a backup or an
    /// export, where stopping half-way through a table would produce a truncated file that
    /// looks complete; finishing a scan the caller may discard is the safer failure.
    static func rows<T>(
        _ stmt: SQLiteStatement,
        decode: (SQLiteStatement) -> T?
    ) -> [T] {
        var out: [T] = []
        while stmt.step() {
            if let row = decode(stmt) { out.append(row) }
        }
        return out
    }

    /// Decode rows, abandoning the scan once the enclosing task is cancelled. For the large
    /// tables on an interactive read path, where a cancelled scan is thrown away anyway and
    /// holding the read lock for it is the cost worth avoiding.
    static func rowsUnlessCancelled<T>(
        _ stmt: SQLiteStatement,
        decode: (SQLiteStatement) -> T?
    ) -> [T] {
        var out: [T] = []
        while !Task.isCancelled, stmt.step() {
            if let row = decode(stmt) { out.append(row) }
        }
        return out
    }

    // MARK: - Decoders

    static func batteryHealth(_ stmt: SQLiteStatement) -> BatteryHealthRecord? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let timestamp = stmt.columnDate(at: 2),
              let odometerKm = stmt.columnDouble(at: 3),
              let stateOfHealthPct = stmt.columnDouble(at: 4),
              let degradationPct = stmt.columnDouble(at: 5),
              let effectiveUsableKwh = stmt.columnDouble(at: 6),
              let measurementSource = stmt.columnText(at: 7) else { return nil }
        return BatteryHealthRecord(
            id: id, vin: vin, timestamp: timestamp, odometerKm: odometerKm,
            stateOfHealthPct: stateOfHealthPct, degradationPct: degradationPct,
            effectiveUsableKwh: effectiveUsableKwh, measurementSource: measurementSource
        )
    }

    static func airQuality(_ stmt: SQLiteStatement) -> AirQualityRecord? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let timestamp = stmt.columnDate(at: 2) else { return nil }
        return AirQualityRecord(
            id: id, vin: vin, timestamp: timestamp,
            airQualityIndex: stmt.columnDouble(at: 3),
            particulateMatter25: stmt.columnDouble(at: 4),
            particulateMatter10: stmt.columnDouble(at: 5),
            filterRemainingPercent: stmt.columnDouble(at: 6)
        )
    }

    static func telemetry(_ stmt: SQLiteStatement) -> HistoricalTelemetryRecord? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let timestamp = stmt.columnDate(at: 2) else { return nil }
        return HistoricalTelemetryRecord(
            id: id, vin: vin, timestamp: timestamp,
            odometerKm: stmt.columnDouble(at: 3),
            tripManualKm: stmt.columnDouble(at: 4),
            tripAutomaticKm: stmt.columnDouble(at: 5),
            averageConsumption: stmt.columnDouble(at: 6),
            averageConsumptionUnit: stmt.columnText(at: 10),
            ambientTemperatureCelsius: stmt.columnDouble(at: 7),
            latitude: stmt.columnDouble(at: 8),
            longitude: stmt.columnDouble(at: 9)
        )
    }

    static func commandAudit(_ stmt: SQLiteStatement) -> RemoteCommandAuditRecord? {
        guard let id = stmt.columnText(at: 0),
              let vin = stmt.columnText(at: 1),
              let command = stmt.columnText(at: 2),
              let status = stmt.columnText(at: 3),
              let executedAt = stmt.columnDate(at: 4) else { return nil }
        return RemoteCommandAuditRecord(
            id: id, vin: vin, command: command, status: status, executedAt: executedAt,
            durationMs: stmt.columnInt64(at: 5).map(Int.init),
            errorMessage: stmt.columnText(at: 6)
        )
    }

    static func connectivity(_ stmt: SQLiteStatement) -> VehicleDatabase.ConnectivityRecord? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let timestamp = stmt.columnDate(at: 2) else { return nil }
        return VehicleDatabase.ConnectivityRecord(
            id: id, vin: vin, timestamp: timestamp,
            networkType: stmt.columnText(at: 3),
            signalBars: stmt.columnInt64(at: 4).map(Int.init),
            wakeReason: stmt.columnText(at: 5)
        )
    }

    static func cabinClimate(_ stmt: SQLiteStatement) -> VehicleDatabase.CabinClimateRecord? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let timestamp = stmt.columnDate(at: 2) else { return nil }
        return VehicleDatabase.CabinClimateRecord(
            id: id, vin: vin, timestamp: timestamp,
            interiorCelsius: stmt.columnDouble(at: 3),
            requestedCelsius: stmt.columnDouble(at: 4)
        )
    }

    static func fuelEntry(_ stmt: SQLiteStatement) -> VehicleDatabase.FuelEntry? {
        guard let id = stmt.columnInt64(at: 0),
              let vin = stmt.columnText(at: 1),
              let date = stmt.columnDate(at: 2),
              let liters = stmt.columnDouble(at: 3),
              let pricePerLiter = stmt.columnDouble(at: 4) else { return nil }
        return VehicleDatabase.FuelEntry(
            id: id, vin: vin, date: date, liters: liters, pricePerLiter: pricePerLiter,
            odometerKm: stmt.columnDouble(at: 5)
        )
    }

    static func chargingSample(_ stmt: SQLiteStatement) -> HistoricalChargingSample? {
        guard let id = stmt.columnInt64(at: 0),
              let sessionId = stmt.columnText(at: 1),
              let vin = stmt.columnText(at: 2),
              let timestamp = stmt.columnDate(at: 3),
              let soc = stmt.columnDouble(at: 4) else { return nil }
        return HistoricalChargingSample(
            id: id, sessionId: sessionId, vin: vin, timestamp: timestamp, soc: soc,
            powerKw: stmt.columnDouble(at: 5),
            voltageVolts: stmt.columnDouble(at: 6),
            currentAmps: stmt.columnDouble(at: 7),
            chargingType: stmt.columnText(at: 8)
        )
    }
}
