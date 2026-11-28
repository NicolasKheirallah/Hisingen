import Foundation
import Testing
@testable import Hisingen

@MainActor
struct VehicleHistoryRecorderTests {
    @Test
    func recordPersistsTheSnapshotBeforeDerivingLaterHistory() async throws {
        let suite = "HisingenTests.VehicleHistoryRecorder.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let recorder = VehicleHistoryRecorder(
            database: database,
            preferences: PreferencesStore(defaults: defaults)
        )
        let state = vehicle(vin: "YSM-HISTORY", battery: 72, brand: .polestar)

        recorder.saveAuthoritative(state)
        recorder.record(state)
        await recorder.drain()

        let snapshot = try #require(database.snapshots.loadSnapshot(for: state.identity.vin))
        #expect(snapshot.identity.vin == state.identity.vin)
        #expect(snapshot.energy.batteryPercentage == state.energy.batteryPercentage)
        #expect(snapshot.freshness.isCached)
    }

    @Test
    func stateOfHealthUpdatesOnlyFromAFullChargeSnapshot() async throws {
        let suite = "HisingenTests.VehicleHistoryRecorder.SoH.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let recorder = VehicleHistoryRecorder(
            database: database,
            preferences: PreferencesStore(defaults: defaults)
        )
        var state = vehicle(vin: "YSM-SOH", battery: 100, brand: .polestar)
        state.maintenance.odometerKm = 10_000

        recorder.saveAuthoritative(state)
        recorder.record(state)
        await recorder.drain()
        let saved = try #require(database.history.batteryHealthHistory(for: state.identity.vin).first)
        #expect(saved.measurementSource == BatteryHealthRecord.fullChargeRangeSource)

        state.energy.batteryPercentage = 80
        state.energy.rangeKm = 50
        state.maintenance.odometerKm = 11_000
        recorder.saveAuthoritative(state)
        recorder.record(state)
        await recorder.drain()

        let history = database.history.batteryHealthHistory(for: state.identity.vin)
        #expect(history.count == 1)
        #expect(history.first?.stateOfHealthPct == saved.stateOfHealthPct)
    }

    @Test(arguments: [nil as Double?, 10, 11])
    func chargePlaceUsesThePairedLocationWhenPositionIsKnown(latitude: Double?) async throws {
        let suite = "HisingenTests.VehicleHistoryRecorder.Place.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.storeChargingHistory = true
        let database = VehicleDatabase.inMemory()
        let recorder = VehicleHistoryRecorder(database: database, preferences: preferences)
        let vin = "YSM-CHARGE-PLACE"
        let home = ChargeLocationSnapshot(
            id: "paired-home", alias: "Garage", latitude: 10, longitude: 10, ampLimit: 16, minimumSoc: 0,
            optimisedChargingEnabled: false, optimisedChargingMode: 0, kind: ChargeLocationKind.saved.rawValue
        )
        let work = ChargeLocationSnapshot(
            id: "saved-work", alias: "Work", latitude: 11, longitude: 10, ampLimit: 16, minimumSoc: 0,
            optimisedChargingEnabled: false, optimisedChargingMode: 0, kind: ChargeLocationKind.saved.rawValue
        )
        let store = HomeChargingStore(defaults: defaults, keychain: preferences.keychain)
        store.pairings = [HomeChargingPairing(
            baseURL: "", chargerID: "wallbox", chargerName: "Garage", entities: HomeChargerEntityMap(),
            vin: vin, locationID: home.id, locationAlias: home.alias
        )]
        var state = vehicle(
            vin: vin, state: .charging, connection: .connected, chargingType: .ac,
            powerWatts: 11_000, location: latitude.map { VehicleLocation(latitude: $0, longitude: 10) }
        )
        state.energy.locations = [home, work]
        state.chargeLocationPresence = ChargeLocationPresence.resolve(
            location: state.location, locations: state.energy.locations, previous: nil
        )

        recorder.record(state)
        await recorder.drain()

        let session = try #require(database.charging.activeChargingSession(for: vin))
        #expect(session.place == (latitude == 11 ? .publicCharging : .home))
    }
}
