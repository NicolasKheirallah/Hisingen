import Foundation
import Testing
@testable import Hisingen

@Suite("Vehicle history writer performance", .serialized)
@MainActor
struct VehicleHistoryRecorderPerformanceTests {
    @Test("Pending observations coalesce by VIN while preserving the latest state")
    func coalescesPendingObservations() async throws {
        let suite = "HisingenTests.HistoryWriterPerformance.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()
        let gate = FirstWriteGate()
        let recorder = VehicleHistoryRecorder(
            database: database,
            preferences: PreferencesStore(defaults: defaults),
            beforePersist: { gate.pauseFirstWrite() }
        )

        recorder.record(vehicle(vin: "COALESCE-VIN", battery: 1, odometerKm: 1))
        #expect(gate.waitUntilFirstWriteStarts())
        for value in 2...100 {
            recorder.record(vehicle(vin: "COALESCE-VIN", battery: Double(value), odometerKm: value))
        }
        gate.resumeFirstWrite()
        await recorder.waitUntilIdle()

        #expect(gate.persistCount == 2)
        let stored = try #require(database.loadSnapshot(for: "COALESCE-VIN"))
        #expect(stored.energy.batteryPercentage == 100)
        #expect(stored.maintenance.odometerKm == 100)
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
