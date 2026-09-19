import Foundation
import OSLog

/// The Vehicle History ledger – one typed read interface over the local history tables.
///
/// Owns every *read* over `battery_health_history`, `air_quality_history`, `telemetry_logs`,
/// `vehicle_activity`, `trip_tags`, `remote_commands_log`, `connectivity_history`,
/// `cabin_climate_history`, and `fuel_entries`, including the CSV exporters and the
/// freshness-window / row-cap policy that used to be re-derived at every call site.
/// `VehicleDatabase` keeps the schema, the heartbeat-gated writers, and the cross-table
/// operations (wipe, prune, backup, counts); `ChargingSessionLedger` owns the charging
/// tables. Charging-session reads for the Info bundle delegate to that ledger.
final class VehicleHistoryLedger: Sendable {
    private let sql: SQLiteDatabase
    private let charging: ChargingSessionLedger

    init(sql: SQLiteDatabase, charging: ChargingSessionLedger) {
        self.sql = sql
        self.charging = charging
    }

    // MARK: - Read models

    struct Comparison: Sendable {
        let distanceKm: Double
        let energyKwh: Double
        let averageConsumption: Double?
    }

    /// One dashboard refresh's worth of records, already filtered to the selected range with
    /// truncation and out-of-range bookkeeping applied.
    struct DashboardSnapshot: Sendable {
        var trips: [TripHistoryEntry] = []
        var reportTrips: [TripHistoryEntry] = []
        var tripPurposes: [String: TripPurpose] = [:]
        var chargingSessions: [HistoricalChargingSession] = []
        var commands: [RemoteCommandAuditRecord] = []
        var activities: [VehicleActivity] = []
        var airQualityRecords: [AirQualityRecord] = []
        var telemetryRecords: [HistoricalTelemetryRecord] = []
        var anomalousSessionIDs: Set<String> = []
        var thisMonth = Comparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var lastMonth = Comparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var thisYear = Comparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        var lastYear = Comparison(distanceKm: 0, energyKwh: 0, averageConsumption: nil)
        /// True when the database holds trips/sessions/commands/air-quality outside the
        /// selected range – lets the empty state say "nothing in this range" rather than
        /// "nothing recorded".
        var hasHistoryOutsideRange = false
        /// True when at least one query returned exactly its row cap, so a caption can warn
        /// that older rows are not shown.
        var truncated = false
        /// True when the store could not be read at all.
        ///
        /// The readers below are `try?` so that one unreadable table cannot take the whole tab
        /// down, but swallowing the error entirely made a locked or corrupt database look
        /// exactly like an empty one, and the UI then told the user their history had never
        /// been recorded. This is the cheap distinction between "nothing here" and "nothing
        /// here could be read".
        var storeUnreadable = false
    }

    /// Period-independent series (state of health, all-time odometer, fuel, cabin climate)
    /// loaded on their own cadence so changing the period selector doesn't re-run them.
    struct LifetimeSnapshot: Sendable {
        var batteryHealthRecords: [BatteryHealthRecord] = []
        var allTimeTelemetryRecords: [HistoricalTelemetryRecord] = []
        var fuelEntries: [VehicleDatabase.FuelEntry] = []
        var cabinClimateRecords: [VehicleDatabase.CabinClimateRecord] = []
        var lifetimeChargingEnergyKwh: Double = 0
        var lifetimeFuelCost: Double = 0
    }

    /// Everything the Info tab derives from the local store. Loaded once per VIN on a
    /// detached task so no card touches the database from inside `body`.
    struct RecentRecords: Sendable {
        var recentTelemetry: [HistoricalTelemetryRecord] = []
        var recentCommands: [RemoteCommandAuditRecord] = []
        var recentActivities: [VehicleActivity] = []
        var airQualityHistory: [AirQualityRecord] = []
        var connectivityHistory: [VehicleDatabase.ConnectivityRecord] = []
        var chargingSessions: [ChargingSession] = []
        var batteryHealthHistory: [BatteryHealthRecord] = []
    }

    // MARK: - Curated bundles

    /// Assembles the History dashboard's snapshot: trips, charging sessions, command audits,
    /// activities, and ambient histories, filtered to `range`, with derived month/year
    /// comparisons, anomaly classification, and truncation flags applied. The per-domain row
    /// caps (the `min(...)` derivations) are policy here, not per-view state.
    /// Whether the local store answers a trivial read. A schema that cannot be queried means
    /// the reads below are not evidence of an empty history.
    private func storeIsReadable() -> Bool {
        (try? self.sql.readQuery(sql: "SELECT count(*) FROM sqlite_master;") { _ in 0 }) != nil
    }

    func dashboard(vin: String, range: ClosedRange<Date>?, rowCap: Int,
                   tripLimit: Int, chargingCapacity: Double) -> DashboardSnapshot {
        var snap = DashboardSnapshot()
        snap.storeUnreadable = !storeIsReadable()
        func inRange(_ date: Date) -> Bool { range.map { $0.contains(date) } ?? true }
        let queryStart = Self.dashboardQueryStart(for: range)

        let rawTrips = derivedTrips(for: vin, limit: tripLimit, since: queryStart)
        snap.trips = rawTrips.filter { inRange($0.endedAt) }
        snap.reportTrips = rawTrips
        snap.tripPurposes = tripPurposes(for: vin)

        let rawSessions = charging.recentChargingSessions(for: vin, limit: rowCap, since: queryStart)
        let reconciledSessions = rawSessions.map {
            charging.reconciled($0, usableCapacityKwh: chargingCapacity)
        }
        // Month/YTD comparisons must cover their full calendar windows, so they run over the
        // unfiltered trips/sessions below; the range selector only scopes the card lists.
        // Comparing energy against the range-filtered sessions made a 7-day period report
        // 7 days as "month to date" and could never surface a year-over-year chip.
        snap.chargingSessions = reconciledSessions.filter { inRange($0.startedAt) }
        snap.anomalousSessionIDs = HistoryInsights.sessionPeakAnomalies(in: snap.chargingSessions)

        let rawCommands = recentCommandAudits(for: vin, limit: min(rowCap, 2_000), since: queryStart)
        snap.commands = rawCommands.filter { inRange($0.executedAt) }
        let rawActivities = recentActivities(for: vin, limit: 1000, since: queryStart)
        snap.activities = rawActivities.filter { inRange($0.timestamp) }

        let rawAir = recentAirQuality(for: vin, limit: min(rowCap, 5_000), since: queryStart)
        snap.airQualityRecords = rawAir.filter { inRange($0.timestamp) }

        let telemetryLimit = min(rowCap, 10_000)
        let rawTelemetry = recentTelemetry(for: vin, limit: telemetryLimit, since: range?.lowerBound)
        snap.telemetryRecords = rawTelemetry.filter { inRange($0.timestamp) }

        snap.truncated = rawTrips.count >= tripLimit || rawSessions.count >= rowCap
            || rawTelemetry.count >= telemetryLimit || rawActivities.count >= 1000

        snap.hasHistoryOutsideRange = rawTrips.count > snap.trips.count
            || rawSessions.count > snap.chargingSessions.count
            || rawCommands.count > snap.commands.count
            || rawAir.count > snap.airQualityRecords.count
            || rawActivities.count > snap.activities.count

        let calendar = Calendar.current
        if let month = HistoryInsights.monthToDateWindows(calendar: calendar) {
            snap.thisMonth = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: month.current)
            snap.lastMonth = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: month.previous)
        }
        if let year = HistoryInsights.yearToDateWindows(calendar: calendar) {
            snap.thisYear = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: year.current)
            snap.lastYear = Self.comparison(trips: rawTrips, sessions: reconciledSessions, in: year.previous)
        }
        return snap
    }

    /// The dashboard needs enough history for its previous-month and previous-YTD chips, but
    /// not records older than every visible/comparison window. Keeping that lower bound in SQL
    /// avoids decoding the vehicle's entire recent history and filtering it afterward.
    nonisolated static func dashboardQueryStart(
        for range: ClosedRange<Date>?, now: Date = Date(), calendar: Calendar = .current
    ) -> Date? {
        guard range != nil else { return nil }
        var starts = [range!.lowerBound]
        if let month = HistoryInsights.monthToDateWindows(now: now, calendar: calendar) {
            starts.append(month.previous.start)
        }
        if let year = HistoryInsights.yearToDateWindows(now: now, calendar: calendar) {
            starts.append(year.previous.start)
        }
        return starts.min()
    }

    func lifetime(vin: String, hasCombustionEngine: Bool) -> LifetimeSnapshot {
        var snap = LifetimeSnapshot()
        snap.batteryHealthRecords = batteryHealthHistory(for: vin, limit: 500)
        snap.allTimeTelemetryRecords = recentTelemetry(for: vin, limit: 10_000)
        snap.fuelEntries = hasCombustionEngine ? recentFuelEntries(for: vin, limit: 500) : []
        snap.cabinClimateRecords = recentCabinClimate(for: vin, limit: 2_000)
        snap.lifetimeChargingEnergyKwh = charging.lifetimeChargingEnergyKwh(for: vin)
        snap.lifetimeFuelCost = lifetimeFuelCost(for: vin)
        return snap
    }

    /// Everything the Info tab derives from the local SQLite store.
    func recent(vin: String, chargingCapacityKwh: Double?) -> RecentRecords {
        var records = RecentRecords()
        records.recentTelemetry = recentTelemetry(for: vin, limit: 40)
        records.recentCommands = recentCommandAudits(for: vin, limit: 5)
        records.recentActivities = recentActivities(for: vin, limit: 10)
        records.airQualityHistory = recentAirQuality(for: vin, limit: 500)
        records.connectivityHistory = recentConnectivity(for: vin, limit: 60)
        records.batteryHealthHistory = batteryHealthHistory(for: vin)
        records.chargingSessions = charging.recentChargingSessions(for: vin, limit: 20)
            .map { charging.domainSession(from: $0, usableCapacityKwh: chargingCapacityKwh) }
            .filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
        return records
    }

    nonisolated static func comparison(trips: [TripHistoryEntry],
                                       sessions: [HistoricalChargingSession],
                                       in interval: DateInterval) -> Comparison {
        let windowTrips = trips.filter { interval.contains($0.endedAt) }
        let windowSessions = sessions.filter { interval.contains($0.startedAt) }
        let consumption = windowTrips.compactMap { trip -> Double? in
            guard let value = trip.averageConsumption, HistoryInsights.efficiencyBounds.contains(value) else { return nil }
            return value
        }
        return Comparison(
            distanceKm: windowTrips.reduce(0) { $0 + $1.distanceKm },
            energyKwh: windowSessions.reduce(0) { $0 + $1.energyDeliveredKwh },
            averageConsumption: consumption.isEmpty ? nil : consumption.reduce(0, +) / Double(consumption.count)
        )
    }

    // MARK: - Trips

    /// Derives trips from telemetry rows. `since` pushes the lower time bound into SQL so a
    /// Shortcuts query for "last 7 days" no longer decodes the entire table first. The
    /// segmentation rules themselves live in `TripSegmentation`.
    func derivedTrips(for vin: String, limit: Int = 100, since: Date? = nil) -> [TripHistoryEntry] {
        // Four samples per requested trip is ample for the segmentation algorithm and keeps
        // the unbounded "All" view from turning 3,000 trips into a 60,000-row decode.
        let telemetryLimit = Self.telemetryRowLimit(forTripLimit: limit)
        let records = Array(recentTelemetry(for: vin, limit: telemetryLimit, since: since).reversed())
        return TripSegmentation.trips(from: records, vin: vin, limit: limit)
    }

    nonisolated static func telemetryRowLimit(forTripLimit limit: Int) -> Int {
        min(12_000, max(2_000, limit * 4))
    }

    func tripPurposes(for vin: String) -> [String: TripPurpose] {
        let query = "SELECT trip_id, purpose FROM trip_tags WHERE vin = ?;"
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), at: 1)
        } process: { stmt -> [String: TripPurpose] in
            var result: [String: TripPurpose] = [:]
            while stmt.step() {
                guard let id = stmt.columnText(at: 0),
                      let raw = stmt.columnText(at: 1),
                      let purpose = TripPurpose(rawValue: raw) else { continue }
                result[id] = purpose
            }
            return result
        }) ?? [:]
    }

    func monthlyMileageReports(for vin: String, limit: Int = 5_000,
                               calendar: Calendar = .current) -> [MonthlyMileageReport] {
        MonthlyMileageReport.build(
            from: derivedTrips(for: vin, limit: limit),
            purposes: tripPurposes(for: vin),
            calendar: calendar
        )
    }

    // MARK: - Ambient and vehicle histories

    func batteryHealthHistory(for vin: String, limit: Int = 50) -> [BatteryHealthRecord] {
        let query = """
        SELECT \(HistoryRowDecoder.Columns.batteryHealth)
        FROM battery_health_history
        WHERE vin = ? AND \(BatteryHealthRecord.measurementSourceFilter)
        ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.batteryHealth)
        }) ?? []
    }

    func recentAirQuality(for vin: String, limit: Int = 200, since: Date? = nil) -> [AirQualityRecord] {
        let dateClause = since == nil ? "" : " AND timestamp >= ?"
        let query = """
        SELECT \(HistoryRowDecoder.Columns.airQuality)
        FROM air_quality_history WHERE vin = ?\(dateClause) ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            if let since { try stmt.bindDate(since, at: 2) }
            try stmt.bindInt64(Int64(limit), at: since == nil ? 2 : 3)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.airQuality)
        }) ?? []
    }

    func recentTelemetry(for vin: String, limit: Int = 50, since: Date? = nil) -> [HistoricalTelemetryRecord] {
        let dateClause = since == nil ? "" : " AND timestamp >= ?"
        let query = """
        SELECT \(HistoryRowDecoder.Columns.telemetry)
        FROM telemetry_logs WHERE vin = ?\(dateClause) ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            if let since { try stmt.bindDate(since, at: 2) }
            try stmt.bindInt64(Int64(max(1, limit)), at: since != nil ? 3 : 2)
        } process: { stmt in
            // The largest table on the interactive path: a cancelled scan is discarded anyway.
            HistoryRowDecoder.rowsUnlessCancelled(stmt, decode: HistoryRowDecoder.telemetry)
        }) ?? []
    }

    func recentCommandAudits(for vin: String?, limit: Int = 20, since: Date? = nil) -> [RemoteCommandAuditRecord] {
        let filters = [vin == nil ? nil : "vin = ?", since == nil ? nil : "executed_at >= ?"].compactMap { $0 }
        let filterClause = filters.isEmpty ? "" : "WHERE \(filters.joined(separator: " AND ")) "
        let query = """
        SELECT \(HistoryRowDecoder.Columns.commandAudit)
        FROM remote_commands_log \(filterClause)ORDER BY executed_at DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            var bindIndex: Int32 = 1
            if let vin { try stmt.bindText(vin, at: bindIndex); bindIndex += 1 }
            if let since { try stmt.bindDate(since, at: bindIndex); bindIndex += 1 }
            try stmt.bindInt64(Int64(max(1, limit)), at: bindIndex)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.commandAudit)
        }) ?? []
    }

    func recentActivities(for vin: String, limit: Int = 100, since: Date? = nil) -> [VehicleActivity] {
        let dateClause = since == nil ? "" : " AND timestamp >= ?"
        let payloads: [Data] = (try? self.sql.readQuery(sql: "SELECT payload FROM vehicle_activity WHERE vin = ?\(dateClause) ORDER BY timestamp DESC, id DESC LIMIT ?;") { statement in
            try statement.bindText(vin, at: 1)
            if let since { try statement.bindDate(since, at: 2) }
            try statement.bindInt64(Int64(min(max(limit, 1), 1000)), at: since == nil ? 2 : 3)
        } process: { statement in
            var result: [Data] = []
            while !Task.isCancelled, statement.step() {
                if let data = statement.columnBlob(at: 0) { result.append(data) }
            }
            return result
        }) ?? []
        guard !Task.isCancelled else { return [] }
        let decoder = JSONDecoder()
        return payloads.compactMap { try? decoder.decode(VehicleActivity.self, from: $0) }
    }

    func recentConnectivity(for vin: String, limit: Int = 200) -> [VehicleDatabase.ConnectivityRecord] {
        let query = """
        SELECT \(HistoryRowDecoder.Columns.connectivity)
        FROM connectivity_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.connectivity)
        }) ?? []
    }

    func recentCabinClimate(for vin: String, limit: Int = 200) -> [VehicleDatabase.CabinClimateRecord] {
        let query = """
        SELECT \(HistoryRowDecoder.Columns.cabinClimate)
        FROM cabin_climate_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.cabinClimate)
        }) ?? []
    }

    func recentFuelEntries(for vin: String, limit: Int = 100) -> [VehicleDatabase.FuelEntry] {
        let query = """
        SELECT \(HistoryRowDecoder.Columns.fuelEntry)
        FROM fuel_entries WHERE vin = ? ORDER BY date DESC LIMIT ?;
        """
        return (try? self.sql.readQuery(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.fuelEntry)
        }) ?? []
    }

    /// Total spend on fuel across stored entries – the combustion half of lifetime cost.
    func lifetimeFuelCost(for vin: String) -> Double {
        var total = 0.0
        try? self.sql.readQuery(sql: "SELECT COALESCE(SUM(liters * price_per_liter),0) FROM fuel_entries WHERE vin = ?;", bindings: { stmt in
            try stmt.bindText(vin, at: 1)
        }, process: { stmt in
            if stmt.step() { total = stmt.columnDouble(at: 0) ?? 0 }
        })
        return total
    }

    /// First→last odometer span across stored telemetry, when both ends exist (km).
    func lifetimeOdometerSpanKm(for vin: String) -> Double? {
        let points = HistoryInsights.odometerTrend(from: recentTelemetry(for: vin, limit: 10_000))
        return HistoryInsights.distanceCovered(from: points)
    }

    // MARK: - CSV exporters

    func exportTripsCSV(for vin: String, limit: Int = 5_000) -> String {
        let trips = derivedTrips(for: vin, limit: limit)
        let formatter = ISO8601DateFormatter()
        var csv = "Trip ID,VIN,Started At,Ended At,Duration (min),Distance (km),Average Consumption,Ambient Temperature (C),Start Latitude,Start Longitude,End Latitude,End Longitude\n"
        for trip in trips {
            let values = [
                trip.id, trip.vin, formatter.string(from: trip.startedAt), formatter.string(from: trip.endedAt),
                String(format: "%.1f", trip.duration / 60), String(format: "%.2f", trip.distanceKm),
                trip.averageConsumption.map { String(format: "%.2f", $0) } ?? "",
                trip.ambientTemperatureCelsius.map { String(format: "%.1f", $0) } ?? "",
                trip.startLatitude.map { String($0) } ?? "", trip.startLongitude.map { String($0) } ?? "",
                trip.endLatitude.map { String($0) } ?? "", trip.endLongitude.map { String($0) } ?? ""
            ]
            csv += values.joined(separator: ",") + "\n"
        }
        return csv
    }

    func exportBatteryHealthCSV(for vin: String? = nil) -> String {
        let vinClause = vin == nil ? "" : "vin = ? AND "
        let query = """
        SELECT \(HistoryRowDecoder.Columns.batteryHealth)
        FROM battery_health_history
        WHERE \(vinClause)\(BatteryHealthRecord.measurementSourceFilter)
        ORDER BY timestamp DESC;
        """

        let records = (try? self.sql.query(sql: query) { stmt in
            if let vin { try stmt.bindText(vin, at: 1) }
        } process: { stmt in
            HistoryRowDecoder.rows(stmt, decode: HistoryRowDecoder.batteryHealth)
        }) ?? []

        var csv = "Record ID,VIN,Date,Odometer (km),Calculated State of Health (%),Calculated Degradation (%),Estimated Usable (kWh),Method\n"
        let df = ISO8601DateFormatter()
        for r in records {
            let date = df.string(from: r.timestamp)
            csv += "\(r.id),\(r.vin),\(date),\(String(format: "%.1f", r.odometerKm)),\(String(format: "%.2f", r.stateOfHealthPct)),\(String(format: "%.2f", r.degradationPct)),\(String(format: "%.2f", r.effectiveUsableKwh)),\(r.measurementSource)\n"
        }
        return csv
    }

    func exportAirQualityCSV(for vin: String) -> String {
        let records = recentAirQuality(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Record ID,VIN,Date,Air Quality Index,PM2.5,PM10,Filter Remaining (%)\n"
        for r in records {
            func number(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "" }
            csv += "\(r.id),\(r.vin),\(formatter.string(from: r.timestamp)),\(number(r.airQualityIndex)),\(number(r.particulateMatter25)),\(number(r.particulateMatter10)),\(number(r.filterRemainingPercent))\n"
        }
        return csv
    }

    func exportTelemetryCSV(for vin: String) -> String {
        let records = recentTelemetry(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Record ID,VIN,Date,Odometer (km),Trip Manual (km),Trip Automatic (km),Average Consumption,Ambient Temperature (C)\n"
        for record in records {
            func number(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(record.id),\(record.vin),\(formatter.string(from: record.timestamp)),\(number(record.odometerKm)),\(number(record.tripManualKm)),\(number(record.tripAutomaticKm)),\(number(record.averageConsumption)),\(number(record.ambientTemperatureCelsius))\n"
        }
        return csv
    }

    func exportCommandAuditsCSV(for vin: String) -> String {
        let records = recentCommandAudits(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        func cell(_ value: String) -> String {
            "\"\(value.replacingOccurrences(of: "\"", with: "\"\"").replacingOccurrences(of: "\n", with: " "))\""
        }
        var csv = "Command ID,VIN,Command,Status,Executed At,Duration (ms),Error\n"
        for record in records {
            csv += "\(cell(record.id)),\(record.vin),\(record.command),\(record.status),\(formatter.string(from: record.executedAt)),\(record.durationMs.map(String.init) ?? ""),\(cell(record.errorMessage ?? ""))\n"
        }
        return csv
    }

    func exportFuelEntriesCSV(for vin: String) -> String {
        let entries = recentFuelEntries(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Entry ID,VIN,Date,Litres,Price per Litre,Total,Odometer (km)\n"
        for entry in entries {
            csv += "\(entry.id),\(entry.vin),\(formatter.string(from: entry.date)),\(String(format: "%.2f", entry.liters)),\(String(format: "%.3f", entry.pricePerLiter)),\(String(format: "%.2f", entry.liters * entry.pricePerLiter)),\(entry.odometerKm.map { String(format: "%.1f", $0) } ?? "")\n"
        }
        return csv
    }

    func exportCabinClimateCSV(for vin: String) -> String {
        let records = recentCabinClimate(for: vin, limit: 10_000)
        let formatter = ISO8601DateFormatter()
        var csv = "Record ID,VIN,Date,Interior (C),Requested Setpoint (C)\n"
        for record in records {
            csv += "\(record.id),\(record.vin),\(formatter.string(from: record.timestamp)),\(record.interiorCelsius.map { String(format: "%.1f", $0) } ?? ""),\(record.requestedCelsius.map { String(format: "%.1f", $0) } ?? "")\n"
        }
        return csv
    }

}


// MARK: - Recording (writes)

// The write side of the history tables, moved here from `VehicleDatabase` so this ledger
// owns every read AND write over the tables its header names. `executeInsert` and the
// two "last reading" helpers are its own; nothing outside this file reaches them.
extension VehicleHistoryLedger {
    private var logger: Logger { AppLog.logger("database") }

    // MARK: - Recording policy

    /// Minimum spacing between recorded air-quality samples, mirroring the battery-health-
    /// milestone approach: a sample is only worth keeping if enough time has passed or the
    /// reading moved meaningfully, not on every refresh cycle.
    private static let airQualityHeartbeat: TimeInterval = 60 * 60
    private static let airQualityIndexDelta: Double = 5.0
    private static let airQualityPM25Delta: Double = 5.0
    /// Heartbeat for a vehicle that hasn't moved. Drive telemetry is only interesting when
    /// the odometer or a trip meter changes; a parked car re-reported the same figures every
    /// refresh, which is what filled this table.
    static let telemetryHeartbeat: TimeInterval = 24 * 60 * 60

    /// Whether these readings differ enough from the last stored row to be worth keeping.
    /// `nil` previous row means this VIN has no history yet, which always qualifies.
    func isBatteryHealthMilestone(sohPct: Double, odometerKm: Double,
                                  since previous: BatteryHealthRecord?,
                                  now: Date = Date()) -> Bool {
        guard let previous else { return true }
        if now.timeIntervalSince(previous.timestamp) >= VehicleDatabase.BatteryHealthMilestone.minimumInterval { return true }
        if abs(sohPct - previous.stateOfHealthPct) >= VehicleDatabase.BatteryHealthMilestone.sohDeltaPct { return true }
        if odometerKm - previous.odometerKm >= VehicleDatabase.BatteryHealthMilestone.odometerDeltaKm { return true }
        return false
    }

    @discardableResult
    func recordBatteryHealthMilestone(vin: String, odometerKm: Double,
                                      sohPct: Double, degPct: Double, usableKwh: Double,
                                      measurementSource: String = BatteryHealthRecord.calculatedSource,
                                      timestamp: Date = Date()) -> Bool {
        let previous = batteryHealthHistory(for: vin, limit: 50)
            .first { $0.measurementSource == measurementSource }
        guard isBatteryHealthMilestone(sohPct: sohPct, odometerKm: odometerKm, since: previous) else {
            return false
        }
        let sql = """
        INSERT INTO battery_health_history (vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(timestamp, at: 2)
            try stmt.bindDouble(odometerKm, at: 3)
            try stmt.bindDouble(sohPct, at: 4)
            try stmt.bindDouble(degPct, at: 5)
            try stmt.bindDouble(usableKwh, at: 6)
            try stmt.bindText(measurementSource, at: 7)
        }
    }

    private func lastAirQualitySample(for vin: String) -> (timestamp: Date, aqi: Double?, pm25: Double?)? {
        let sql = """
        SELECT timestamp, air_quality_index, particulate_matter_25
        FROM air_quality_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        return try? self.sql.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> (Date, Double?, Double?)? in
            guard stmt.step(), let ts = stmt.columnDate(at: 0) else { return nil }
            return (ts, stmt.columnDouble(at: 1), stmt.columnDouble(at: 2))
        } ?? nil
    }

    @discardableResult
    func recordAirQuality(vin: String, airQualityIndex: Double?, particulateMatter25: Double?,
                          particulateMatter10: Double?, filterRemainingPercent: Double?,
                          timestamp: Date = Date()) -> Bool {
        guard airQualityIndex != nil || particulateMatter25 != nil else { return false }
        if let last = lastAirQualitySample(for: vin),
           timestamp.timeIntervalSince(last.timestamp) < Self.airQualityHeartbeat,
           abs((airQualityIndex ?? 0) - (last.aqi ?? 0)) < Self.airQualityIndexDelta,
           abs((particulateMatter25 ?? 0) - (last.pm25 ?? 0)) < Self.airQualityPM25Delta {
            return false
        }
        let sql = """
        INSERT INTO air_quality_history (vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10, filter_remaining_percent)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(timestamp, at: 2)
            try stmt.bindDouble(airQualityIndex, at: 3)
            try stmt.bindDouble(particulateMatter25, at: 4)
            try stmt.bindDouble(particulateMatter10, at: 5)
            try stmt.bindDouble(filterRemainingPercent, at: 6)
        }
    }

    /// The odometer/trip readings of the most recent row, used to detect movement.
    private func lastTelemetryReadings(
        for vin: String
    ) -> (timestamp: Date, odometerKm: Double?, tripManualKm: Double?, tripAutoKm: Double?)? {
        let sql = """
        SELECT timestamp, odometer_km, trip_manual_km, trip_auto_km
        FROM telemetry_logs WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        return try? self.sql.query(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> (Date, Double?, Double?, Double?)? in
            guard stmt.step(), let ts = stmt.columnDate(at: 0) else { return nil }
            return (ts, stmt.columnDouble(at: 1), stmt.columnDouble(at: 2), stmt.columnDouble(at: 3))
        } ?? nil
    }

    @discardableResult
    func recordTelemetry(vin: String, odometerKm: Double?, tripManualKm: Double?,
                         tripAutoKm: Double?, avgConsumption: Double?,
                         consumptionUnit: String? = nil, ambientTempC: Double?,
                         latitude: Double?, longitude: Double?,
                         timestamp: Date = Date()) -> Bool {
        if let last = lastTelemetryReadings(for: vin),
           timestamp.timeIntervalSince(last.timestamp) < Self.telemetryHeartbeat,
           last.odometerKm == odometerKm,
           last.tripManualKm == tripManualKm,
           last.tripAutoKm == tripAutoKm {
            let previous = recentTelemetry(for: vin, limit: 2).dropFirst().first
            let lastRowFollowedMovement = previous.map {
                $0.odometerKm != last.odometerKm
                    || $0.tripManualKm != last.tripManualKm
                    || $0.tripAutomaticKm != last.tripAutoKm
            } ?? false
            if !lastRowFollowedMovement { return false }
        }
        let sql = """
        INSERT INTO telemetry_logs (vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        return executeInsert(sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(timestamp, at: 2)
            try stmt.bindDouble(odometerKm, at: 3)
            try stmt.bindDouble(tripManualKm, at: 4)
            try stmt.bindDouble(tripAutoKm, at: 5)
            try stmt.bindDouble(avgConsumption, at: 6)
            try stmt.bindDouble(ambientTempC, at: 7)
            try stmt.bindDouble(latitude, at: 8)
            try stmt.bindDouble(longitude, at: 9)
            try stmt.bindText(consumptionUnit, at: 10)
        }
    }

    func setTripPurpose(_ purpose: TripPurpose?, tripID: String, vin: String) {
        let cleanVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !tripID.isEmpty, !cleanVIN.isEmpty else { return }
        if let purpose {
            let sql = """
            INSERT INTO trip_tags (trip_id, vin, purpose, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(trip_id, vin) DO UPDATE SET
                purpose=excluded.purpose, updated_at=excluded.updated_at;
            """
            try? self.sql.query(sql: sql) { stmt in
                try stmt.bindText(tripID, at: 1)
                try stmt.bindText(cleanVIN, at: 2)
                try stmt.bindText(purpose.rawValue, at: 3)
                try stmt.bindDate(Date(), at: 4)
                try stmt.executeUpdate()
            } process: { _ in }
        } else {
            try? self.sql.query(sql: "DELETE FROM trip_tags WHERE trip_id = ? AND vin = ?;") { stmt in
                try stmt.bindText(tripID, at: 1)
                try stmt.bindText(cleanVIN, at: 2)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    func recordCommandAudit(id: String = UUID().uuidString, vin: String,
                            command: String, status: String, durationMs: Int? = nil, error: String? = nil,
                            timestamp: Date = Date()) {
        let sql = """
        INSERT INTO remote_commands_log (id, vin, command_name, status, executed_at, duration_ms, error_message)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        try? self.sql.query(sql: sql) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindText(command, at: 3)
            try stmt.bindText(status, at: 4)
            try stmt.bindDate(timestamp, at: 5)
            try stmt.bindInt64(durationMs.map(Int64.init), at: 6)
            try stmt.bindText(error, at: 7)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func updateCommandAudit(id: String, status: String, error: String? = nil) {
        let sql = """
        UPDATE remote_commands_log
        SET status = ?, error_message = COALESCE(?, error_message)
        WHERE id = ?;
        """
        try? self.sql.query(sql: sql) { stmt in
            try stmt.bindText(status, at: 1)
            try stmt.bindText(error, at: 2)
            try stmt.bindText(id, at: 3)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    @discardableResult
    func recordConnectivity(vin: String, networkType: String?, signalBars: Int?,
                            wakeReason: String?, timestamp: Date = Date()) -> Bool {
        let sql = """
        SELECT timestamp, network_type, signal_bars, wake_reason
        FROM connectivity_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;
        """
        var last: (Date, String?, Int?, String?)?
        try? self.sql.query(sql: sql) { stmt in try stmt.bindText(vin, at: 1) } process: { stmt in
            if stmt.step(), let ts = stmt.columnDate(at: 0) {
                last = (ts, stmt.columnText(at: 1), stmt.columnInt64(at: 2).map(Int.init),
                        stmt.columnText(at: 3))
            }
        }
        if let last {
            let unchanged = last.1 == networkType && last.2 == signalBars && last.3 == wakeReason
            if unchanged, timestamp.timeIntervalSince(last.0) < 60 * 60 { return false }
        }
        return executeInsert(
            "INSERT INTO connectivity_history (vin, timestamp, network_type, signal_bars, wake_reason) VALUES (?,?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(timestamp, at: 2)
            try stmt.bindText(networkType, at: 3)
            try stmt.bindInt64(signalBars.map(Int64.init), at: 4)
            try stmt.bindText(wakeReason, at: 5)
        }
    }

    @discardableResult
    func recordCabinClimate(vin: String, interiorCelsius: Double?, requestedCelsius: Double?,
                            timestamp: Date = Date()) -> Bool {
        guard interiorCelsius != nil || requestedCelsius != nil else { return false }
        let sql = "SELECT timestamp FROM cabin_climate_history WHERE vin = ? ORDER BY timestamp DESC LIMIT 1;"
        var last: Date?
        try? self.sql.query(sql: sql) { stmt in try stmt.bindText(vin, at: 1) } process: { stmt in
            if stmt.step() { last = stmt.columnDate(at: 0) }
        }
        // One row per hour is plenty for a temperature trend.
        if let last, timestamp.timeIntervalSince(last) < 60 * 60 { return false }
        return executeInsert(
            "INSERT INTO cabin_climate_history (vin, timestamp, interior_c, requested_c) VALUES (?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(timestamp, at: 2)
            try stmt.bindDouble(interiorCelsius, at: 3)
            try stmt.bindDouble(requestedCelsius, at: 4)
        }
    }

    private func executeInsert(_ sql: String, bind: (SQLiteStatement) throws -> Void) -> Bool {
        do {
            try self.sql.query(sql: sql, bindings: { stmt in
                try bind(stmt)
                try stmt.executeUpdate()
            }) { _ in }
            return true
        } catch {
            logger.error("History insert failed: \(error, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func addFuelEntry(vin: String, date: Date, liters: Double,
                      pricePerLiter: Double, odometerKm: Double?) -> Bool {
        guard liters > 0, pricePerLiter >= 0 else { return false }
        return executeInsert(
            "INSERT INTO fuel_entries (vin, date, liters, price_per_liter, odometer_km) VALUES (?,?,?,?,?);"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindDate(date, at: 2)
            try stmt.bindDouble(liters, at: 3)
            try stmt.bindDouble(pricePerLiter, at: 4)
            try stmt.bindDouble(odometerKm, at: 5)
        }
    }

    func deleteFuelEntry(id: Int64) {
        try? self.sql.query(sql: "DELETE FROM fuel_entries WHERE id = ?;") { stmt in
            try stmt.bindInt64(id, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func recordActivities(_ events: [VehicleActivity]) {
        guard !events.isEmpty else { return }
        do {
            try sql.withTransaction {
                for event in events {
                    let payload = try JSONEncoder().encode(event)
                    try self.sql.query(sql: "INSERT OR IGNORE INTO vehicle_activity(id, vin, timestamp, payload) VALUES (?, ?, ?, ?);") { statement in
                        try statement.bindText(event.id, at: 1)
                        try statement.bindText(event.vin, at: 2)
                        try statement.bindDate(event.timestamp, at: 3)
                        try statement.bindBlob(payload, at: 4)
                        try statement.executeUpdate()
                    } process: { _ in }
                }
            }
        } catch {
            logger.error("Could not save vehicle activity: \(error, privacy: .public)")
        }
    }
}
