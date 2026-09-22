import Foundation
import Testing
@testable import Hisingen

/// The workspace's interface is the test surface: every query, edit and export drives an
/// in-memory database through the same seam the panel views use, with no `VehicleDatabase`
/// held by the caller.
@MainActor
struct HistoryWorkspaceTests {
    @MainActor
    private struct Harness {
        let workspace: HistoryWorkspace
        let database: VehicleDatabase
        let preferences: PreferencesStore
        let suite: String

        init(label: String) {
            let suite = "HisingenTests.\(label).\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let database = VehicleDatabase.inMemory()
            let store = PreferencesStore(defaults: defaults,
                                         keychain: .init(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"))
            self.init(workspace: HistoryWorkspace(database: database, preferences: store),
                      database: database, preferences: store, suite: suite)
        }

        private init(workspace: HistoryWorkspace, database: VehicleDatabase,
                     preferences: PreferencesStore, suite: String) {
            self.workspace = workspace
            self.database = database
            self.preferences = preferences
            self.suite = suite
        }

        func close() {
            UserDefaults(suiteName: suite)!.removePersistentDomain(forName: suite)
        }

        /// A completed charging session with two observed samples, ended at `startedAt` + 30 min.
        @discardableResult
        func seedSession(vin: String, startedAt: Date, startSoc: Double = 40, endSoc: Double = 70,
                         energyKwh: Double = 10) -> String {
            let id = database.charging.startChargingSession(vin: vin, startSoc: startSoc, startedAt: startedAt)
            database.charging.recordChargingSample(sessionId: id, vin: vin, soc: startSoc, powerKw: 7,
                                                   voltage: nil, current: nil, timestamp: startedAt)
            database.charging.recordChargingSample(sessionId: id, vin: vin, soc: endSoc, powerKw: 7,
                                                   voltage: nil, current: nil,
                                                   timestamp: startedAt.addingTimeInterval(1_800))
            database.charging.completeChargingSession(
                id: id, endSoc: endSoc, energyDeliveredKwh: energyKwh,
                peakPowerKw: 7, averagePowerKw: 7,
                endedAt: startedAt.addingTimeInterval(1_800))
            return id
        }
    }

    private let vin = "YSMWORKSPACEVIN01"

    @Test
    func usableCapacityFollowsTheSpecificationOverride() {
        let harness = Harness(label: "workspace-capacity")
        defer { harness.close() }

        let state = vehicle(vin: vin)
        let baseline = harness.workspace.usableCapacityKwh(vin: vin, state: state)

        var override = VehicleSpecificationOverride()
        override.usableBatteryCapacityKwh = 82.0
        harness.preferences.setVehicleSpecificationOverride(override, for: vin)

        #expect(harness.workspace.usableCapacityKwh(vin: vin, state: state) == 82.0)
        #expect(baseline != 82.0)
    }

    @Test
    func dashboardReturnsSeededSessionsAndFuelEntries() async {
        let harness = Harness(label: "workspace-dashboard")
        defer { harness.close() }

        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        harness.seedSession(vin: vin, startedAt: startedAt)
        #expect(harness.workspace.addFuelEntry(vin: vin, date: startedAt, liters: 40,
                                               pricePerLiter: 1.9, odometerKm: 12_345))

        let query = HistoryWorkspace.DashboardQuery(
            vin: vin, range: nil, rowCap: 3_000, tripCap: 3_000,
            capacityKwh: 75, hasElectricRange: true, hasCombustionEngine: true,
            lifetimeKey: "t0")
        let loaded = await harness.workspace.dashboard(matching: query, loadLifetime: true,
                                                       keeping: .init())
        guard let loaded else {
            Issue.record("dashboard load returned nil without cancellation")
            return
        }

        #expect(loaded.dashboard.storeUnreadable == false)
        #expect(loaded.dashboard.chargingSessions.count == 1)
        #expect(loaded.lifetime.fuelEntries.count == 1)
    }

    @Test
    func dashboardLoadLifetimeFalseKeepsTheProvidedLifetimeSnapshot() async {
        let harness = Harness(label: "workspace-lifetime-keep")
        defer { harness.close() }

        var existing = VehicleHistoryLedger.LifetimeSnapshot()
        existing.fuelEntries = [VehicleDatabase.FuelEntry(id: 1, vin: vin, date: Date(),
                                                          liters: 30, pricePerLiter: 1.8,
                                                          odometerKm: nil)]

        let query = HistoryWorkspace.DashboardQuery(
            vin: vin, range: nil, rowCap: 3_000, tripCap: 3_000,
            capacityKwh: 75, hasElectricRange: true, hasCombustionEngine: false,
            lifetimeKey: "t1")
        let loaded = await harness.workspace.dashboard(matching: query, loadLifetime: false,
                                                       keeping: existing)
        #expect(loaded?.lifetime.fuelEntries.count == 1)
        #expect(loaded?.lifetime.batteryHealthRecords.isEmpty == true)
    }

    @Test
    func persistentChargingSessionsExcludeContentlessSessions() async {
        let harness = Harness(label: "workspace-persistent")
        defer { harness.close() }

        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        harness.seedSession(vin: vin, startedAt: startedAt, startSoc: 50, endSoc: 50, energyKwh: 0)
        let sessions = await harness.workspace.persistentChargingSessions(vin: vin, state: vehicle(vin: vin))
        #expect(sessions.isEmpty)

        harness.seedSession(vin: vin, startedAt: startedAt.addingTimeInterval(3_600),
                            startSoc: 40, endSoc: 70, energyKwh: 12)
        let filled = await harness.workspace.persistentChargingSessions(vin: vin, state: vehicle(vin: vin))
        #expect(filled.count == 1)
        #expect(filled.first?.kwhDelivered == 12)
    }

    @Test
    func sessionCurvesCarrySamplesAndOptionalPreviousOverlay() async throws {
        let harness = Harness(label: "workspace-curves")
        defer { harness.close() }

        let firstStart = Date(timeIntervalSince1970: 1_780_000_000)
        let firstID = harness.seedSession(vin: vin, startedAt: firstStart)
        let secondID = harness.seedSession(vin: vin, startedAt: firstStart.addingTimeInterval(86_400),
                                           startSoc: 30, endSoc: 80)

        let records = harness.database.charging.recentChargingSessions(for: vin)
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let second = try #require(byID[secondID])
        let first = try #require(byID[firstID])

        let curves = await harness.workspace.sessionCurves(for: second, overlaying: first)
        #expect(curves.samples.count == 2)
        #expect(curves.current.isEmpty == false)
        #expect(curves.previous.isEmpty == false)

        let alone = await harness.workspace.sessionCurves(for: second, overlaying: nil)
        #expect(alone.previous.isEmpty)
    }

    @Test
    func fuelEditRoundTripThroughTheWorkspace() async {
        let harness = Harness(label: "workspace-fuel-edit")
        defer { harness.close() }

        #expect(harness.workspace.addFuelEntry(vin: vin, date: Date(), liters: 35,
                                               pricePerLiter: 2.0, odometerKm: 10_000))
        #expect(harness.workspace.addFuelEntry(vin: vin, date: Date(), liters: 0,
                                               pricePerLiter: 2.0, odometerKm: nil) == false)

        let lifetime = harness.database.history.lifetime(vin: vin, hasCombustionEngine: true)
        guard let entry = lifetime.fuelEntries.first else {
            Issue.record("fuel entry missing after add")
            return
        }
        harness.workspace.deleteFuelEntry(id: entry.id)
        let after = harness.database.history.lifetime(vin: vin, hasCombustionEngine: true)
        #expect(after.fuelEntries.isEmpty)
    }

    @Test
    func exportCSVHonorsScopeAndKind() async {
        let harness = Harness(label: "workspace-export")
        defer { harness.close() }

        let startedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let sessionID = harness.seedSession(vin: vin, startedAt: startedAt)

        // Full history reaches the ledger; selected period formats only the rows it is given.
        let full = await harness.workspace.exportCSV(
            .chargingSessions, scope: .fullHistory, vin: vin, selectedSessionID: nil,
            periodTrips: [], periodSessions: [])
        #expect(full.contains(vin))

        let period = await harness.workspace.exportCSV(
            .chargingSessions, scope: .selectedPeriod, vin: vin, selectedSessionID: nil,
            periodTrips: [], periodSessions: [])
        #expect(!period.contains(vin))

        let samples = await harness.workspace.exportCSV(
            .sessionSamples, scope: .fullHistory, vin: vin, selectedSessionID: sessionID,
            periodTrips: [], periodSessions: [])
        #expect(samples.contains("Timestamp"))

        let emptySamples = await harness.workspace.exportCSV(
            .sessionSamples, scope: .fullHistory, vin: vin, selectedSessionID: nil,
            periodTrips: [], periodSessions: [])
        #expect(emptySamples.isEmpty)

        let battery = await harness.workspace.exportCSV(
            .batteryHealth, scope: .selectedPeriod, vin: vin, selectedSessionID: nil,
            periodTrips: [], periodSessions: [])
        #expect(battery.contains("VIN"))
    }

    @Test
    func backupExportProducesJSON() async {
        let harness = Harness(label: "workspace-backup")
        defer { harness.close() }

        harness.seedSession(vin: vin, startedAt: Date(timeIntervalSince1970: 1_780_000_000))
        let data = await harness.workspace.exportBackupJSON(includeCoordinates: false)
        #expect(data != nil)
        #expect(String(data: data ?? Data(), encoding: .utf8)?.contains(vin) == true)
    }

    @Test
    func tripPurposeWritesRoundTrip() {
        let harness = Harness(label: "workspace-trip-purpose")
        defer { harness.close() }

        harness.workspace.setTripPurpose(.business, tripID: "trip-1", vin: vin)
        #expect(harness.database.history.tripPurposes(for: vin)["trip-1"] == .business)
        harness.workspace.setTripPurpose(nil, tripID: "trip-1", vin: vin)
        #expect(harness.database.history.tripPurposes(for: vin)["trip-1"] == nil)
    }
}
