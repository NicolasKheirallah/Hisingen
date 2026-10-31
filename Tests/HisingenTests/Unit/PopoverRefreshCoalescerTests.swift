import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct PopoverRefreshCoalescerTests {
    @Test
    func requestsInsideWindowProduceOneRefreshWithLatestState() async throws {
        let state = RenderState()
        let sleeper = ControllableSleeper()
        let coalescer = PopoverRefreshCoalescer(
            delay: .milliseconds(120),
            sleep: { try await sleeper.sleep($0) }
        ) {
            state.render()
        }

        coalescer.schedule()
        state.latest = 2
        coalescer.schedule()
        state.latest = 3
        coalescer.schedule()

        #expect(try await sleeper.sleepStarts.next() == .milliseconds(120))
        #expect(state.rendered.isEmpty)

        sleeper.releaseNext()
        #expect(try await state.renders.next() == 3)
        #expect(state.rendered == [3])
        #expect(sleeper.requestCount == 1)
    }

    @Test
    func requestAfterRefreshOpensANewWindow() async throws {
        let state = RenderState()
        let sleeper = ControllableSleeper()
        let coalescer = PopoverRefreshCoalescer(
            delay: .milliseconds(120),
            sleep: { try await sleeper.sleep($0) }
        ) {
            state.render()
        }

        coalescer.schedule()
        _ = try await sleeper.sleepStarts.next()
        sleeper.releaseNext()
        _ = try await state.renders.next()

        state.latest = 2
        coalescer.schedule()
        _ = try await sleeper.sleepStarts.next()
        sleeper.releaseNext()
        #expect(try await state.renders.next() == 2)
        #expect(state.rendered == [1, 2])
        #expect(sleeper.requestCount == 2)
    }

    @Test
    func aMissingEventFailsWithinItsDeadline() async {
        let event = TestEvent<Int>()
        do {
            _ = try await event.next(timeout: .milliseconds(1))
            Issue.record("An event without a producer unexpectedly completed")
        } catch is TestEventTimeout {
        } catch {
            Issue.record("Unexpected event failure: \(error)")
        }
    }

    @Test
    func cancellingAnEventWaitReleasesItsContinuation() async throws {
        let event = TestEvent<Int>()
        let started = TestEvent<Void>()
        let waiting = Task { try await event.next(onWait: { started.yield(()) }) }
        try await started.next()
        waiting.cancel()
        do {
            _ = try await waiting.value
            Issue.record("A cancelled event wait unexpectedly completed")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected cancellation failure: \(error)")
        }
        event.yield(42)
        #expect(try await event.next() == 42)
    }

    @Test
    func defaultWindowStaysWithinInteractiveCoalescingRange() {
        #expect(PopoverRefreshCoalescer.defaultDelay >= .milliseconds(150))
        #expect(PopoverRefreshCoalescer.defaultDelay <= .milliseconds(250))
    }
}

/// Stands in for `Task.sleep`. Each call announces its requested duration and then suspends
/// until the test releases it, so no test waits on the wall clock.
@MainActor
private final class ControllableSleeper {
    let sleepStarts = TestEvent<Duration>()
    private let releases = TestEvent<Void>()
    private(set) var requestCount = 0

    func sleep(_ duration: Duration) async throws {
        requestCount += 1
        sleepStarts.yield(duration)
        try await releases.next()
    }

    func releaseNext() { releases.yield(()) }

}

@MainActor
private final class RenderState {
    var latest = 1
    private(set) var rendered: [Int] = []
    let renders = TestEvent<Int>()

    func render() {
        rendered.append(latest)
        renders.yield(latest)
    }
}
