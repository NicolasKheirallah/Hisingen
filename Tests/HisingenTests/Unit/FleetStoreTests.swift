import Foundation
import Testing
@testable import Hisingen

@MainActor
struct FleetStoreTests {
    @Test
    func membershipIncludesDiscoveredConfiguredAndRetainedVehiclesWithoutDuplicates() {
        let fleet = FleetSnapshot(
            cars: [CarSummary(vin: "P1", title: "First"), CarSummary(vin: "P1", title: "Duplicate")],
            configuredVINs: ["", "V1", "P1", "MISSING"],
            snapshots: ["V1": vehicle(vin: "V1", brand: .volvo), "P2": vehicle(vin: "P2")])
        #expect(fleet.vehicles == ["P1", "V1", "MISSING", "P2"])
        #expect(fleet.snapshot(for: "MISSING") == nil)
        #expect(fleet.vehicles(orderedBy: ["P2", "V1"]) == ["P2", "V1", "MISSING", "P1"])
    }

    @Test
    func activeStateOverridesRetainedStateWithoutPersistingItsOptimisticValues() throws {
        let suite = "FleetStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.setVin("P1", for: .polestar)
        let database = VehicleDatabase.inMemory()
        let stateStore = VehicleStateStore(defaults: defaults, database: database, preferences: preferences)
        database.saveSnapshot(vehicle(vin: "P1", battery: 10))
        let store = FleetStore(stateStore: stateStore, preferences: preferences)
        #expect(store.snapshot().snapshot(for: "P1")?.batteryPercentage == 10)
        store.retain(vehicle(vin: "P1", battery: 20))
        let display = store.snapshot(activeState: vehicle(vin: "P1", battery: 30))
        #expect(display.snapshot(for: "P1")?.batteryPercentage == 30)
        #expect(store.snapshot(for: "P1")?.batteryPercentage == 20)
        #expect(database.loadSnapshot(for: "P1")?.batteryPercentage == 10)
    }

    @Test
    func forgettingAnAccountClearsItsRetainedSnapshotsAndPreservesTheOtherBrand() throws {
        let suite = "FleetStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        let stateStore = VehicleStateStore(defaults: defaults, database: .inMemory(), preferences: preferences)
        let store = FleetStore(stateStore: stateStore, preferences: preferences)
        store.updateCars([CarSummary(vin: "P1", title: "First")])
        store.retain(vehicle(vin: "P1"))
        store.retain(vehicle(vin: "P2"))
        store.retain(vehicle(vin: "V1", brand: .volvo))
        store.forget(brand: .polestar)
        #expect(store.snapshot().vehicles == ["V1"])
        #expect(store.snapshot(for: "P1") == nil)
        #expect(store.snapshot(for: "P2") == nil)
        #expect(store.snapshot(for: "V1")?.model.brand == .volvo)
    }
}
