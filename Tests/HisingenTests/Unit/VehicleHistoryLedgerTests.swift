import Foundation
import Testing
@testable import Hisingen

/// Round-trips through the Vehicle History ledger's interface: write with the database's
/// heartbeat-gated writers (or controlled SQL seeds where the writer stamps `now()`),
/// read back through the curated bundles and per-domain queries.
@Suite("Vehicle history ledger round-trips")
struct VehicleHistoryLedgerTests {
    private let vin = "HISTORY-LEDGER-VIN"
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    private func makeDatabase() -> VehicleDatabase { VehicleDatabase.inMemory() }

    /// `recordTelemetry` stamps each row with `now()`, so deterministic trip derivation
    /// seeds the table directly with controlled timestamps.
    private func insertTelemetry(
        _ database: VehicleDatabase, minute: Int, odometer: Double,
        consumption: Double? = 16, temperature: Double? = 20
    ) throws {
        try database.db.query(sql: """
            INSERT INTO telemetry_logs
            (vin, timestamp, odometer_km, trip_manual_km, trip_auto_km, avg_consumption, ambient_temp_c)
            VALUES (?, ?, ?, NULL, NULL, ?, ?);
            """) { statement in
            try statement.bindText(vin, at: 1)
            try statement.bindDate(start.addingTimeInterval(Double(minute * 60)), at: 2)
            try statement.bindDouble(odometer, at: 3)
            try statement.bindDouble(consumption, at: 4)
            try statement.bindDouble(temperature, at: 5)
            try statement.executeUpdate()
        } process: { _ in }
    }

    @Test("Fuel entries round-trip through reads and lifetime cost")
    func fuelRoundTrip() {
        let database = makeDatabase()
        #expect(database.addFuelEntry(vin: vin, date: start, liters: 40, pricePerLiter: 1.8, odometerKm: 42_000))
        #expect(database.addFuelEntry(vin: vin, date: start.addingTimeInterval(86_400), liters: 30, pricePerLiter: 1.9, odometerKm: 42_500))
        // A zero-litre entry is rejected at the write boundary.
        #expect(!database.addFuelEntry(vin: vin, date: start, liters: 0, pricePerLiter: 1.8, odometerKm: nil))

        let entries = database.history.recentFuelEntries(for: vin)
        #expect(entries.count == 2)
        #expect(entries.first?.liters == 30)
        #expect(abs(database.history.lifetimeFuelCost(for: vin) - (40 * 1.8 + 30 * 1.9)) < 0.001)
    }

    @Test("Telemetry heartbeat dedupes parked polls and keeps the movement")
    func telemetryRoundTrip() {
        let database = makeDatabase()
        let moved = database.recordTelemetry(
            vin: vin, odometerKm: 42_000, tripManualKm: nil, tripAutoKm: 10,
            avgConsumption: 15.5, consumptionUnit: "kwh", ambientTempC: 18,
            latitude: 57.7, longitude: 11.9)
        #expect(moved)
        // Same readings within the 24h heartbeat are dropped.
        let parked = database.recordTelemetry(
            vin: vin, odometerKm: 42_000, tripManualKm: nil, tripAutoKm: 10,
            avgConsumption: 15.5, consumptionUnit: "kwh", ambientTempC: 18,
            latitude: nil, longitude: nil)
        #expect(!parked)

        let records = database.history.recentTelemetry(for: vin)
        #expect(records.count == 1)
        #expect(records.first?.odometerKm == 42_000)
        #expect(records.first?.latitude == 57.7)
        #expect(database.history.recentTelemetry(for: "OTHER-VIN").isEmpty)
    }

    @Test("Derived trips segment moving telemetry and carry purpose tags")
    func tripsRoundTrip() throws {
        let database = makeDatabase()
        try insertTelemetry(database, minute: 0, odometer: 10_000)
        try insertTelemetry(database, minute: 5, odometer: 10_012)
        try insertTelemetry(database, minute: 10, odometer: 10_024)
        try insertTelemetry(database, minute: 15, odometer: 10_048)

        let trips = database.history.derivedTrips(for: vin)
        #expect(trips.count == 1)
        #expect(abs(trips[0].distanceKm - 48) < 0.001)

        database.setTripPurpose(.business, tripID: trips[0].id, vin: vin)
        #expect(database.history.tripPurposes(for: vin)[trips[0].id] == .business)

        database.setTripPurpose(nil, tripID: trips[0].id, vin: vin)
        #expect(database.history.tripPurposes(for: vin)[trips[0].id] == nil)

        let mileage = database.history.monthlyMileageReports(for: vin)
        #expect(mileage.count == 1)
        #expect(abs(mileage[0].totalKm - 48) < 0.001)
    }

    @Test("Connectivity and cabin climate records round-trip with heartbeats")
    func ambientRoundTrip() {
        let database = makeDatabase()
        #expect(database.recordConnectivity(vin: vin, networkType: "wifi", signalBars: 3, wakeReason: nil))
        // Unchanged inside the heartbeat window is dropped; a change writes immediately.
        #expect(!database.recordConnectivity(vin: vin, networkType: "wifi", signalBars: 3, wakeReason: nil))
        #expect(database.recordConnectivity(vin: vin, networkType: "wifi", signalBars: 3, wakeReason: "telemetry poll"))

        #expect(database.recordCabinClimate(vin: vin, interiorCelsius: 21, requestedCelsius: nil))
        #expect(!database.recordCabinClimate(vin: vin, interiorCelsius: 21, requestedCelsius: nil))

        let connectivity = database.history.recentConnectivity(for: vin)
        #expect(connectivity.count == 2)
        #expect(connectivity.first?.wakeReason == "telemetry poll")
        #expect(connectivity.last?.wakeReason == nil)
        let climate = database.history.recentCabinClimate(for: vin)
        #expect(climate.count == 1)
        #expect(climate.first?.interiorCelsius == 21)
    }

    @Test("Battery health milestones round-trip and CSV export contains the columns")
    func batteryHealthRoundTrip() throws {
        let database = makeDatabase()
        database.recordBatteryHealthMilestone(vin: vin, odometerKm: 25_000, sohPct: 97.2, degPct: 2.8, usableKwh: 75.8)

        let records = database.history.batteryHealthHistory(for: vin)
        #expect(records.count == 1)
        #expect(records.first?.stateOfHealthPct == 97.2)
        #expect(records.first?.effectiveUsableKwh == 75.8)

        let csv = database.history.exportBatteryHealthCSV(for: vin)
        #expect(csv.contains("Calculated State of Health (%)"))
        #expect(csv.contains("97.20"))
    }

    @Test("Command audits round-trip with an account-wide nil-VIN query")
    func auditsRoundTrip() throws {
        let database = makeDatabase()
        database.recordCommandAudit(vin: vin, command: "lock", status: "sent")
        database.recordCommandAudit(vin: "OTHER-VIN", command: "unlock", status: "confirmed")

        let scoped = database.history.recentCommandAudits(for: vin)
        #expect(scoped.count == 1)
        #expect(scoped.first?.command == "lock")
        let all = database.history.recentCommandAudits(for: nil, limit: 10)
        #expect(all.count == 2)

        let csv = database.history.exportCommandAuditsCSV(for: vin)
        #expect(csv.contains("lock"))
    }

    @Test("The dashboard bundle assembles records, comparisons, and truncation flags")
    func dashboardBundle() throws {
        let database = makeDatabase()
        try insertTelemetry(database, minute: 0, odometer: 5_000)
        try insertTelemetry(database, minute: 5, odometer: 5_020)
        try insertTelemetry(database, minute: 10, odometer: 5_040)

        let sessionID = database.charging.startChargingSession(
            vin: vin, startSoc: 40, location: "Home", startedAt: start,
            usableCapacityKwh: 79)
        database.charging.recordChargingSample(
            sessionId: sessionID, vin: vin, soc: 60, powerKw: 11,
            voltage: 230, current: 16, timestamp: start.addingTimeInterval(1_800))
        database.charging.completeChargingSession(
            id: sessionID, endSoc: 60, energyDeliveredKwh: 15.8,
            peakPowerKw: 11, averagePowerKw: 11,
            endedAt: start.addingTimeInterval(1_800), completionReason: .targetReached)
        database.recordCommandAudit(vin: vin, command: "lock", status: "confirmed")

        let snapshot = database.history.dashboard(
            vin: vin, range: nil, rowCap: 200, tripLimit: 100, chargingCapacity: 79)
        #expect(snapshot.trips.count == 1)
        #expect(snapshot.chargingSessions.count == 1)
        #expect(snapshot.chargingSessions.first?.energyDeliveredKwh == 15.8)
        #expect(snapshot.commands.count == 1)
        #expect(!snapshot.truncated)
        #expect(!snapshot.hasHistoryOutsideRange)
        // A row capped exactly at its limit warns that older rows exist.
        let capped = database.history.dashboard(
            vin: vin, range: nil, rowCap: 1, tripLimit: 100, chargingCapacity: 79)
        #expect(capped.truncated)
    }

    @Test("The Info bundle returns the recent record set including domain charging sessions")
    func recentBundle() throws {
        let database = makeDatabase()
        let sessionID = database.charging.startChargingSession(
            vin: vin, startSoc: 40, location: "Home", startedAt: start,
            usableCapacityKwh: 79)
        database.charging.recordChargingSample(
            sessionId: sessionID, vin: vin, soc: 55, powerKw: 11,
            voltage: nil, current: nil, timestamp: start.addingTimeInterval(600))
        database.charging.completeChargingSession(
            id: sessionID, endSoc: 55, energyDeliveredKwh: 7.9,
            peakPowerKw: 11, averagePowerKw: 11,
            endedAt: start.addingTimeInterval(600), completionReason: .stopped)

        let bundle = database.history.recent(vin: vin, chargingCapacityKwh: 79)
        #expect(bundle.recentCommands.isEmpty)
        #expect(bundle.chargingSessions.count == 1)
        #expect(bundle.chargingSessions.first?.kwhDelivered == 7.9)
        #expect(bundle.batteryHealthHistory.isEmpty)
    }

    @Test("Lifetime odometer span reads from stored telemetry endpoints")
    func odometerSpan() throws {
        let database = makeDatabase()
        try insertTelemetry(database, minute: 0, odometer: 10_000)
        try insertTelemetry(database, minute: 5, odometer: 10_100)
        #expect(database.history.lifetimeOdometerSpanKm(for: vin) == 100)
    }
}
