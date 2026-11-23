import Foundation
import Testing
@testable import Hisingen

/// The browser hand-off times out so a lost callback cannot wedge the sign-in lane. That timeout
/// belongs to the round trip that armed it: one that fires after its round trip ended must not
/// find a later sign-in's continuation and resume the finished one a second time.
@Suite("Volvo sign-in presenter timeout", .serialized)
@MainActor
struct VolvoSignInPresenterTimeoutTests {
    private let authorize = URL(string: "https://volvoid.eu.volvocars.com/as/authorization.oauth2")!
    private let callback = URL(string: "hisingen://oauth/volvo/callback?code=c&state=s")!

    private func waitUntilWaiting(_ presenter: VolvoSignInPresenter) async -> Bool {
        for _ in 0..<10_000 {
            if presenter.isWaitingForCallback { return true }
            await Task.yield()
        }
        return false
    }

    @Test
    func anEarlierRoundTripsTimeoutLeavesALaterSignInAlone() async throws {
        let presenter = VolvoSignInPresenter(callbackTimeout: 0.4, openInBrowser: { _ in true })

        let first = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(await waitUntilWaiting(presenter))
        presenter.handleCallbackURL(callback)
        _ = try await first.value
        #expect(!presenter.isWaitingForCallback)

        // The second sign-in starts after the first finished but before the first's timer fires.
        try await Task.sleep(for: .milliseconds(200))
        let second = Task { @MainActor in
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(await waitUntilWaiting(presenter))

        // Past the first timer (0.4 s), before the second's own (0.2 + 0.4 s).
        try await Task.sleep(for: .milliseconds(300))
        #expect(presenter.isWaitingForCallback, "A finished round trip's timer must not end a newer one")

        presenter.handleCallbackURL(callback)
        _ = try await second.value
    }

    @Test
    func aRoundTripThatHearsNothingStillTimesOut() async throws {
        let presenter = VolvoSignInPresenter(callbackTimeout: 0.1, openInBrowser: { _ in true })
        await #expect(throws: (any Error).self) {
            try await presenter.signIn(authorizeURL: authorize, callbackScheme: "hisingen")
        }
        #expect(!presenter.isWaitingForCallback)
    }
}
