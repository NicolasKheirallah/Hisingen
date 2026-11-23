import Foundation
import Testing
@testable import Hisingen

/// NexBlue rotates the refresh token on every grant, and every provider the model builds shares
/// the one stored token. Overlapping grants must neither run together nor sign the charger out.
@Suite("NexBlue token rotation")
@MainActor
struct NexBlueTokenRotationTests {
    private func makeStore() -> HomeChargingStore {
        let scoped = ScopedPreferences(label: "nexblue-rotation")
        return HomeChargingStore(defaults: scoped.defaults, keychain: scoped.keychain)
    }

    @Test
    func aGrantFromTheStoredTokenStoresTheRotatedOne() throws {
        let store = makeStore()
        try store.saveNexBlueRefreshToken("t1")
        try store.updateNexBlueRefreshToken("t2", previous: "t1")
        #expect(try store.nexBlueRefreshToken() == "t2")
    }

    @Test
    func aGrantThatLostTheRaceKeepsTheNewerStoredTokenAndDoesNotFail() throws {
        let store = makeStore()
        try store.saveNexBlueRefreshToken("t2")
        // Another grant already rotated t1 to t2; this one started from t1.
        try store.updateNexBlueRefreshToken("t3", previous: "t1")
        #expect(try store.nexBlueRefreshToken() == "t2")
    }

    @Test
    func aGrantFinishingAfterSignOutIsRefusedAndStoresNothing() throws {
        let store = makeStore()
        try store.saveNexBlueRefreshToken("t1")
        store.deleteCredentials(for: .nexBlue)
        #expect(throws: DirectChargerError.unauthorized) {
            try store.updateNexBlueRefreshToken("t2", previous: "t1")
        }
        #expect(try store.nexBlueRefreshToken() == nil)
    }
}

@Suite("Serial async queue")
struct SerialAsyncQueueTests {
    private actor Trace {
        var events: [String] = []
        var running = 0
        var overlapped = false
        func enter(_ name: String) {
            running += 1
            if running > 1 { overlapped = true }
            events.append("start \(name)")
        }
        func leave(_ name: String) {
            running -= 1
            events.append("end \(name)")
        }
    }

    @Test
    func operationsRunOneAtATimeInSubmissionOrder() async throws {
        let queue = SerialAsyncQueue()
        let trace = Trace()
        let first = Task { try await queue.run { await trace.enter("a"); try await Task.sleep(for: .milliseconds(80)); await trace.leave("a"); return 1 } }
        try await Task.sleep(for: .milliseconds(10))
        let second = Task { try await queue.run { await trace.enter("b"); await trace.leave("b"); return 2 } }
        try await Task.sleep(for: .milliseconds(10))
        let third = Task { try await queue.run { await trace.enter("c"); try await Task.sleep(for: .milliseconds(20)); await trace.leave("c"); return 3 } }
        let results = try await [first.value, second.value, third.value]
        #expect(results == [1, 2, 3])
        #expect(await trace.overlapped == false)
        #expect(await trace.events == ["start a", "end a", "start b", "end b", "start c", "end c"])
    }

    @Test
    func aFailedOperationDoesNotStopTheOnesBehindIt() async throws {
        struct Boom: Error {}
        let queue = SerialAsyncQueue()
        let failing = Task { try await queue.run { () async throws -> Int in throw Boom() } }
        let following = Task { try await queue.run { 7 } }
        #expect(await (try? failing.value) == nil)
        #expect(try await following.value == 7)
    }
}
