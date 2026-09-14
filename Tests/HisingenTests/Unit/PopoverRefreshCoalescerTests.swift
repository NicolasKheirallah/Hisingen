import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PopoverRefreshCoalescerTests {
    @Test
    func requestsInsideWindowProduceOneRefreshWithLatestState() async throws {
        let state = RenderState()
        let coalescer = PopoverRefreshCoalescer(delay: .milliseconds(120)) {
            state.rendered.append(state.latest)
        }

        coalescer.schedule()
        state.latest = 2
        coalescer.schedule()
        state.latest = 3
        coalescer.schedule()

        #expect(state.rendered.isEmpty)
        let clock = ContinuousClock()
        // The full suite runs several MainActor-heavy integration suites concurrently. Give
        // the actor time to resume without turning scheduler congestion into a coalescer flake.
        let deadline = clock.now.advanced(by: .seconds(10))
        while state.rendered.isEmpty, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.rendered == [3])
    }

    @Test
    func defaultWindowStaysWithinInteractiveCoalescingRange() {
        #expect(PopoverRefreshCoalescer.defaultDelay >= .milliseconds(150))
        #expect(PopoverRefreshCoalescer.defaultDelay <= .milliseconds(250))
    }
}

@MainActor
private final class RenderState {
    var latest = 1
    var rendered: [Int] = []
}
