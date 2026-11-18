import Foundation
import Testing
@testable import Hisingen

private let base = Date(timeIntervalSince1970: 1_780_000_000)
private let vin = "YSMTEST"

private func candidate(
    key: String = "ha:NX1234567:1780000000", kind: HomeChargingSessionCandidate.KeyKind = .history,
    start: Double = 0, end: Double = 135, kwh: Double = 16.2, measuredAfter: Double? = nil,
    intervals: Bool = true
) -> HomeChargingSessionCandidate {
    let steps = 9
    let span = (end - start) / Double(steps)
    let list = intervals ? (0..<steps).map { index in
        HomeEnergyInterval(start: base.addingTimeInterval((start + span * Double(index)) * 60),
                           end: base.addingTimeInterval((start + span * Double(index + 1)) * 60), kwh: kwh / Double(steps))
    } : []
    return HomeChargingSessionCandidate(
        key: key, keyKind: kind, chargerID: "NX1234567",
        startedAt: base.addingTimeInterval(start * 60), endedAt: base.addingTimeInterval(end * 60),
        energyKwh: kwh, energySource: kind == .captureID ? "ha_durable_capture" : "ha_session_energy_sensor",
        measuredAt: base.addingTimeInterval((measuredAfter ?? end) * 60), intervals: list, peakPowerKw: 7.3)
}

private let fixedCost = HomeSessionCost(
    method: .intervalTibber, amount: 7.74, partialAmount: nil, pricedKwh: 16.2, missingKwh: 0,
    priceSource: HomeSessionPricer.tibberSource, assumptions: ["No variable network fee is set, so none is added"], currency: "kr")

private func ingestVehicleCharge(_ ledger: ChargingSessionLedger, vin: String, from startMinute: Double, to endMinute: Double,
                                 startSoc: Double = 40, endSoc: Double = 78) {
    let configuration = ChargingSessionLedgerConfiguration(usableCapacityKwh: 75, tariffPricePerKwh: 2.0, currencySymbol: "kr", locationName: "Home")
    func observe(_ minute: Double, soc: Double, state: ChargingState, power: Double?) {
        ledger.ingest(ChargingSessionObservation(
            vin: vin, timestamp: base.addingTimeInterval(minute * 60), soc: soc, chargingState: state,
            chargerConnection: .connected, powerKw: power, voltageVolts: nil, currentAmps: nil,
            chargingType: .ac, targetSoc: 80), configuration: configuration, recordingEnabled: true)
    }
    observe(startMinute, soc: startSoc, state: .charging, power: 7.2)
    observe((startMinute + endMinute) / 2, soc: (startSoc + endSoc) / 2, state: .charging, power: 7.2)
    observe(endMinute, soc: endSoc, state: .complete, power: nil)
}

@Suite("Wallbox measurements on the charging history row")
struct HomeWallboxLedgerTests {
    @Test("Importing the same session again, after a reconnect or a sleep, never adds a second row")
    func repeatedImportsDoNotDuplicate() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        let first = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home"))
        #expect(first.kind == .inserted)
        for _ in 0..<3 {
            let again = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home"))
            #expect(again.kind == .unchanged)
            #expect(again.rowID == first.rowID)
        }
        #expect(ledger.wallboxSessionCount(chargerID: "NX1234567") == 1)
        #expect(ledger.recentChargingSessions(for: vin).count == 1)
    }

    @Test func nexBluePauseAndResumeKeepSeparateMetersUnderOneVehicleSession() throws {
        let ledger = VehicleDatabase.inMemory().charging
        ingestVehicleCharge(ledger, vin: vin, from: 0, to: 135)
        let observed = try #require(ledger.observedVehicleSessions(from: base, to: base.addingTimeInterval(135 * 60)).first)
        let decision = HomeSessionAttribution.Decision.enrich(rowID: observed.id, vin: vin)
        let first = candidate(key: "nexblue:first", kind: .vendorWindow, start: 0, end: 50, kwh: 6)
        let resumed = candidate(key: "nexblue:resumed", kind: .vendorWindow, start: 50, end: 135, kwh: 10)
        #expect(ledger.recordWallboxSession(first, decision: decision, cost: nil, locationName: "Home")?.kind == .enriched)
        #expect(ledger.recordWallboxSession(resumed, decision: decision, cost: nil, locationName: "Home")?.kind == .inserted)
        for session in [first, resumed] {
            #expect(ledger.recordWallboxSession(session, decision: decision, cost: nil, locationName: "Home")?.kind == .unchanged)
        }
        let corrected = candidate(key: "nexblue:corrected", kind: .vendorWindow, start: 50, end: 137, kwh: 11)
        #expect(ledger.recordWallboxSession(corrected, decision: decision, cost: nil, locationName: "Home")?.kind == .updated)
        #expect(ledger.recordWallboxSession(resumed, decision: decision, cost: nil, locationName: "Home")?.kind == .unchanged)
        var revisedEnergy = corrected
        revisedEnergy.energyKwh = 10.8
        #expect(ledger.recordWallboxSession(revisedEnergy, decision: decision, cost: nil, locationName: "Home")?.kind == .updated)
        #expect(ledger.recordWallboxSession(revisedEnergy, decision: decision, cost: nil, locationName: "Home")?.kind == .unchanged)
        let amounts = ledger.recentChargingSessions(for: vin).compactMap(\.wallbox?.energyKwh)
        #expect(amounts.sorted() == [6, 10.8])
    }

    @Test("A later sync with fresher figures updates the row in place")
    func refreshedFiguresUpdateInPlace() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        let first = try #require(ledger.recordWallboxSession(candidate(end: 100, kwh: 12.0), decision: decision, cost: nil, locationName: "Home"))
        let second = try #require(ledger.recordWallboxSession(candidate(end: 135, kwh: 16.2, measuredAfter: 140), decision: decision,
                                                              cost: fixedCost, locationName: "Home"))
        #expect(second.kind == .updated)
        #expect(second.rowID == first.rowID)
        let row = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(row.wallbox?.energyKwh == 16.2)
        #expect(row.wallbox?.cost == 7.74)
        #expect(ledger.wallboxSessionCount(chargerID: "NX1234567") == 1)
    }

    @Test("The same charge seen through two sources is one row and keeps the stronger key")
    func twoSourcesJoinOnOverlap() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        let history = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: nil, locationName: "Home"))
        // The capture component timestamps the start a minute earlier: a different key, the same charge.
        let capture = candidate(key: "capture:NX1234567:c0ffee01", kind: .captureID, start: -1, end: 136, kwh: 16.25)
        let joined = try #require(ledger.recordWallboxSession(capture, decision: decision, cost: nil, locationName: "Home"))
        #expect(joined.kind == .merged)
        #expect(joined.rowID == history.rowID)
        #expect(ledger.wallboxSessionCount(chargerID: "NX1234567") == 1)
        let row = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(row.wallbox?.sessionKey == "capture:NX1234567:c0ffee01")
        #expect(row.wallbox?.keyKind == "ha_capture_id")
        // The weaker source arriving afterwards does not displace it, nor create another row.
        let weakerAgain = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: nil, locationName: "Home"))
        #expect(weakerAgain.kind == .merged)
        #expect(ledger.wallboxSessionCount(chargerID: "NX1234567") == 1)
        #expect(try #require(ledger.recentChargingSessions(for: vin).first).wallbox?.keyKind == "ha_capture_id")
    }

    @Test("The vehicle's own record is enriched in place, and the two energy figures stay apart")
    func enrichesTheVehicleRow() throws {
        let ledger = VehicleDatabase.inMemory().charging
        ingestVehicleCharge(ledger, vin: vin, from: 2, to: 130)
        let before = try #require(ledger.recentChargingSessions(for: vin).first)
        let observed = ledger.observedVehicleSessions(from: base, to: base.addingTimeInterval(135 * 60))
        #expect(observed.count == 1)
        let decision = HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(shared: true), observed: observed)
        #expect(decision == .enrich(rowID: before.id, vin: vin))

        let result = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home"))
        #expect(result.kind == .enriched)
        #expect(result.rowID == before.id)
        let rows = ledger.recentChargingSessions(for: vin)
        #expect(rows.count == 1)
        let after = try #require(rows.first)
        #expect(after.wallbox?.energyKwh == 16.2)
        #expect(after.wallbox?.attribution == "overlap")
        // The battery-side estimate and the vehicle's SoC are untouched.
        #expect(after.energyDeliveredKwh == before.energyDeliveredKwh)
        #expect(after.startSoc == 40)
        #expect(after.endSoc == before.endSoc)
        #expect(after.energySource == before.energySource)
    }

    @Test("A shared charger's session with no overlapping vehicle charge stays unassigned and out of any vehicle's history")
    func sharedChargerStaysUnassigned() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let pairing = NexBlueFixture.pairing(shared: true)
        let decision = HomeSessionAttribution.decide(candidate: candidate(), pairing: pairing, observed: [])
        let result = try #require(ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home"))
        #expect(result.kind == .inserted)
        #expect(ledger.recentChargingSessions(for: vin).isEmpty)
        let unassigned = ledger.unassignedWallboxSessions(chargerID: "NX1234567")
        #expect(unassigned.count == 1)
        #expect(unassigned.first?.vin == "")
        #expect(unassigned.first?.wallbox?.attribution == "unassigned_shared_charger")
        // Syncing again does not duplicate it either.
        _ = ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home")
        #expect(ledger.unassignedWallboxSessions(chargerID: "NX1234567").count == 1)
    }

    @Test("A charge that overlaps a different vehicle's is unassigned")
    func overlapWithOtherVehicle() throws {
        let ledger = VehicleDatabase.inMemory().charging
        ingestVehicleCharge(ledger, vin: "YSMOTHER", from: 5, to: 125)
        let observed = ledger.observedVehicleSessions(from: base, to: base.addingTimeInterval(135 * 60))
        let decision = HomeSessionAttribution.decide(candidate: candidate(), pairing: NexBlueFixture.pairing(), observed: observed)
        #expect(decision == .unassigned(.overlapsAnotherVehicle))
        _ = ledger.recordWallboxSession(candidate(), decision: decision, cost: nil, locationName: "Home")
        #expect(ledger.recentChargingSessions(for: vin).isEmpty)
        #expect(ledger.recentChargingSessions(for: "YSMOTHER").first?.wallbox == nil)
    }

    @Test("A dedicated charger's session recorded with no battery reading is kept without inventing percentages")
    func noBatteryReading() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let decision = HomeSessionAttribution.Decision.newForVehicle(vin: vin)
        _ = ledger.recordWallboxSession(candidate(), decision: decision, cost: fixedCost, locationName: "Home")
        let row = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(row.energySource == .wallboxOnly)
        #expect(row.energyDeliveredKwh == 0)
        #expect(row.wallbox?.energyKwh == 16.2)
        let domain = ledger.domainSession(from: row, usableCapacityKwh: 75)
        #expect(!domain.hasBatteryReading)
        #expect(domain.samples.isEmpty)
        #expect(domain.resolvedCost(policy: .fixed, fallbackPricePerKwh: 2) == 7.74)
        let csv = ledger.exportChargingSessionsCSV(for: vin)
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(WallboxCSV.header.joined(separator: ",")))
        let cells = lines[1].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        #expect(cells[4] == "")   // Start SoC is blank, not -1
        #expect(cells.contains("16.200"))
        #expect(cells.contains("interval_tibber_15min"))
        #expect(cells.contains("ha_session_energy_sensor"))
    }

    @Test("The cost, its method, the price source and the assumptions travel with the row and into the export")
    func costProvenanceIsStored() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let estimate = HomeSessionCost(method: .totalFixedTariff, amount: 32.4, partialAmount: nil, pricedKwh: 16.2, missingKwh: 0,
                                       priceSource: HomeSessionPricer.tariffSource, assumptions: ["typed-in price used as entered"], currency: "kr")
        _ = ledger.recordWallboxSession(candidate(intervals: false), decision: .newForVehicle(vin: vin), cost: estimate, locationName: "Home")
        let wallbox = try #require(ledger.recentChargingSessions(for: vin).first?.wallbox)
        #expect(wallbox.costMethod == "total_fixed_tariff")
        #expect(wallbox.isEstimatedCost)
        #expect(wallbox.priceSource == HomeSessionPricer.tariffSource)
        #expect(wallbox.costAssumptions == ["typed-in price used as entered"])
        let presentation = WallboxSessionPresentation(wallbox, currencyFallback: "kr")
        #expect(presentation.costLabel == L10n.text("Estimated Electricity Cost"))
        #expect(presentation.costInfo?.contains(HomeSessionPricer.tariffSource) == true)
    }

    @Test("An incomplete price shows what is missing and never a zero")
    func incompleteCost() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let partial = HomeSessionCost(method: .intervalTibber, amount: nil, partialAmount: 5.0, pricedKwh: 10.8, missingKwh: 5.4,
                                      priceSource: HomeSessionPricer.tibberSource, assumptions: [], currency: "kr")
        _ = ledger.recordWallboxSession(candidate(), decision: .newForVehicle(vin: vin), cost: partial, locationName: "Home")
        let row = try #require(ledger.recentChargingSessions(for: vin).first)
        #expect(row.wallbox?.cost == nil)
        #expect(row.wallbox?.partialCost == 5.0)
        #expect(row.wallbox?.missingKwh == 5.4)
        let presentation = try #require(row.wallbox.map { WallboxSessionPresentation($0, currencyFallback: "kr") })
        #expect(presentation.costValue?.contains("5.40") == true || presentation.costValue?.contains("5,40") == true)
        #expect(ledger.domainSession(from: row).resolvedCost(policy: .fixed, fallbackPricePerKwh: 2) == nil)
    }

    @Test("The planning rate is the median delivered power of recent sessions, ignoring idle time")
    func rateFromRecentSessions() throws {
        func session(_ kwhPerQuarter: [Double]) -> [HomeEnergyInterval] {
            kwhPerQuarter.enumerated().map {
                HomeEnergyInterval(start: base.addingTimeInterval(Double($0.offset) * 900),
                                   end: base.addingTimeInterval(Double($0.offset + 1) * 900), kwh: $0.element)
            }
        }
        // 1.8 kWh per quarter hour is 7.2 kW; the 0.05 kWh quarters are idle (0.2 kW) and do not dilute it.
        #expect(abs((HomeChargingRate.estimate(fromSessions: [session([1.8, 1.8, 0.05, 1.8])]) ?? 0) - 7.2) < 0.001)
        let median = HomeChargingRate.estimate(fromSessions: [session([1.8, 1.8]), session([2.75, 2.75]), session([1.4, 1.4])])
        #expect(abs((median ?? 0) - 7.2) < 0.001)   // 7.2, 11.0 and 5.6 kW: the middle one
        #expect(HomeChargingRate.estimate(fromSessions: [session([0.02, 0.03])]) == nil)
        #expect(HomeChargingRate.estimate(fromSessions: []) == nil)

        let ledger = VehicleDatabase.inMemory().charging
        _ = ledger.recordWallboxSession(candidate(), decision: .newForVehicle(vin: vin), cost: nil, locationName: "Home")
        let stored = HomeChargingRate.estimate(fromSessions: ledger.recentWallboxIntervals(chargerID: "NX1234567"))
        #expect(abs((stored ?? 0) - 7.2) < 0.001)   // 16.2 kWh over 135 minutes of charging
    }

    @Test("The interval record survives for later repricing")
    func intervalsAreKept() throws {
        let ledger = VehicleDatabase.inMemory().charging
        let result = try #require(ledger.recordWallboxSession(candidate(), decision: .newForVehicle(vin: vin), cost: nil, locationName: "Home"))
        let intervals = ledger.wallboxIntervals(rowID: result.rowID)
        #expect(intervals.count == 9)
        #expect(abs(intervals.reduce(0) { $0 + $1.kwh } - 16.2) < 0.001)
    }
}

@Suite("Wallbox schema migration")
struct HomeWallboxMigrationTests {
    @Test("A fresh database carries the wallbox columns and the unique key index")
    func freshInstall() throws {
        let database = VehicleDatabase.inMemory()
        let columns = try database.charging.sql.query(sql: "PRAGMA table_info(charging_sessions);") { _ in } process: { stmt -> Set<String> in
            var names = Set<String>()
            while try stmt.stepOrThrow() { if let name = stmt.columnText(at: 1) { names.insert(name) } }
            return names
        }
        for column in ["wallbox_charger_id", "wallbox_session_key", "wallbox_energy_kwh", "wallbox_cost_method", "wallbox_attribution",
                       "wallbox_start_reason", "wallbox_stop_reason"] {
            #expect(columns.contains(column))
        }
        #expect(database.schemaVersion() == VehicleDatabase.latestSchemaVersion)
    }

    @Test("A version-six database upgrades without losing a session, and the key index forbids a duplicate")
    func upgradeKeepsHistory() throws {
        let sqlite = try SQLiteDatabase.inMemory()
        // The v6 charging table exactly as the previous release left it.
        try sqlite.execute(sql: """
            CREATE TABLE charging_sessions (
                id TEXT PRIMARY KEY NOT NULL, vin TEXT NOT NULL, started_at REAL NOT NULL, ended_at REAL,
                start_soc REAL NOT NULL, end_soc REAL, energy_delivered_kwh REAL DEFAULT 0.0,
                peak_power_kw REAL DEFAULT 0.0, average_power_kw REAL DEFAULT 0.0, location_name TEXT,
                created_at REAL NOT NULL, lifecycle_state TEXT NOT NULL DEFAULT 'active', completion_reason TEXT,
                energy_source TEXT NOT NULL DEFAULT 'soc_capacity_estimate', confidence TEXT NOT NULL DEFAULT 'low',
                sample_coverage REAL, usable_capacity_kwh REAL, tariff_price_per_kwh REAL,
                night_tariff_enabled INTEGER NOT NULL DEFAULT 0, night_tariff_price_per_kwh REAL,
                night_tariff_start_hour INTEGER, night_tariff_end_hour INTEGER, currency_symbol TEXT, target_soc REAL,
                last_observed_at REAL, summary_version INTEGER NOT NULL DEFAULT 2,
                pending_stop_count INTEGER NOT NULL DEFAULT 0, estimated_cost REAL, spot_estimated_cost REAL
            );
            INSERT INTO charging_sessions (id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh, created_at,
                lifecycle_state, energy_source, summary_version)
            VALUES ('legacy-1', 'YSMTEST', 1780000000, 1780007200, 30, 70, 30.0, 1780000000, 'completed', 'soc_capacity_estimate', 2);
            PRAGMA user_version = 6;
            """)
        let database = VehicleDatabase(database: sqlite)
        #expect(database.schemaVersion() == VehicleDatabase.latestSchemaVersion)
        let legacy = try #require(database.charging.recentChargingSessions(for: vin).first)
        #expect(legacy.id == "legacy-1")
        #expect(legacy.energyDeliveredKwh == 30.0)
        #expect(legacy.wallbox == nil)

        // Enrich the legacy row, then try to write the same key onto a second row.
        let enrich = HomeSessionAttribution.Decision.enrich(rowID: "legacy-1", vin: vin)
        _ = database.charging.recordWallboxSession(candidate(), decision: enrich, cost: nil, locationName: "Home")
        #expect(throws: (any Error).self) {
            try sqlite.execute(sql: """
                INSERT INTO charging_sessions (id, vin, started_at, start_soc, created_at, wallbox_session_key)
                VALUES ('dup', 'YSMTEST', 1790000000, 10, 1790000000, 'ha:NX1234567:1780000000');
                """)
        }
    }
}
