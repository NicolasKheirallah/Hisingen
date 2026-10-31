import Foundation
import Testing
@testable import Hisingen

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct RefreshClockSeamTests {
    @MainActor
    private final class GatedClock {
        private(set) var waits: [TimeInterval] = []
        let starts = TestEvent<TimeInterval>()
        let finished = TestEvent<Void>()
        private let releases = TestEvent<Void>()

        func wait(_ duration: TimeInterval) async throws {
            waits.append(duration)
            starts.yield(duration)
            defer { finished.yield(()) }
            try await releases.next()
        }

        func release() { releases.yield(()) }
        func cancel() { releases.cancel() }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.clock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func aScheduledTickWaitsOnTheInjectedClock() async throws {
        let clock = GatedClock()
        let loop = AsyncTimerLoop(wait: { duration in try await clock.wait(duration) })
        let fired = TestEvent<Void>()
        defer { loop.cancel(); clock.cancel() }

        loop.scheduleOnce(after: 120) { fired.yield(()) }
        #expect(try await clock.starts.next() == 120)
        clock.release()
        _ = try await fired.next()
        #expect(clock.waits == [120])
    }

    @Test
    func aCancelledTickIsDroppedWhileItSleepsOnTheInjectedClock() async throws {
        let clock = GatedClock()
        let loop = AsyncTimerLoop(wait: { duration in try await clock.wait(duration) })
        var fired = false
        defer { loop.cancel(); clock.cancel() }

        loop.scheduleOnce(after: 30) { fired = true }
        #expect(try await clock.starts.next() == 30)
        loop.cancel()
        _ = try await clock.finished.next()
        #expect(!fired)
        #expect(clock.waits == [30])
    }

    @Test
    func theRetryCadenceIsAssertedInsteadOfSleptThrough() async throws {
        let clock = GatedClock()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults,
                                           keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.vin = "YSMTEST"
        let coordinator = RefreshCoordinator(
            api: ClockProbeProvider(),
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            scheduler: AsyncTimerLoop(wait: { duration in try await clock.wait(duration) }),
            now: { instant }
        )
        defer { coordinator.stop(); clock.cancel() }
        coordinator.start(preferredVIN: "YSMTEST")
        _ = try await clock.starts.next()

        // The delay the coordinator asked its clock for is the deadline it published as the next
        // refresh, and the test read both without waiting out either.
        let recorded = try #require(clock.waits.last, "the coordinator never asked its clock to wait")
        let scheduled = try #require(coordinator.nextRefresh)
        #expect(recorded == scheduled.timeIntervalSince(instant))
        #expect(recorded > 0)

        coordinator.stop()
    }
}

private actor ClockProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? cars.first?.vin }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
