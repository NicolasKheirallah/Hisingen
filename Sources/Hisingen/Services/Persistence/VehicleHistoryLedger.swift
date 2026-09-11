import Foundation

/// The Vehicle History ledger — one typed read interface over the local history tables.
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
        /// selected range — lets the empty state say "nothing in this range" rather than
        /// "nothing recorded".
        var hasHistoryOutsideRange = false
        /// True when at least one query returned exactly its row cap, so a caption can warn
        /// that older rows are not shown.
        var truncated = false
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
    func dashboard(vin: String, range: ClosedRange<Date>?, rowCap: Int,
                   tripLimit: Int, chargingCapacity: Double) -> DashboardSnapshot {
        var snap = DashboardSnapshot()
        func inRange(_ date: Date) -> Bool { range.map { $0.contains(date) } ?? true }

        let rawTrips = derivedTrips(for: vin, limit: tripLimit)
        snap.trips = rawTrips.filter { inRange($0.endedAt) }
        snap.reportTrips = rawTrips
        snap.tripPurposes = tripPurposes(for: vin)

        let rawSessions = charging.recentChargingSessions(for: vin, limit: rowCap)
        snap.chargingSessions = rawSessions.map {
            charging.reconciled($0, usableCapacityKwh: chargingCapacity)
        }.filter { inRange($0.startedAt) }
        snap.anomalousSessionIDs = HistoryInsights.sessionPeakAnomalies(in: snap.chargingSessions)

        let rawCommands = recentCommandAudits(for: vin, limit: min(rowCap, 2_000))
        snap.commands = rawCommands.filter { inRange($0.executedAt) }
        let rawActivities = recentActivities(for: vin, limit: 1000)
        snap.activities = rawActivities.filter { inRange($0.timestamp) }

        let rawAir = recentAirQuality(for: vin, limit: min(rowCap, 5_000))
        snap.airQualityRecords = rawAir.filter { inRange($0.timestamp) }

        let telemetryLimit = min(rowCap, 10_000)
        let rawTelemetry = recentTelemetry(for: vin, limit: telemetryLimit)
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
            snap.thisMonth = Self.comparison(trips: rawTrips, sessions: snap.chargingSessions, in: month.current)
            snap.lastMonth = Self.comparison(trips: rawTrips, sessions: snap.chargingSessions, in: month.previous)
        }
        if let year = HistoryInsights.yearToDateWindows(calendar: calendar) {
            snap.thisYear = Self.comparison(trips: rawTrips, sessions: snap.chargingSessions, in: year.current)
            snap.lastYear = Self.comparison(trips: rawTrips, sessions: snap.chargingSessions, in: year.previous)
        }
        return snap
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
    /// Shortcuts query for "last 7 days" no longer decodes the entire table first.
    func derivedTrips(for vin: String, limit: Int = 100, since: Date? = nil) -> [TripHistoryEntry] {
        let records = Array(recentTelemetry(for: vin, limit: max(2_000, limit * 20), since: since).reversed())
        var trips: [TripHistoryEntry] = []
        var segmentStart: HistoricalTelemetryRecord?
        var segmentEnd: HistoricalTelemetryRecord?
        var segmentDistance = 0.0
        var consumptionTotal = 0.0
        var consumptionCount = 0
        var temperatureTotal = 0.0
        var temperatureCount = 0

        func appendSegment() {
            guard let start = segmentStart, let end = segmentEnd, segmentDistance >= 0.05 else { return }
            trips.append(TripHistoryEntry(
                id: "\(start.id)-\(end.id)", vin: vin,
                startedAt: start.timestamp, endedAt: end.timestamp,
                distanceKm: segmentDistance,
                averageConsumption: consumptionCount > 0 ? consumptionTotal / Double(consumptionCount) : nil,
                ambientTemperatureCelsius: temperatureCount > 0 ? temperatureTotal / Double(temperatureCount) : nil,
                startLatitude: start.latitude, startLongitude: start.longitude,
                endLatitude: end.latitude, endLongitude: end.longitude
            ))
        }

        func clearSegment() {
            segmentStart = nil
            segmentEnd = nil
            segmentDistance = 0
            consumptionTotal = 0
            consumptionCount = 0
            temperatureTotal = 0
            temperatureCount = 0
        }

        for pair in zip(records, records.dropFirst()) {
            let start = pair.0
            let end = pair.1
            let odometerDelta: Double? = {
                guard let current = start.odometerKm, let next = end.odometerKm else { return nil }
                return next - current
            }()
            let automaticDelta: Double? = {
                guard let current = start.tripAutomaticKm, let next = end.tripAutomaticKm else { return nil }
                return next >= current ? next - current : next
            }()
            let manualDelta: Double? = {
                guard let current = start.tripManualKm, let next = end.tripManualKm else { return nil }
                return next >= current ? next - current : next
            }()
            let distance = [odometerDelta, automaticDelta, manualDelta]
                .compactMap { $0 }.first(where: { $0 >= 0.05 && $0 < 2_000 })
            let gap = end.timestamp.timeIntervalSince(start.timestamp)
            guard let distance, gap > 0, gap <= 45 * 60 else {
                appendSegment()
                clearSegment()
                continue
            }
            if segmentStart == nil { segmentStart = start }
            segmentEnd = end
            segmentDistance += distance
            if let value = end.averageConsumption ?? start.averageConsumption {
                consumptionTotal += value
                consumptionCount += 1
            }
            if let value = end.ambientTemperatureCelsius ?? start.ambientTemperatureCelsius {
                temperatureTotal += value
                temperatureCount += 1
            }
        }
        appendSegment()
        return Array(trips.suffix(limit).reversed())
    }

    func tripPurposes(for vin: String) -> [String: TripPurpose] {
        let query = "SELECT trip_id, purpose FROM trip_tags WHERE vin = ?;"
        return (try? sql.query(sql: query) { stmt in
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
        SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source
        FROM battery_health_history
        WHERE vin = ? AND measurement_source IN ('full-charge-range-v1', 'calculated-v2', 'legacy-estimate')
        ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [BatteryHealthRecord] in
            var records: [BatteryHealthRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2),
                      let odo = stmt.columnDouble(at: 3),
                      let soh = stmt.columnDouble(at: 4),
                      let deg = stmt.columnDouble(at: 5),
                      let usable = stmt.columnDouble(at: 6),
                      let source = stmt.columnText(at: 7) else { continue }
                records.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable,
                    measurementSource: source
                ))
            }
            return records
        }) ?? []
    }

    func recentAirQuality(for vin: String, limit: Int = 200) -> [AirQualityRecord] {
        let query = """
        SELECT id, vin, timestamp, air_quality_index, particulate_matter_25, particulate_matter_10, filter_remaining_percent
        FROM air_quality_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [AirQualityRecord] in
            var records: [AirQualityRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                records.append(AirQualityRecord(
                    id: id, vin: vin, timestamp: ts,
                    airQualityIndex: stmt.columnDouble(at: 3),
                    particulateMatter25: stmt.columnDouble(at: 4),
                    particulateMatter10: stmt.columnDouble(at: 5),
                    filterRemainingPercent: stmt.columnDouble(at: 6)
                ))
            }
            return records
        }) ?? []
    }

    func recentTelemetry(for vin: String, limit: Int = 50, since: Date? = nil) -> [HistoricalTelemetryRecord] {
        let query = since != nil
            ? """
            SELECT id, vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit
            FROM telemetry_logs WHERE vin = ? AND timestamp >= ? ORDER BY timestamp DESC LIMIT ?;
            """
            : """
            SELECT id, vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c, latitude, longitude, avg_consumption_unit
            FROM telemetry_logs WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
            """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            if let since { try stmt.bindDate(since, at: 2) }
            try stmt.bindInt64(Int64(max(1, limit)), at: since != nil ? 3 : 2)
        } process: { stmt -> [HistoricalTelemetryRecord] in
            var records: [HistoricalTelemetryRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let rowVIN = stmt.columnText(at: 1),
                      let timestamp = stmt.columnDate(at: 2) else { continue }
                records.append(HistoricalTelemetryRecord(
                    id: id, vin: rowVIN, timestamp: timestamp,
                    odometerKm: stmt.columnDouble(at: 3),
                    tripManualKm: stmt.columnDouble(at: 4),
                    tripAutomaticKm: stmt.columnDouble(at: 5),
                    averageConsumption: stmt.columnDouble(at: 6),
                    averageConsumptionUnit: stmt.columnText(at: 10),
                    ambientTemperatureCelsius: stmt.columnDouble(at: 7),
                    latitude: stmt.columnDouble(at: 8),
                    longitude: stmt.columnDouble(at: 9)
                ))
            }
            return records
        }) ?? []
    }

    func recentCommandAudits(for vin: String?, limit: Int = 20) -> [RemoteCommandAuditRecord] {
        let filterClause = vin != nil ? "WHERE vin = ? " : ""
        let query = """
        SELECT id, vin, command_name, status, executed_at, duration_ms, error_message
        FROM remote_commands_log \(filterClause)ORDER BY executed_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            var bindIndex: Int32 = 1
            if let vin { try stmt.bindText(vin, at: bindIndex); bindIndex += 1 }
            try stmt.bindInt64(Int64(max(1, limit)), at: bindIndex)
        } process: { stmt -> [RemoteCommandAuditRecord] in
            var records: [RemoteCommandAuditRecord] = []
            while stmt.step() {
                guard let id = stmt.columnText(at: 0),
                      let rowVIN = stmt.columnText(at: 1),
                      let command = stmt.columnText(at: 2),
                      let status = stmt.columnText(at: 3),
                      let executedAt = stmt.columnDate(at: 4) else { continue }
                records.append(RemoteCommandAuditRecord(
                    id: id, vin: rowVIN, command: command, status: status,
                    executedAt: executedAt,
                    durationMs: stmt.columnInt64(at: 5).map(Int.init),
                    errorMessage: stmt.columnText(at: 6)
                ))
            }
            return records
        }) ?? []
    }

    func recentActivities(for vin: String, limit: Int = 100) -> [VehicleActivity] {
        (try? sql.query(sql: "SELECT payload FROM vehicle_activity WHERE vin = ? ORDER BY timestamp DESC, id DESC LIMIT ?;") { statement in
            try statement.bindText(vin, at: 1)
            try statement.bindInt64(Int64(min(max(limit, 1), 1000)), at: 2)
        } process: { statement in
            var result: [VehicleActivity] = []
            while statement.step() {
                if let data = statement.columnBlob(at: 0),
                   let event = try? JSONDecoder().decode(VehicleActivity.self, from: data) { result.append(event) }
            }
            return result
        }) ?? []
    }

    func recentConnectivity(for vin: String, limit: Int = 200) -> [VehicleDatabase.ConnectivityRecord] {
        let query = """
        SELECT id, vin, timestamp, network_type, signal_bars, wake_reason
        FROM connectivity_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [VehicleDatabase.ConnectivityRecord] in
            var out: [VehicleDatabase.ConnectivityRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                out.append(VehicleDatabase.ConnectivityRecord(
                    id: id, vin: vin, timestamp: ts,
                    networkType: stmt.columnText(at: 3),
                    signalBars: stmt.columnInt64(at: 4).map(Int.init),
                    wakeReason: stmt.columnText(at: 5)))
            }
            return out
        }) ?? []
    }

    func recentCabinClimate(for vin: String, limit: Int = 200) -> [VehicleDatabase.CabinClimateRecord] {
        let query = """
        SELECT id, vin, timestamp, interior_c, requested_c
        FROM cabin_climate_history WHERE vin = ? ORDER BY timestamp DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [VehicleDatabase.CabinClimateRecord] in
            var out: [VehicleDatabase.CabinClimateRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2) else { continue }
                out.append(VehicleDatabase.CabinClimateRecord(
                    id: id, vin: vin, timestamp: ts,
                    interiorCelsius: stmt.columnDouble(at: 3),
                    requestedCelsius: stmt.columnDouble(at: 4)))
            }
            return out
        }) ?? []
    }

    func recentFuelEntries(for vin: String, limit: Int = 100) -> [VehicleDatabase.FuelEntry] {
        let query = """
        SELECT id, vin, date, liters, price_per_liter, odometer_km
        FROM fuel_entries WHERE vin = ? ORDER BY date DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [VehicleDatabase.FuelEntry] in
            var out: [VehicleDatabase.FuelEntry] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0), let vin = stmt.columnText(at: 1),
                      let date = stmt.columnDate(at: 2), let liters = stmt.columnDouble(at: 3),
                      let price = stmt.columnDouble(at: 4) else { continue }
                out.append(VehicleDatabase.FuelEntry(id: id, vin: vin, date: date, liters: liters,
                                                     pricePerLiter: price,
                                                     odometerKm: stmt.columnDouble(at: 5)))
            }
            return out
        }) ?? []
    }

    /// Total spend on fuel across stored entries — the combustion half of lifetime cost.
    func lifetimeFuelCost(for vin: String) -> Double {
        var total = 0.0
        try? sql.query(sql: "SELECT COALESCE(SUM(liters * price_per_liter),0) FROM fuel_entries WHERE vin = ?;", bindings: { stmt in
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
        let query = vin != nil
            ? "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source FROM battery_health_history WHERE vin = ? AND measurement_source IN ('full-charge-range-v1', 'calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC;"
            : "SELECT id, vin, timestamp, odometer_km, state_of_health_pct, degradation_pct, effective_usable_kwh, measurement_source FROM battery_health_history WHERE measurement_source IN ('full-charge-range-v1', 'calculated-v2', 'legacy-estimate') ORDER BY timestamp DESC;"

        let records = (try? sql.query(sql: query) { stmt in
            if let vin { try stmt.bindText(vin, at: 1) }
        } process: { stmt -> [BatteryHealthRecord] in
            var list: [BatteryHealthRecord] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let vin = stmt.columnText(at: 1),
                      let ts = stmt.columnDate(at: 2),
                      let odo = stmt.columnDouble(at: 3),
                      let soh = stmt.columnDouble(at: 4),
                      let deg = stmt.columnDouble(at: 5),
                      let usable = stmt.columnDouble(at: 6),
                      let source = stmt.columnText(at: 7) else { continue }
                list.append(BatteryHealthRecord(
                    id: id, vin: vin, timestamp: ts, odometerKm: odo,
                    stateOfHealthPct: soh, degradationPct: deg, effectiveUsableKwh: usable,
                    measurementSource: source
                ))
            }
            return list
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
