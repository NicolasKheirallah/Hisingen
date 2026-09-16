import Foundation
import Testing
@testable import Hisingen

/// The durable provider stand-downs: one owner for both adapters, injected rather than reached
/// through `UserDefaults.standard`, and named by the erasure regime so a wipe can find them.
@MainActor
struct ProviderBackoffStoreTests {
    private let vin = "PROVIDER_BACKOFF_VIN"
    private let otherVIN = "PROVIDER_BACKOFF_OTHER_VIN"

    private func makeDefaults() throws -> UserDefaults {
        try #require(UserDefaults(
            suiteName: "io.kheirallah.hisingen.providerbackoff.\(UUID().uuidString)"))
    }

    @Test
    func aStandDownSurvivesANewOwnerOverTheSameDatabase() throws {
        let database = VehicleDatabase.inMemory()
        let now = Date()
        let until = now.addingTimeInterval(3_600)
        ProviderBackoffStore(database: database)
            .block(VolvoAPI.endpointBackoffSubject("environment", vin: vin), until: until, reason: nil)

        // A relaunch is a new owner over the same file: what it reads back is what was written,
        // which is the behaviour the defaults dictionary had to hand-roll. The row keeps the
        // instant as epoch seconds, so compare it as one: sub-millisecond drift is not a
        // stand-down anybody can observe.
        let read = try #require(ProviderBackoffStore(database: database)
            .blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin), now: now))
        #expect(abs(read.timeIntervalSince(until)) < 0.001)
    }

    @Test
    func anExpiredStandDownDoesNotAnswerAndUnblockingRestoresTheProbe() {
        let database = VehicleDatabase.inMemory()
        let now = Date()
        let store = ProviderBackoffStore(database: database)
        let subject = VolvoAPI.endpointBackoffSubject("environment", vin: vin)
        store.block(subject, until: now.addingTimeInterval(-1), reason: nil)

        #expect(store.blockedUntil(subject, now: now) == nil)

        store.block(subject, until: now.addingTimeInterval(60), reason: nil)
        #expect(store.blockedUntil(subject, now: now) != nil)
        store.unblock(subject)
        #expect(store.blockedUntil(subject, now: now) == nil)
    }

    @Test
    func theReasonReachesTheDiagnosticsExport() {
        let database = VehicleDatabase.inMemory()
        let store = ProviderBackoffStore(database: database)
        #expect(store.reason(for: PolestarAPI.discoveryBackoff, fallback: "persistentFailure")
            == "persistentFailure")

        store.block(PolestarAPI.discoveryBackoff, until: Date().addingTimeInterval(60), reason: "client-426")
        #expect(store.reason(for: PolestarAPI.discoveryBackoff, fallback: "persistentFailure") == "client-426")
    }

    @Test
    func everyVehicleAndEndpointIsItsOwnSubject() {
        let database = VehicleDatabase.inMemory()
        let store = ProviderBackoffStore(database: database)
        store.block(
            VolvoAPI.endpointBackoffSubject("environment", vin: vin), until: Date().addingTimeInterval(3_600), reason: nil)

        // Volvo's market restriction is learned per vehicle and per endpoint: carrying it to
        // another car or another path would skip a probe that has never failed.
        #expect(store.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: otherVIN)) == nil)
        #expect(store.blockedUntil(VolvoAPI.endpointBackoffSubject("location", vin: vin)) == nil)
        #expect(store.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin)) != nil)
    }

    @Test
    func aSessionEraseDropsVehicleStandDownsAndKeepsTheProviderWideOne() throws {
        let database = VehicleDatabase.inMemory()
        let defaults = try makeDefaults()
        let store = ProviderBackoffStore(database: database)
        store.block(
            VolvoAPI.endpointBackoffSubject("environment", vin: vin),
            until: Date().addingTimeInterval(3_600),
            reason: nil)
        store.block(PolestarAPI.discoveryBackoff, until: Date().addingTimeInterval(86_400), reason: "client-426")

        let eraser = LocalDataEraser(
            database: database,
            preferences: PreferencesStore(defaults: defaults),
            imageCache: CarImageCache())
        try eraser.perform(.session(.vehicle(vin)))

        #expect(store.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin)) == nil)
        // Not account state: a client-version rejection is answered by a new client, not a
        // sign-out, so a session erase leaves it standing.
        #expect(store.blockedUntil(PolestarAPI.discoveryBackoff) != nil)
    }

    @Test
    func aFleetWideEraseDropsEveryStandDown() throws {
        let database = VehicleDatabase.inMemory()
        let defaults = try makeDefaults()
        let store = ProviderBackoffStore(database: database)
        store.block(
            VolvoAPI.endpointBackoffSubject("environment", vin: vin),
            until: Date().addingTimeInterval(3_600),
            reason: nil)
        store.block(PolestarAPI.discoveryBackoff, until: Date().addingTimeInterval(86_400), reason: "client-426")

        let eraser = LocalDataEraser(
            database: database,
            preferences: PreferencesStore(defaults: defaults),
            imageCache: CarImageCache())
        try eraser.perform(.everything(.all))

        #expect(store.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin)) == nil)
        #expect(store.blockedUntil(PolestarAPI.discoveryBackoff) == nil)
    }

    @Test
    func aRestrictedVolvoEndpointStandsDownWithoutBeingReprobed() async throws {
        let suite = "io.kheirallah.hisingen.providerbackoff.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let backoffs = ProviderBackoffStore(database: .inMemory())
        let api = VolvoAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"),
            preferences: PreferencesStore(defaults: defaults),
            backoffs: backoffs)

        let first: Int? = try await api.optional(
            enabled: true, key: "environment", vin: vin,
            operation: { () async throws -> Int in
                throw VolvoError.regionRestricted(service: "environment")
            })
        #expect(first == nil)

        // The adapter consults the store it was handed: the second probe is skipped rather than
        // attempted, which is the whole point of persisting the restriction.
        let second: Int? = try await api.optional(
            enabled: true, key: "environment", vin: vin, operation: { 42 })
        #expect(second == nil)
        #expect(backoffs.blockedUntil(VolvoAPI.endpointBackoffSubject("environment", vin: vin)) != nil)

        let other: Int? = try await api.optional(
            enabled: true, key: "environment", vin: otherVIN, operation: { 42 })
        #expect(other == 42)
    }

    @Test func theLaunchSweepDropsClosedStandDownsAndKeepsOpenOnes() {
        let database = VehicleDatabase.inMemory()
        let store = ProviderBackoffStore(database: database)
        let vin = "VIN-SWEEP"
        let now = Date()
        let closed = VolvoAPI.endpointBackoffSubject("environment", vin: vin)
        let open = VolvoAPI.endpointBackoffSubject("location", vin: vin)
        store.block(closed, until: now.addingTimeInterval(-60), reason: "closed")
        store.block(open, until: now.addingTimeInterval(3_600), reason: "open")

        // What `VehicleStateStore.activate()` runs on every launch.
        database.deleteExpiredProviderBackoffs(now: now)

        #expect(store.blockedUntil(closed, now: now) == nil)
        #expect(store.blockedUntil(open, now: now) != nil)
    }
}
