import Foundation
import Testing
@testable import Hisingen

/// The erase sequence is one call with one ordering, so it is asserted through that call rather
/// than through each storage mechanism. The in-memory image tier is not observable through
/// `CarImageCache`'s interface, so the drop is covered by construction, not here.
@MainActor
struct LocalDataEraserTests {

    @Test
    func theSessionScopeClearsTheSnapshotAndKeepsDurableHistory() throws {
        let (eraser, database, preferences, cleanup) = try makeEraser()
        defer { cleanup() }
        let vin = "ERASER-SESSION"
        database.saveSnapshot(vehicle(vin: vin))
        seedHistory(database, vin: vin)

        try eraser.perform(.session, vin: vin)

        #expect(database.loadSnapshot(for: vin) == nil)
        #expect(database.recordCounts().chargingSessions == 1)
        _ = preferences
    }

    @Test
    func theEverythingScopeEmptiesDurableHistoryToo() throws {
        let (eraser, database, _, cleanup) = try makeEraser()
        defer { cleanup() }
        let vin = "ERASER-EVERYTHING"
        database.saveSnapshot(vehicle(vin: vin))
        seedHistory(database, vin: vin)

        try eraser.perform(.everything, vin: vin)

        #expect(database.loadSnapshot(for: vin) == nil)
        let counts = database.recordCounts()
        #expect(counts.chargingSessions == 0)
        #expect(counts.chargingSamples == 0)
    }

    @Test
    func theSamplesScopeKeepsSessionHeaders() throws {
        let (eraser, database, _, cleanup) = try makeEraser()
        defer { cleanup() }
        let vin = "ERASER-SAMPLES"
        seedHistory(database, vin: vin)

        try eraser.perform(.samples(olderThanDays: 0), vin: vin)

        let counts = database.recordCounts()
        #expect(counts.chargingSamples == 0)
        #expect(counts.chargingSessions == 1)
    }

    @Test
    func theLocationsScopeAlsoTurnsThePreferenceOff() throws {
        let (eraser, database, preferences, cleanup) = try makeEraser()
        defer { cleanup() }
        let vin = "ERASER-LOCATIONS"
        #expect(database.recordTelemetry(
            vin: vin, odometerKm: 1, tripManualKm: nil, tripAutoKm: nil,
            avgConsumption: nil, ambientTempC: nil, latitude: 57.7, longitude: 11.9))
        preferences.persistLocationHistory = true

        try eraser.perform(.locations, vin: vin)

        // The preference is what keeps cleared coordinates cleared, so it belongs to the
        // sequence rather than to the button that calls it.
        #expect(preferences.persistLocationHistory == false)
        let remaining = try database.db.query(
            sql: "SELECT latitude FROM telemetry_logs WHERE vin = ? LIMIT 1;"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> Double? in
            guard stmt.step() else { return nil }
            return stmt.columnDouble(at: 0)
        }
        #expect(remaining == nil)
    }

    private func makeEraser() throws -> (LocalDataEraser, VehicleDatabase, PreferencesStore, () -> Void) {
        let suite = "LocalDataEraserTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let preferences = PreferencesStore(defaults: defaults)
        let database = VehicleDatabase.inMemory()
        let eraser = LocalDataEraser(
            database: database, preferences: preferences, imageCache: CarImageCache())
        return (eraser, database, preferences, { defaults.removePersistentDomain(forName: suite) })
    }

    private func seedHistory(_ database: VehicleDatabase, vin: String) {
        let sessionId = database.charging.startChargingSession(vin: vin, startSoc: 20)
        database.charging.recordChargingSample(
            sessionId: sessionId, vin: vin, soc: 20, powerKw: 10, voltage: 230, current: 16)
    }
}
