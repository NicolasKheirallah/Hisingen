import Foundation
import Testing
@testable import Hisingen

/// D11: erasing a vehicle means everything keyed to that VIN – all twelve `UserDefaults`
/// stores, the SQLite rows, the image tier and the in-memory caches. D12: the fleet-wide erase
/// is a named call of its own, never the meaning of an omitted argument. A fleet-wide *sign-out*
/// is the narrower case: with no vehicle known it takes only the stores the vehicle reported,
/// because a name or a colour belongs to the reader rather than to the car. A location clear is
/// narrower still: it names the one store it invalidates.
@MainActor
struct VehicleEraseScopeTests {
    private let vinA = "YSMERASETEST00001"
    private let vinB = "YSMERASETEST00002"

    /// The vehicle-derived half of the table: what the car reported, which any erase may drop.
    /// Everything else in `perVehicleStores` is a choice the reader made about the car.
    private let vehicleDerivedKeys: Set<String> = [
        "cached_vehicle_snapshots_v1",
        "command_receipts",
        "charging_baselines",
        "planner_notified_window_ends_v2",
    ]

    /// One erase target: a scoped defaults domain, an in-memory database, and the eraser over
    /// both. The registry is per-test so a registered fake sees only this test's drops.
    @MainActor
    private final class Harness {
        let scoped = ScopedPreferences(label: "VehicleEraseScope")
        let database = VehicleDatabase.inMemory()
        let registry = VehicleMemoryCacheRegistry()
        let stateStore: VehicleStateStore
        let eraser: LocalDataEraser

        init() {
            stateStore = VehicleStateStore(
                defaults: scoped.defaults, database: database, preferences: scoped.store)
            eraser = LocalDataEraser(
                database: database, preferences: scoped.store, imageCache: CarImageCache(),
                memoryCaches: registry)
        }

        var preferences: PreferencesStore { scoped.store }
    }

    /// Every per-VIN store, read through the accessor the app itself uses. The labels are the
    /// `UserDefaults` keys on purpose: a store added to the app but not to the erase has to show
    /// up as a missing row here rather than as data that quietly survives.
    private func perVehicleStores(
        _ harness: Harness
    ) -> [(key: String, isDefaultsBacked: Bool, isPresent: (String) -> Bool)] {
        let preferences = harness.preferences
        let stateStore = harness.stateStore
        return [
            // The snapshot mirror is the one plist tier left with a key of its own here; the
            // authoritative snapshot, the baseline and the receipts are SQLite rows the accessors
            // read, so `isDefaultsBacked` is what the plist-level check below may look at.
            ("cached_vehicle_snapshots_v1", true, { self.mirroredVINs(harness).contains($0) }),
            ("command_receipts", false, { !stateStore.commandReceipts(for: $0).isEmpty }),
            ("charging_baselines", false, { stateStore.baseline(for: $0) != nil }),
            ("polestar_vehicle_nicknames_v1", true, { !preferences.vehicleNickname(for: $0).isEmpty }),
            ("planner_notified_window_ends_v2", true, { preferences.plannerNotifiedWindowEnd(for: $0) != nil }),
            ("history_selected_session_v1", true, { preferences.selectedHistorySession(for: $0) != nil }),
            ("history_hidden_trips_v1", true, { !preferences.hiddenTripIDs(for: $0).isEmpty }),
            ("vehicle_in_service_dates_v1", true, { preferences.warrantyInServiceDate(for: $0) != nil }),
            ("vehicle_specification_overrides_v1", true, { preferences.vehicleSpecificationOverride(for: $0) != nil }),
            ("dismissed_software_events_v1", true, { preferences.dismissedSoftwareEventIdentifier(for: $0) != nil }),
            ("muted_vehicle_vins_v1", true, { preferences.isMuted(vin: $0) }),
            // The Volvo brand has no `theme_for_volvo` key here, so a vehicle whose per-VIN
            // theme was erased reads back the brand default rather than the seeded theme.
            ("vehicle_themes_v1", true, { preferences.theme(for: $0, brand: .volvo) == .aurora }),
        ]
    }

    /// The legacy plist mirror, read as the VIN-keyed payload the erase is defined against. It is
    /// a legacy tier on purpose: current writers reach SQLite only, and the eraser still owns the
    /// blobs older installs left behind.
    private func mirroredVINs(_ harness: Harness) -> Set<String> {
        guard let data = harness.scoped.defaults.data(forKey: "cached_vehicle_snapshots_v1"),
              let values = try? JSONDecoder().decode([String: VehicleState].self, from: data)
        else { return [] }
        return Set(values.keys)
    }

    private func seed(_ harness: Harness, vin: String) throws {
        // Two tiers for one vehicle, on purpose. The authoritative snapshot goes in through the
        // store's own write path, which is where the app keeps it now; the legacy plist mirror is
        // written by hand because no current writer produces one, and the erase still has to
        // clear what older installs left there.
        harness.stateStore.save(vehicle(vin: vin))
        var mirrors = harness.scoped.defaults.data(forKey: "cached_vehicle_snapshots_v1")
            .flatMap { try? JSONDecoder().decode([String: VehicleState].self, from: $0) } ?? [:]
        mirrors[vin] = vehicle(vin: vin)
        harness.scoped.defaults.set(
            try JSONEncoder().encode(mirrors), forKey: "cached_vehicle_snapshots_v1")
        harness.stateStore.saveCommandReceipts(
            [StoredCommandReceipt(
                receipt: CommandReceipt(commandIdentifier: "lock", issuedAt: Date()),
                confirmationDeadline: nil)],
            for: vin)
        harness.stateStore.save(ChargingBaseline(
            vin: vin, state: .idle, connection: .disconnected, batteryPercentage: 50,
            targetPercentage: 80, vehicleReportedAt: Date(), sampledAt: Date(),
            chargingSessionActive: false, interruptionSamples: 0, lowBatteryNotified: false))
        harness.preferences.setVehicleNickname("Nickname \(vin)", for: vin)
        harness.preferences.setPlannerNotifiedWindowEnd(
            Date(timeIntervalSince1970: 1_700_000_000), for: vin)
        harness.preferences.setSelectedHistorySession("session-\(vin)", for: vin)
        harness.preferences.setTripHidden(true, id: "trip-\(vin)", for: vin)
        harness.preferences.setWarrantyInServiceDate(
            Date(timeIntervalSince1970: 1_600_000_000), for: vin)
        harness.preferences.setVehicleSpecificationOverride(
            VehicleSpecificationOverride(usableBatteryCapacityKwh: 78, wltpRangeKm: 480), for: vin)
        harness.preferences.setDismissedSoftwareEventIdentifier("software-\(vin)", for: vin)
        harness.preferences.setMuted(true, for: vin)
        harness.preferences.setTheme(.aurora, for: vin)
    }

    private func seedHistory(_ harness: Harness, vin: String) {
        let sessionId = harness.database.charging.startChargingSession(vin: vin, startSoc: 20)
        harness.database.charging.recordChargingSample(
            sessionId: sessionId, vin: vin, soc: 20, powerKw: 10, voltage: 230, current: 16)
        #expect(harness.database.addFuelEntry(
            vin: vin, date: Date(), liters: 10, pricePerLiter: 2, odometerKm: 500))
    }

    @Test
    func erasingOneVehicleEmptiesAllTwelvePerVINStoresAndKeepsTheOthers() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        let stores = perVehicleStores(harness)
        #expect(stores.count == 12, "every per-VIN store has to be covered by this erase")

        for store in stores {
            #expect(store.isPresent(vinA), "\(store.key) was not seeded for the erased vehicle")
            #expect(store.isPresent(vinB), "\(store.key) was not seeded for the kept vehicle")
        }

        try harness.eraser.perform(.everything(.vehicle(vinA)))

        for store in stores {
            #expect(!store.isPresent(vinA), "\(store.key) survived the erase")
            #expect(store.isPresent(vinB), "\(store.key) lost the untouched vehicle")
        }
    }

    @Test
    func erasingAPaddedLowercaseVINReachesTheEntryThatWasWrittenNormalized() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)

        // Every writer normalizes before storing; an erase that removes the raw VIN instead is
        // the silent no-op this covers.
        try harness.eraser.perform(.everything(.vehicle("  \(vinA.lowercased()) ")))

        #expect(harness.preferences.vehicleNickname(for: vinA).isEmpty)
        #expect(harness.preferences.theme(for: vinA, brand: .volvo) == .volvo)
        #expect(harness.preferences.isMuted(vin: vinA) == false)
        #expect(harness.preferences.selectedHistorySession(for: vinA) == nil)
        #expect(harness.preferences.vehicleNickname(for: vinB) == "Nickname \(vinB)")
        #expect(harness.preferences.theme(for: vinB, brand: .volvo) == .aurora)
        #expect(harness.preferences.isMuted(vin: vinB))

        // The store's own entry point normalizes too, for callers that never reach the eraser.
        harness.preferences.clearLocalVehicleDefaults(for: " \(vinB.lowercased()) ")
        #expect(harness.preferences.vehicleNickname(for: vinB).isEmpty)
        #expect(harness.preferences.isMuted(vin: vinB) == false)
    }

    @Test
    func aPerVehicleEraseNeverTouchesAnotherVehicle() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        seedHistory(harness, vin: vinA)
        seedHistory(harness, vin: vinB)

        try harness.eraser.perform(.everything(.vehicle(vinA)))

        let counts = harness.database.recordCounts()
        #expect(counts.chargingSessions == 1)
        #expect(counts.chargingSamples == 1)
        #expect(harness.database.history.recentFuelEntries(for: vinA).isEmpty)
        #expect(harness.database.history.recentFuelEntries(for: vinB).count == 1)
        #expect(harness.database.loadSnapshot(for: vinA) == nil)
        for store in perVehicleStores(harness) {
            #expect(store.isPresent(vinB), "\(store.key) lost the untouched vehicle")
        }
        // The accessor path last: it reads SQLite, which is where the seeded snapshot for this VIN
        // lives, and the erase has to have taken the row with the vehicle.
        #expect(harness.stateStore.snapshot(for: vinA) == nil)
        #expect(harness.stateStore.snapshot(for: vinB) != nil)
    }

    @Test
    func theFleetWideEraseIsOnlyReachableThroughItsNamedEntryPoint() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        seedHistory(harness, vin: vinB)

        // An empty VIN names no vehicle. It used to mean "every vehicle" one tier away from a
        // database delete that read it as a scoped no-op.
        try harness.eraser.perform(.everything(.vehicle("")))

        for store in perVehicleStores(harness) {
            #expect(store.isPresent(vinA), "\(store.key) read an empty VIN as every vehicle")
            #expect(store.isPresent(vinB), "\(store.key) read an empty VIN as every vehicle")
        }
        #expect(harness.database.recordCounts().chargingSessions == 1)

        // Fleet-wide erasing is the separately named entry point, and nothing else reaches it.
        harness.stateStore.clearAll(eraseHistory: true)

        for store in perVehicleStores(harness) {
            #expect(!store.isPresent(vinA), "\(store.key) survived the fleet-wide erase")
            #expect(!store.isPresent(vinB), "\(store.key) survived the fleet-wide erase")
        }
        #expect(harness.database.recordCounts().chargingSessions == 0)
        #expect(harness.database.history.recentFuelEntries(for: vinB).isEmpty)
    }

    @Test
    func aFleetWideSignOutDropsTheVehicleDerivedStoresAndKeepsTheReadersOwn() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        let stores = perVehicleStores(harness)
        #expect(stores.filter { vehicleDerivedKeys.contains($0.key) }.count == 4)

        for store in stores {
            for vin in [vinA, vinB] {
                #expect(store.isPresent(vin), "\(store.key) was not seeded for \(vin)")
            }
        }

        try harness.eraser.perform(.session(.all))

        for store in stores {
            for vin in [vinA, vinB] {
                if vehicleDerivedKeys.contains(store.key) {
                    #expect(!store.isPresent(vin), "\(store.key) survived the fleet-wide sign-out")
                } else {
                    #expect(
                        store.isPresent(vin),
                        "\(store.key) is the reader's, and a sign-out took it")
                }
            }
        }
        // The same half again, read straight off the domain rather than through the accessors:
        // a reader-authored key has to be there, not merely read back as the default.
        for key in stores.map(\.key) where !vehicleDerivedKeys.contains(key) {
            #expect(
                harness.scoped.defaults.object(forKey: key) != nil,
                "\(key) is the reader's, and a sign-out took it")
        }
    }

    @Test
    func theFleetWideEraseActionTakesTheReadersOwnStoresToo() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)

        try harness.eraser.perform(.everything(.all))

        // The reader asked for every vehicle to be gone, so the reader-authored half goes with
        // them: a name that outlives its vehicle is the half-erase that action rules out.
        for store in perVehicleStores(harness) {
            #expect(!store.isPresent(vinA), "\(store.key) survived the fleet-wide erase")
            #expect(!store.isPresent(vinB), "\(store.key) survived the fleet-wide erase")
        }
    }

    @Test
    func signingOutAKnownVehicleStillTakesAllTwelveForThatVehicleAlone() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)

        // That vehicle's session genuinely ended and it is the vehicle the reader acted on, so
        // the reader-authored stores go too – for that VIN only.
        try harness.eraser.perform(.session(.vehicle(vinA)))

        for store in perVehicleStores(harness) {
            #expect(
                !store.isPresent(vinA),
                "\(store.key) survived the sign-out of the vehicle it belongs to")
            #expect(store.isPresent(vinB), "\(store.key) lost the untouched vehicle")
        }
    }

    @Test
    func theFleetWideLocationScopeClearsEveryVehiclesCoordinates() throws {
        let harness = Harness()
        #expect(harness.database.recordTelemetry(
            vin: vinA, odometerKm: 1, tripManualKm: nil, tripAutoKm: nil,
            avgConsumption: nil, ambientTempC: nil, latitude: 57.7, longitude: 11.9))
        #expect(harness.database.recordTelemetry(
            vin: vinB, odometerKm: 2, tripManualKm: nil, tripAutoKm: nil,
            avgConsumption: nil, ambientTempC: nil, latitude: 59.3, longitude: 18.1))

        // Its own scope, because the location toggle's dialog can only clear a loaded vehicle.
        try harness.eraser.perform(.locations(.all))

        let first = try latitude(harness, vin: vinA)
        let second = try latitude(harness, vin: vinB)
        #expect(first == nil)
        #expect(second == nil)
    }

    private func latitude(_ harness: Harness, vin: String) throws -> Double? {
        try harness.database.db.query(
            sql: "SELECT latitude FROM telemetry_logs WHERE vin = ? LIMIT 1;"
        ) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> Double? in
            guard stmt.step() else { return nil }
            return stmt.columnDouble(at: 0)
        }
    }

    @Test
    func aLocationEraseDropsTheSnapshotMirrorAndKeepsEveryOtherStore() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        let stores = perVehicleStores(harness)

        for store in stores {
            for vin in [vinA, vinB] {
                #expect(store.isPresent(vin), "\(store.key) was not seeded for \(vin)")
            }
        }

        try harness.eraser.perform(.locations(.vehicle(vinA)))

        for store in stores {
            if store.key == "cached_vehicle_snapshots_v1" {
                #expect(!store.isPresent(vinA), "the snapshot mirror survived a location erase")
                #expect(store.isPresent(vinB), "the location erase reached another vehicle")
            } else {
                #expect(store.isPresent(vinA), "\(store.key) is not location state")
                #expect(store.isPresent(vinB), "\(store.key) is not location state")
            }
        }

        // The fleet-wide location clear names the same one store rather than inheriting the
        // table: a nickname or a theme it took would be the erase bug this scope is defined
        // against.
        try harness.eraser.perform(.locations(.all))

        for store in stores {
            for vin in [vinA, vinB] {
                if store.key == "cached_vehicle_snapshots_v1" {
                    #expect(!store.isPresent(vin), "the snapshot mirror survived a location erase")
                } else {
                    #expect(store.isPresent(vin), "\(store.key) is not location state")
                }
            }
        }
        // The plist keys again, read straight off the domain rather than through the accessors.
        // The SQLite-backed stores have no key to read: the accessor loop above is their check.
        for store in stores
        where store.isDefaultsBacked && store.key != "cached_vehicle_snapshots_v1" {
            #expect(
                harness.scoped.defaults.object(forKey: store.key) != nil,
                "\(store.key) left the defaults domain on a location erase")
        }
    }

    @Test
    func theEraseDropsRegisteredInMemoryCachesForTheSameScope() throws {
        let harness = Harness()
        let cache = RecordingMemoryCache()
        harness.registry.register(cache)

        try harness.eraser.perform(.everything(.vehicle(vinA)))
        #expect(cache.scopes == [.vehicle(vinA)])

        try harness.eraser.perform(.session(.all))
        #expect(cache.scopes == [.vehicle(vinA), .all])

        // A location clear invalidates the held snapshot alone: the notification latches and
        // badge counts a full erase takes with it are not location state.
        try harness.eraser.perform(.locations(.vehicle(vinA)))
        #expect(cache.scopes == [.vehicle(vinA), .all])
        #expect(cache.snapshotScopes == [.vehicle(vinA)])

        // Compaction reaches no per-VIN tier, so it must not invalidate one either.
        try harness.eraser.perform(.compact)
        #expect(cache.scopes == [.vehicle(vinA), .all])
        #expect(cache.snapshotScopes == [.vehicle(vinA)])
    }

    @Test
    func theEraseDropsTheFleetsRetainedSnapshots() throws {
        let harness = Harness()
        try seed(harness, vin: vinA)
        try seed(harness, vin: vinB)
        let fleetStore = FleetStore(stateStore: harness.stateStore, preferences: harness.preferences)
        fleetStore.retain(vehicle(vin: vinA, battery: 11))
        fleetStore.retain(vehicle(vin: vinB, battery: 22))
        harness.registry.register(fleetStore)

        try harness.eraser.perform(.everything(.vehicle(vinA)))

        #expect(fleetStore.snapshot(for: vinA) == nil)
        #expect(fleetStore.snapshot(for: vinB)?.energy.batteryPercentage == 22)
    }

    @Test
    func theEraseStopsTheNotifierNamingBannersAfterTheWipedVehicle() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        let registry = VehicleMemoryCacheRegistry()
        registry.register(notifier)
        let eraser = LocalDataEraser(
            database: harness.store.database, preferences: harness.preferences,
            imageCache: CarImageCache(), memoryCaches: registry)
        // A Volvo-shaped VIN: the model family follows the VIN prefix, and preferencing the
        // dormant brand is what makes the stale snapshot visible in the banner.
        let vin = "YV1ERASETEST0000V"
        notifier.vehicleStateDidUpdate(vehicle(vin: vin, brand: .volvo))

        // Before the erase the remembered snapshot supplies the brand for a banner about a
        // vehicle that currently has no loaded state.
        notifier.notifyChargingAnomaly(locationName: "Home", vin: vin)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.last?.content.subtitle == "Volvo")

        try eraser.perform(.everything(.vehicle(vin)))

        notifier.notifyChargingAnomaly(locationName: "Home", vin: vin)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.last?.content.subtitle == "Polestar")
    }

    @Test
    func aLocationEraseLeavesNotificationLatchesAndTheBadgeAlone() async throws {
        let harness = try NotificationTestHarness()
        let vin = NotificationTestHarness.vin
        // A sustained latch opened ten minutes ago and persisted across a relaunch, so this run
        // sees it fire without waiting out its delay.
        harness.defaults.set(
            ["\(vin).stale": Date(timeIntervalSinceNow: -600).timeIntervalSince1970],
            forKey: "notifier_sustained_starts_v1")
        let notifier = harness.makeNotifier()
        var counts: [Int] = []
        notifier.onWarningVehicleCountChanged = { counts.append($0) }
        let registry = VehicleMemoryCacheRegistry()
        registry.register(notifier)
        let eraser = LocalDataEraser(
            database: harness.store.database, preferences: harness.preferences,
            imageCache: CarImageCache(), memoryCaches: registry)

        // A warning, so the vehicle is in the dock badge count; a due service, so the service-due
        // latch persists; a poll the car never answered, so the stale latch fires.
        var state = harness.makeState(serviceWarning: true)
        state.freshness.fetchedAt = Date(timeIntervalSinceNow: -7_200)
        state.freshness.vehicleReportedAt = Date(timeIntervalSinceNow: -7_200)
        notifier.vehicleStateDidUpdate(state)
        await harness.drainNotificationHops()
        #expect(counts == [1])
        #expect(harness.defaults.dictionary(forKey: "notifier_service_due_v1")?[vin] != nil)
        #expect(harness.defaults.dictionary(forKey: "notifier_sustained_starts_v1")?["\(vin).stale"] != nil)

        try eraser.perform(.locations(.vehicle(vin)))

        // The coordinates moved; nothing the reader has already been told about did.
        #expect(counts == [1])
        #expect(harness.defaults.dictionary(forKey: "notifier_service_due_v1")?[vin] != nil)
        #expect(harness.defaults.dictionary(forKey: "notifier_sustained_starts_v1")?["\(vin).stale"] != nil)

        // A full erase takes the latches and the badge with the vehicle, whether it is the wipe
        // or the sign-out of a known vehicle.
        try eraser.perform(.everything(.vehicle(vin)))
        #expect(counts == [1, 0])
        #expect(harness.defaults.dictionary(forKey: "notifier_service_due_v1")?[vin] == nil)
        #expect(harness.defaults.dictionary(forKey: "notifier_sustained_starts_v1")?["\(vin).stale"] == nil)

        notifier.vehicleStateDidUpdate(state)
        #expect(counts == [1, 0, 1])
        #expect(harness.defaults.dictionary(forKey: "notifier_service_due_v1")?[vin] != nil)

        try eraser.perform(.session(.vehicle(vin)))
        #expect(counts == [1, 0, 1, 0])
        #expect(harness.defaults.dictionary(forKey: "notifier_service_due_v1")?[vin] == nil)
        #expect(harness.defaults.dictionary(forKey: "notifier_sustained_starts_v1")?["\(vin).stale"] == nil)
    }
}

/// Records what an erase asked an in-memory tier to drop.
@MainActor
private final class RecordingMemoryCache: VehicleMemoryCaching {
    private(set) var scopes: [VehicleScope] = []
    private(set) var snapshotScopes: [VehicleScope] = []
    func dropCachedVehicles(_ scope: VehicleScope) { scopes.append(scope) }
    func dropCachedSnapshots(_ scope: VehicleScope) { snapshotScopes.append(scope) }
}
