import Foundation
import Testing
@testable import Hisingen

/// Stands in for the presenter's wall-clock timer. Each armed timeout waits here until the test
/// fires it, so the order in which timeouts expire is the test's choice rather than the speed of
/// the machine running it.
@MainActor
private final class ManualTimeouts {
    private(set) var durations: [TimeInterval] = []
    private var waiting: [CheckedContinuation<Void, Never>?] = []

    var armedCount: Int { durations.count }

    func sleep(_ duration: TimeInterval) async {
        durations.append(duration)
        await withCheckedContinuation { waiting.append($0) }
    }

    func fire(_ index: Int) {
        waiting[index]?.resume()
        waiting[index] = nil
    }

    func fireAll() {
        for index in waiting.indices { fire(index) }
    }
}

/// The browser hand-off times out so a lost callback cannot wedge the sign-in lane. That timeout
/// belongs to the round trip that armed it: one that fires after its round trip ended must not
/// find a later sign-in's continuation and resume the finished one a second time.
@Suite("Volvo sign-in presenter timeout", .serialized)
@MainActor
struct VolvoSignInPresenterTimeoutTests {
    private let authorize = URL(string: "https://volvoid.eu.volvocars.com/as/authorization.oauth2")!
    private let callback = URL(string: "hisingen://oauth/volvo/callback?code=c&state=s")!

    private func makePresenter(_ timeouts: ManualTimeouts, callbackTimeout: TimeInterval = 300) -> VolvoSignInPresenter {
        VolvoSignInPresenter(
            callbackTimeout: callbackTimeout,
            openInBrowser: { _ in true },
            sleep: { await timeouts.sleep($0) })
    }

    private func waitUntilWaiting(_ presenter: VolvoSignInPresenter) async -> Bool {
        await wait { presenter.isWaitingForCallback }
    }

    private func wait(until condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// Lets a fired timeout run to its end. A timeout that wrongly ended a round trip does so in
    /// the first turns after it is fired, so a generous number of yields lets it show.
    private func letFiredTimeoutsSettle() async {
        for _ in 0..<200 { await Task.yield() }
    }

    @Test
    func anEarlierRoundTripsTimeoutLeavesALaterSignInAlone() async throws {
        let timeouts = ManualTimeouts()
        let presenter = makePresenter(timeouts)

        let first = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(await waitUntilWaiting(presenter))
        #expect(await wait { timeouts.armedCount == 1 })
        presenter.handleCallbackURL(callback)
        _ = try await first.value
        #expect(!presenter.isWaitingForCallback)

        // The second sign-in starts after the first finished while the first's timer is still armed.
        let second = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(await waitUntilWaiting(presenter))
        #expect(await wait { timeouts.armedCount == 2 })

        // The first round trip's timeout expires now; the second's has not.
        timeouts.fire(0)
        await letFiredTimeoutsSettle()
        #expect(presenter.isWaitingForCallback, "A finished round trip's timer must not end a newer one")

        presenter.handleCallbackURL(callback)
        _ = try await second.value
        timeouts.fireAll()
    }

    @Test
    func aRoundTripThatHearsNothingStillTimesOut() async throws {
        let timeouts = ManualTimeouts()
        let presenter = makePresenter(timeouts, callbackTimeout: 42)

        let signIn = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(await wait { timeouts.armedCount == 1 })
        #expect(timeouts.durations == [42])
        #expect(presenter.isWaitingForCallback)

        timeouts.fire(0)
        await #expect(throws: (any Error).self) { try await signIn.value }
        #expect(!presenter.isWaitingForCallback)
    }
}
