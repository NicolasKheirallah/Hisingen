import Foundation
import Testing
@testable import Hisingen

private enum SingleFlightTestError: Error {
    case failed
}

/// Owns its in-flight table the way `PolestarGRPC` does, so the helper runs under actor isolation.
private actor SingleFlightHarness {
    private var inFlight: [String: PolestarInFlightRequest<Int>] = [:]
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var shouldFail: Bool
    private(set) var joins = 0
    private(set) var executions = 0

    init(failing: Bool = false) {
        shouldFail = failing
    }

    func load(_ key: String) async throws -> Int {
        let flight = SingleFlight.join(key, in: &inFlight) {
            Task { try await self.execute() }
        }
        joins += 1
        defer { SingleFlight.finish(key, flight, in: &inFlight) }
        return try await flight.task.value
    }

    /// Holds the execution until `open()`, so concurrent callers can join the same flight.
    private func execute() async throws -> Int {
        executions += 1
        if !isOpen {
            await withCheckedContinuation { parked.append($0) }
        }
        if shouldFail { throw SingleFlightTestError.failed }
        return executions
    }

    func open() {
        isOpen = true
        parked.forEach { $0.resume() }
        parked = []
    }

    func setFailing(_ value: Bool) {
        shouldFail = value
    }
}

struct SingleFlightTests {

    @Test func concurrentCallersShareOneExecution() async throws {
        let harness = SingleFlightHarness()
        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { try await harness.load("VIN") }
            }
            // `joins` counts inside the actor right after `join`, so 8 means every caller joined.
            while await harness.joins < 8 { await Task.yield() }
            await harness.open()
            var collected: [Int] = []
            for try await value in group { collected.append(value) }
            return collected
        }
        let runs = await harness.executions
        #expect(values == Array(repeating: 1, count: 8))
        #expect(runs == 1)
    }

    @Test func failurePropagatesToEveryCaller() async throws {
        let harness = SingleFlightHarness(failing: true)
        let failures = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<3 {
                group.addTask { (try? await harness.load("VIN")) == nil }
            }
            while await harness.joins < 3 { await Task.yield() }
            await harness.open()
            var collected: [Bool] = []
            for await failed in group { collected.append(failed) }
            return collected
        }
        let runs = await harness.executions
        #expect(failures == [true, true, true])
        #expect(runs == 1)
    }

    @Test func callAfterCompletionRunsAgain() async throws {
        let harness = SingleFlightHarness()
        await harness.open()
        let first = try await harness.load("VIN")
        let second = try await harness.load("VIN")
        let runs = await harness.executions
        #expect(first == 1)
        #expect(second == 2)
        #expect(runs == 2)
    }

    @Test func failedFlightIsNotReusedByTheNextCall() async throws {
        let harness = SingleFlightHarness(failing: true)
        await harness.open()
        var threw = false
        do {
            _ = try await harness.load("VIN")
        } catch {
            threw = true
        }
        await harness.setFailing(false)
        let recovered = try await harness.load("VIN")
        let runs = await harness.executions
        #expect(threw)
        #expect(recovered == 2)
        #expect(runs == 2)
    }
}
