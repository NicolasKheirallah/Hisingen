import Foundation
import Testing
@testable import Hisingen

/// The derived-history queue.
///
/// Its contract is order and completeness, not coalescing. The charging ledger confirms a stop
/// from two consecutive observations, so a pass the queue drops is a lost session boundary —
/// and the queue's old coalescing was only ever safe because the snapshot write happened to
/// serialize callers from inside the same queued pass.
@Suite("Vehicle history writer", .serialized)
@MainActor
struct VehicleHistoryRecorderPerformanceTests {
    @Test("Every enqueued observation reaches the history tiers, in order")
    func deliversEveryObservationInOrder() async throws {
        let suite = "HisingenTests.HistoryWriterOrder.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let gate = FirstWriteGate()
        let recorder = VehicleHistoryRecorder(
            database: database,
            preferences: PreferencesStore(defaults: defaults),
            beforePersist: { gate.pauseFirstWrite() }
        )

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func observation(_ value: Int) -> VehicleState {
            vehicle(
                vin: "ORDER-VIN", battery: Double(value), odometerKm: value,
                fetchedAt: base.addingTimeInterval(Double(value) * 60)
            )
        }

        recorder.record(observation(1))
        #expect(gate.waitUntilFirstWriteStarts())
        // Enqueued while the first pass is still blocked: none of these may be dropped.
        for value in 2...10 {
            recorder.record(observation(value))
        }
        gate.resumeFirstWrite()
        await recorder.drain()

        #expect(gate.persistCount == 10)
        // `recentTelemetry` reads newest first; reversing yields the enqueue order.
        let odometers = database.history
            .recentTelemetry(for: "ORDER-VIN", limit: 50)
            .reversed()
            .map(\.odometerKm)
            .compactMap { $0 }
        #expect(odometers == Array(1...10).map(Double.init))
    }
}

private final class FirstWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var isFirst = true
    private var count = 0

    var persistCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func pauseFirstWrite() {
        lock.lock()
        count += 1
        let shouldPause = isFirst
        isFirst = false
        lock.unlock()
        guard shouldPause else { return }
        started.signal()
        resume.wait()
    }

    func waitUntilFirstWriteStarts() -> Bool {
        started.wait(timeout: .now() + 2) == .success
    }

    func resumeFirstWrite() { resume.signal() }
}
