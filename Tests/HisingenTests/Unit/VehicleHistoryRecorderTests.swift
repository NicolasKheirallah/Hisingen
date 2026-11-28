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
    func historyRecordsReportedVehicleReadingsWithoutBatteryPercentage() async {
        let database = VehicleDatabase.inMemory()
        let preferences = ScopedPreferences(label: "ICEHistory")
        let recorder = VehicleHistoryRecorder(database: database, preferences: preferences.store)
        let vin = "YV1-ICE-HISTORY"
        var state = vehicle(vin: vin, battery: nil, brand: .volvo,
                            climateStatus: .init(activity: .idle, timeRemainingMinutes: nil,
                                                 timerTriggered: false, interiorTemperatureCelsius: 19))
        state.connectivity = .init(state: .connected, networkType: "LTE", signalBars: 3)
        state.softwareInfo = .init(version: "3.1", state: .downloaded)

        recorder.record(state)
        await recorder.drain()

        #expect(database.history.recentConnectivity(for: vin).first?.signalBars == 3)
        #expect(database.history.recentCabinClimate(for: vin).first?.interiorCelsius == 19)
        #expect(database.history.metrics(for: vin, metric: .softwareVersion).first?.text == "3.1")
        #expect(database.history.metrics(for: vin, metric: .batteryLevel).isEmpty)
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
}
