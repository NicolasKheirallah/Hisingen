import Foundation
import HisingenIntents
import Testing
@testable import Hisingen
@testable import HisingenWidget

/// The per-car widget's data contract: the app's garage enumeration, the widget's
/// selection resolution, and the round trip between the two binaries. The widget UI
/// itself (Edit sheet, gallery, canvas) cannot be unit-tested — the live check for that
/// is installing the built bundle and exercising Edit mode on macOS.
///
/// The wire types have one definition in `HisingenIntents`, shared by both binaries, so
/// this suite still feeds the resolver only through the wire: the app's writer publishes,
/// the widget's `WidgetSnapshotStore` reads the files back, and never an app-side snapshot
/// passed straight into a widget-side call.
@Suite("Vehicle widget per-car selection")
@MainActor
struct VehicleWidgetGarageTests {
    /// A UUID-scoped preferences domain, mirroring the app suite's ScopedPreferences
    /// discipline without depending on that file (it belongs to the other test target).
    private final class ScopedDefaults {
        nonisolated(unsafe) let defaults: UserDefaults
        let keychain: KeychainStore
        private let suiteName: String

        init() {
            suiteName = "VehicleWidgetGarageTests.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
            keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }

        @MainActor func preferences() -> PreferencesStore {
            PreferencesStore(defaults: defaults, keychain: keychain)
        }
    }

    /// One hour ago, fixed per test instance: recent enough that a saved snapshot survives
    /// the database's own seven-day retention on read (an older `fetchedAt` makes
    /// `snapshot(for:)` legitimately answer nil), fixed enough that every expectation in the
    /// test sees one consistent time.
    private let fixedNow = Date(timeIntervalSinceNow: -3_600)

    private func fixtureState(
        vin: String,
        battery: Double? = 78.4,
        fetchedAt: Date = Date(timeIntervalSinceNow: -3_600)
    ) -> VehicleState {
        VehicleState(
            energy: EnergyAndChargingSnapshot(
                batteryPercentage: battery, rangeKm: 213, chargingState: .idle),
            identity: VehicleIdentitySnapshot(
                availability: .available, modelName: "Polestar 2", modelYear: "2023", vin: vin),
            freshness: SnapshotFreshness(isCached: false, fetchedAt: fetchedAt)
        )
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hisingen-garage-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The shared enumeration fixture: the active car, one detached car, one known car
    /// with a stored reading, one known car without any reading.
    private func garageFixture(
        preferences: PreferencesStore,
        stateStore: VehicleStateStore
    ) -> VehicleState {
        preferences.rememberKnownVINs(
            ["YV1PERSIST2", "YV1DETACHD3", "YV1UNSEEN45"], for: .polestar)
        preferences.detachVehicle(vin: "YV1DETACHD3", brand: .polestar, title: "Detached car")
        stateStore.save(fixtureState(vin: "YV1PERSIST2", battery: 61.0))
        return fixtureState(vin: "YV1ACTIVE001", battery: 84.0)
    }

    /// Publishes the two-car fixture and reads it back through the widget's own reader, so
    /// the resolver tests exercise the extension's wire path. The values here arrive only by
    /// crossing the files, which is the path the widget itself takes.
    private func publishedGarage(
        directory: URL,
        preferences: PreferencesStore,
        stateStore: VehicleStateStore
    ) throws -> (active: VehicleWidgetSnapshot, garage: [VehicleWidgetSnapshot]) {
        let activeState = garageFixture(preferences: preferences, stateStore: stateStore)
        #expect(WidgetSnapshotWriter.publish(
            activeState, preferences: preferences, now: fixedNow, directory: directory) != nil)
        #expect(WidgetSnapshotWriter.publishGarage(
            activeState: activeState, preferences: preferences, now: fixedNow,
            directory: directory, stateStore: stateStore) != nil)
        let active = try #require(WidgetSnapshotStore.load(directory: directory))
        let garage = WidgetSnapshotStore.loadGarage(directory: directory)
        #expect(garage.map(\.vin) == ["YV1ACTIVE001", "YV1PERSIST2"])
        return (active, garage)
    }

    /// The resolver tests' entry point: a published two-car garage in a scratch directory,
    /// already read back through the widget's reader.
    private func resolverFixture() throws -> (
        active: VehicleWidgetSnapshot, garage: [VehicleWidgetSnapshot]
    ) {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = ScopedDefaults()
        return try publishedGarage(
            directory: directory, preferences: scoped.preferences(),
            stateStore: VehicleStateStore(defaults: scoped.defaults, database: .inMemory()))
    }

    // MARK: garage enumeration

    @Test("the garage lists the active car first, then persisted readings, nothing else")
    func garageEnumeration() throws {
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)

        let cars = WidgetSnapshotWriter.garageCars(
            activeState: active, preferences: preferences, stateStore: stateStore, now: fixedNow)

        #expect(cars.map(\.vin) == ["YV1ACTIVE001", "YV1PERSIST2"])
        #expect(cars.map(\.batteryText) == ["84%", "61%"])
    }

    @Test("a detached car leaves the garage on the next enumeration")
    func detachedCarDropsOut() throws {
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)
        preferences.detachVehicle(vin: "YV1PERSIST2", brand: .polestar, title: "Detached too")

        let cars = WidgetSnapshotWriter.garageCars(
            activeState: active, preferences: preferences, stateStore: stateStore, now: fixedNow)

        #expect(cars.map(\.vin) == ["YV1ACTIVE001"])
    }

    @Test("the garage write decodes through the widget's reader and keeps the active file")
    func garageRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)

        #expect(WidgetSnapshotWriter.publish(
            active, preferences: preferences, now: fixedNow, directory: directory) != nil)
        let garage = try #require(WidgetSnapshotWriter.publishGarage(
            activeState: active, preferences: preferences, now: fixedNow,
            directory: directory, stateStore: stateStore))

        // The single-car file stays the old widget's contract, untouched by the garage.
        let activeRead = try #require(WidgetSnapshotStore.load(directory: directory))
        #expect(activeRead.vin == "YV1ACTIVE001")

        let read = WidgetSnapshotStore.loadGarage(directory: directory)
        // Same-named types on the two sides of the wire compare field by field, not
        // structurally: the display strings the app wrote must read back identical.
        #expect(read.map(\.name) == garage.cars.map(\.name))
        #expect(read.map(\.vin) == garage.cars.map(\.vin))
    }

    @Test("a garage from a newer schema is refused, not half-read")
    func futureGarageSchemaIsRefused() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let car = WidgetSnapshotWriter.snapshot(
            from: fixtureState(vin: "YV1ACTIVE001"), preferences: PreferencesStore(defaults: ScopedDefaults().defaults),
            now: fixedNow)
        // The car was built by the app's writer, so the container is the app-side type;
        // qualified because the widget target defines a same-named twin.
        let garage = VehicleWidgetGarageSnapshot(
            schemaVersion: VehicleWidgetGarageSnapshot.currentSchemaVersion + 1, cars: [car])
        try JSONEncoder().encode(garage).write(
            to: directory.appendingPathComponent(VehicleWidgetGarageSnapshot.fileName))

        #expect(WidgetSnapshotStore.loadGarage(directory: directory) == [])
    }

    // MARK: selection resolution

    @Test("an unset selection follows the active car")
    func unsetSelectionFollowsActive() throws {
        let (active, garage) = try resolverFixture()

        for selected in [nil as String?, "", "   "] {
            let outcome = VehicleWidgetSelection.resolve(
                selectedVIN: selected, active: active, garage: garage)
            #expect(outcome.snapshot?.vin == "YV1ACTIVE001")
            #expect(outcome.substitutedActiveCar == false)
        }
    }

    @Test("a configured car renders its own garage entry, case-insensitively")
    func configuredCarRenders() throws {
        let (active, garage) = try resolverFixture()

        let outcome = VehicleWidgetSelection.resolve(
            selectedVIN: "yv1persist2", active: active, garage: garage)
        #expect(outcome.snapshot?.vin == "YV1PERSIST2")
        #expect(outcome.snapshot?.batteryText == "61%")
        #expect(outcome.substitutedActiveCar == false)
    }

    @Test("a configured car missing from the garage stands in as the active car, with the note")
    func missingCarSubstitutesActive() throws {
        let (active, garage) = try resolverFixture()

        let outcome = VehicleWidgetSelection.resolve(
            selectedVIN: "YV1SOLD0099", active: active, garage: garage)
        #expect(outcome.snapshot?.vin == "YV1ACTIVE001")
        #expect(outcome.substitutedActiveCar == true)
    }

    @Test("a configured active car renders without the note when the garage file is missing")
    func configuredActiveSurvivesMissingGarage() throws {
        let (active, _) = try resolverFixture()

        let outcome = VehicleWidgetSelection.resolve(
            selectedVIN: "YV1ACTIVE001", active: active, garage: [])
        #expect(outcome.snapshot?.vin == "YV1ACTIVE001")
        #expect(outcome.substitutedActiveCar == false)
    }

    @Test("with no data at all the widget draws its placeholder")
    func signedOutDrawsPlaceholder() {
        let outcome = VehicleWidgetSelection.resolve(
            selectedVIN: "YV1ACTIVE001", active: nil, garage: [])
        #expect(outcome.snapshot == nil)
        #expect(outcome.substitutedActiveCar == false)
    }

    // MARK: provider entries

    @Test("the provider entry honors the configured VIN and deep-links it")
    func providerEntryFollowsSelection() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)
        #expect(WidgetSnapshotWriter.publish(
            active, preferences: preferences, now: fixedNow, directory: directory) != nil)
        #expect(WidgetSnapshotWriter.publishGarage(
            activeState: active, preferences: preferences, now: fixedNow,
            directory: directory, stateStore: stateStore) != nil)

        let pinned = VehicleTimelineProvider.entry(
            now: fixedNow, selectedVIN: "YV1PERSIST2", directory: directory)
        #expect(pinned.snapshot?.vin == "YV1PERSIST2")
        #expect(pinned.fallbackNote == nil)
        #expect(pinned.link.absoluteString == "hisingen://select-car?vin=YV1PERSIST2")

        // The old entry point (no selection) keeps rendering the active car.
        let unselected = VehicleTimelineProvider.entry(now: fixedNow, directory: directory)
        #expect(unselected.snapshot?.vin == "YV1ACTIVE001")
        #expect(unselected.fallbackNote == nil)
    }

    @Test("a missing configured car falls back to the active car with a note naming it")
    func providerEntryCarriesFallbackNote() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)
        #expect(WidgetSnapshotWriter.publish(
            active, preferences: preferences, now: fixedNow, directory: directory) != nil)
        #expect(WidgetSnapshotWriter.publishGarage(
            activeState: active, preferences: preferences, now: fixedNow,
            directory: directory, stateStore: stateStore) != nil)

        let entry = VehicleTimelineProvider.entry(
            now: fixedNow, selectedVIN: "YV1SOLD0099", directory: directory)
        #expect(entry.snapshot?.vin == "YV1ACTIVE001")
        // The widget tables are not bundled in the test runner, so the English key is the
        // deterministic shape of the note here.
        #expect(entry.fallbackNote == "Vehicle not on file — showing \(entry.snapshot?.name ?? "")")
        #expect(entry.link.absoluteString == "hisingen://select-car?vin=YV1ACTIVE001")
    }

    @Test("sign-out removes both files and the pinned widget draws its placeholder")
    func signOutClearsBothFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scoped = ScopedDefaults()
        let preferences = scoped.preferences()
        let stateStore = VehicleStateStore(defaults: scoped.defaults, database: .inMemory())
        let active = garageFixture(preferences: preferences, stateStore: stateStore)
        #expect(WidgetSnapshotWriter.publish(
            active, preferences: preferences, now: fixedNow, directory: directory) != nil)
        #expect(WidgetSnapshotWriter.publishGarage(
            activeState: active, preferences: preferences, now: fixedNow,
            directory: directory, stateStore: stateStore) != nil)

        WidgetSnapshotWriter.remove(directory: directory)

        #expect(WidgetSnapshotStore.load(directory: directory) == nil)
        #expect(WidgetSnapshotStore.loadGarage(directory: directory) == [])
        let entry = VehicleTimelineProvider.entry(
            now: fixedNow, selectedVIN: "YV1PERSIST2", directory: directory)
        #expect(entry.snapshot == nil)
        #expect(entry.fallbackNote == nil)
        #expect(entry.link.absoluteString == "hisingen://status")
    }
}
