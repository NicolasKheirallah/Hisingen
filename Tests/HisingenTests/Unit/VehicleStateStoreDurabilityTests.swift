import Foundation
import Testing
@testable import Hisingen

/// The durable half of `VehicleStateStore.save(_:)`.
///
/// These assertions are the point of the split: a read straight after a save has to see what
/// was saved, with no polling helper and no race window. Before the split the snapshot write
/// sat behind a coalescing utility queue, so every read-after-write in the suite had to poll
/// for up to five seconds — an interface whose contract its own tests could not state.
@MainActor
struct VehicleStateStoreDurabilityTests {
    private struct Fixture {
        let store: VehicleStateStore
        let database: VehicleDatabase
        let suiteName: String
        let defaults: UserDefaults
    }

    private func makeStore() throws -> Fixture {
        let suiteName = "HisingenTests.VehicleStateStoreDurability.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let database = VehicleDatabase.inMemory()
        return Fixture(
            store: VehicleStateStore(defaults: defaults, database: database),
            database: database,
            suiteName: suiteName,
            defaults: defaults
        )
    }

    private func cleanUp(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
    }

    @Test
    func saveIsReadableThroughSnapshotImmediately() async throws {
        let fixture = try makeStore()
        defer { cleanUp(fixture) }
        let state = vehicle(vin: "YSM-DURABLE", battery: 64, brand: .polestar)

        fixture.store.save(state)

        // No await, no awaitStored: the authoritative row is written before `save` returned.
        let read = try #require(fixture.store.snapshot(for: "YSM-DURABLE"))
        #expect(read.identity.vin == state.identity.vin)
        #expect(read.energy.batteryPercentage == 64)
    }

    @Test
    func aSecondSaveReplacesTheFirstInPlace() async throws {
        let fixture = try makeStore()
        defer { cleanUp(fixture) }

        fixture.store.save(vehicle(vin: "YSM-DURABLE", battery: 40, brand: .polestar))
        fixture.store.save(vehicle(vin: "YSM-DURABLE", battery: 91, brand: .polestar))

        let read = try #require(fixture.store.snapshot(for: "YSM-DURABLE"))
        #expect(read.energy.batteryPercentage == 91)
    }

    @Test
    func savingOneVehicleLeavesAnotherReadable() async throws {
        let fixture = try makeStore()
        defer { cleanUp(fixture) }

        fixture.store.save(vehicle(vin: "YSM-ALPHA", battery: 30, brand: .polestar))
        fixture.store.save(vehicle(vin: "YSM-BETA", battery: 70, brand: .polestar))

        #expect(fixture.store.snapshot(for: "YSM-ALPHA")?.energy.batteryPercentage == 30)
        #expect(fixture.store.snapshot(for: "YSM-BETA")?.energy.batteryPercentage == 70)
    }

    /// The derived history tiers are deliberately *not* durable on return — they coalesce on a
    /// utility queue, which is what `drainHistory()` exists for.
    @Test
    func derivedHistoryWaitsForTheDrain() async throws {
        let fixture = try makeStore()
        defer { cleanUp(fixture) }
        var state = vehicle(vin: "YSM-HISTORY", battery: 55, brand: .polestar)
        state.maintenance.odometerKm = 12_345

        fixture.store.save(state)
        await fixture.store.drainHistory()

        let telemetry = fixture.database.history.recentTelemetry(for: "YSM-HISTORY")
        #expect(telemetry.contains { $0.odometerKm == 12_345 })
    }
}
