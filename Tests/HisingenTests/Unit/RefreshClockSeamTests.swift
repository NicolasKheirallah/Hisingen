import Foundation
import Testing
@testable import Hisingen

/// The refresh module's clock seam: `AsyncTimerLoop` sleeps on an injected wait, so a test can
/// assert the delay the coordinator asked for instead of waiting it out in real time. This is
/// the seam the 34-test stream suite still polls through, and the one its conversion will drive.
@MainActor
struct RefreshClockSeamTests {
    /// Records every wait it is asked for and returns immediately.
    private final class RecordingClock: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []

        var waits: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func record(_ duration: TimeInterval) async throws {
            append(duration)
        }

        /// Sync on purpose: `NSLock` is unavailable directly inside an async context, and the
        /// lock is only ever held for this one append.
        private func append(_ duration: TimeInterval) {
            lock.lock()
            recorded.append(duration)
            lock.unlock()
        }
    }

    /// Records every wait and parks on it until `release()`: the coordinator cannot advance past
    /// the wait, so what it published as `nextRefresh` is still what the test reads.
    private final class GatedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [TimeInterval] = []
        private var parked: [CheckedContinuation<Void, Never>] = []

        var waits: [TimeInterval] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }

        func wait(_ duration: TimeInterval) async {
            await withCheckedContinuation { continuation in
                lock.lock()
                recorded.append(duration)
                parked.append(continuation)
                lock.unlock()
            }
        }

        func release() {
            lock.lock()
            let continuations = parked
            parked = []
            lock.unlock()
            continuations.forEach { $0.resume() }
        }
    }

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.clock.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func aScheduledTickWaitsOnTheInjectedClock() async {
        let clock = RecordingClock()
        let loop = AsyncTimerLoop(wait: { duration in try await clock.record(duration) })
        let fired = Flag()

        loop.scheduleOnce(after: 120) { fired.set() }
        for _ in 0..<500 where !fired.value { await Task.yield() }

        #expect(fired.value, "the tick never ran on the injected clock")
        #expect(clock.waits == [120], "the loop waited somewhere other than the injected clock")
    }

    @Test
    func aCancelledTickIsDroppedWhileItSleepsOnTheInjectedClock() async {
        let clock = RecordingClock()
        let loop = AsyncTimerLoop(wait: { duration in try await clock.record(duration) })
        let fired = Flag()

        loop.scheduleOnce(after: 30) { fired.set() }
        loop.cancel()
        for _ in 0..<50 { await Task.yield() }

        // The wait began – the tick was already sleeping on the injected clock – and cancelling
        // is what drops it before the tick body runs.
        #expect(!fired.value, "a cancelled tick ran anyway")
        #expect(clock.waits == [30])
    }

    @Test
    func theRetryCadenceIsAssertedInsteadOfSleptThrough() async throws {
        let clock = GatedClock()
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMTEST"
        let coordinator = RefreshCoordinator(
            api: ClockProbeProvider(),
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            sessionManager: SessionManager(readToken: { _ in "test-session" },
                                           readPassword: { nil }, clearPassword: {}),
            scheduler: AsyncTimerLoop(wait: { duration in await clock.wait(duration) }),
            now: { instant }
        )
        coordinator.start(preferredVIN: "YSMTEST")
        for _ in 0..<1_000 where clock.waits.isEmpty { await Task.yield() }

        // The delay the coordinator asked its clock for is the deadline it published as the next
        // refresh, and the test read both without waiting out either.
        let recorded = try #require(clock.waits.last, "the coordinator never asked its clock to wait")
        let scheduled = try #require(coordinator.nextRefresh)
        #expect(recorded == scheduled.timeIntervalSince(instant))
        #expect(recorded > 0)

        clock.release()
        coordinator.stop()
    }
}

/// A one-shot flag two tasks can share.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

private actor ClockProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
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
