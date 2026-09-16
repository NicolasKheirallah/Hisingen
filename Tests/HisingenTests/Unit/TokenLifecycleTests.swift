import Foundation
import Testing
@testable import Hisingen

/// The token lifecycle, driven entirely through its constructor: a stub grant, a stub persist,
/// and an injected clock. Before this module the same sequence existed twice, and neither copy
/// was reachable this way – each provider built its own transport inside its initializer, so the
/// only route to the renewal margin, the rotation rule, or the dead-grant path was to mutate
/// actor internals from a test.
@Suite("Token lifecycle")
struct TokenLifecycleTests {
    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Renewal decision

    @Test func aTokenInsideItsRenewalWindowIsReused() async throws {
        let grants = GrantCounter()
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "fresh"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now.addingTimeInterval(240)

        // 300 s lifetime, 30 s margin: 240 s remaining is still comfortably inside the grant.
        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.renewalWindow, now: now, epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant() })

        #expect(outcome == .notNeeded)
        #expect(await grants.value == 0)
        #expect(lifecycle.accessToken == "fresh")
    }

    @Test func aTokenInsideTheMarginIsRenewed() async throws {
        let grants = GrantCounter()
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "expiring"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        // 10 s remaining is inside the 30 s margin a 300 s grant computes.
        lifecycle.tokenExpiry = now.addingTimeInterval(10)

        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.renewalWindow, now: now, epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant() })

        #expect(outcome == .refreshed)
        #expect(await grants.value == 1)
        #expect(lifecycle.accessToken == "refreshed-access")
    }

    // MARK: - Rotation

    @Test func aRotatedRefreshTokenReplacesThePreviousOneAndIsPersistedOnce() async throws {
        let persisted = PersistRecorder()
        let lifecycle = makeLifecycle(persist: { persisted.record($0) })
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "previous"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { Self.grant(refreshToken: "rotated") })

        #expect(outcome == .refreshed)
        #expect(lifecycle.accessToken == "refreshed-access")
        #expect(lifecycle.refreshToken == "rotated")
        #expect(lifecycle.tokenLifetime == 300)
        #expect(lifecycle.tokenExpiry == now.addingTimeInterval(300))
        #expect(persisted.values == ["rotated"])
    }

    @Test func anUnrotatedGrantIsNotPersisted() async throws {
        let persisted = PersistRecorder()
        let lifecycle = makeLifecycle(persist: { persisted.record($0) })
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "previous"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        _ = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { Self.grant(refreshToken: nil) })

        #expect(lifecycle.refreshToken == "previous")
        #expect(persisted.values.isEmpty)
    }

    @Test func aFailedPersistStillKeepsTheRotatedTokenInMemory() async throws {
        let lifecycle = makeLifecycle(persist: { _ in throw PersistFailure() })
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "previous"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        _ = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { Self.grant(refreshToken: "rotated") })

        // The server already invalidated the previous token, so a storage failure must not leave
        // the session replaying it: the rotated token is live in memory either way.
        #expect(lifecycle.refreshToken == "rotated")
        #expect(lifecycle.accessToken == "refreshed-access")
    }

    @Test func aRefusedTokenTheSessionNoLongerHoldsSpendsNoGrant() async throws {
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = nil
        lifecycle.refreshToken = "previous"
        lifecycle.tokenLifetime = 300

        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { throw GrantRejected() })

        // A dead grant clears the session's token; a 401 for the old one arriving afterwards must
        // not try to grant again (the throwing closure would surface that).
        #expect(outcome == .notNeeded)
    }

    // MARK: - Dead grant

    @Test func aDeadGrantIsReportedAndNothingIsApplied() async throws {
        let lifecycle = makeLifecycle(isDeadGrant: { _ in true })
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { throw GrantRejected() })

        #expect(outcome == .deadGrant)
        // The caller decides what a dead grant means in its own vocabulary; the lifecycle only
        // reports it, and applies nothing.
        #expect(lifecycle.accessToken == "expired")
        #expect(lifecycle.refreshToken == "stored")
    }

    @Test func aTransientGrantFailureIsRethrownUntouched() async throws {
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        await #expect(throws: GrantRejected.self) {
            try await lifecycle.refresh(
                TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
                grant: { throw GrantRejected() })
        }
        #expect(lifecycle.accessToken == "expired")
    }

    @Test func aGrantLandingAfterTheSessionMovedIsDiscarded() async throws {
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        await #expect(throws: CancellationError.self) {
            try await lifecycle.refresh(
                TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { false },
                grant: { Self.grant(refreshToken: "rotated") })
        }
        #expect(lifecycle.accessToken == "expired")
        #expect(lifecycle.refreshToken == "stored")
    }

    // MARK: - Bursts

    @Test func aBurstInsideTheMinimumRegrantIntervalIsSwallowed() async throws {
        // Volvo's shape: its request layer does not carry the refused token back, so a forced call
        // has nothing to compare and the granted-at cooldown is what bounds the burst.
        let grants = GrantCounter()
        let lifecycle = makeLifecycle(minimumRegrantInterval: 10)
        lifecycle.accessToken = "expired"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now

        _ = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: nil), now: now, epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant(refreshToken: "rotated") })

        // A second caller arrives five seconds later: the grant that just landed is the freshest
        // token obtainable, so the cooldown reuses it rather than starting another.
        let burst = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: nil), now: now.addingTimeInterval(5), epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant(refreshToken: "rotated-again") })

        #expect(burst == .notNeeded)
        #expect(await grants.value == 1)

        // Past the cooldown the next grant is allowed through.
        let later = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: nil), now: now.addingTimeInterval(11), epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant(refreshToken: "rotated-later") })

        #expect(later == .refreshed)
        #expect(await grants.value == 2)
    }

    @Test func aRefusedTokenAlreadyReplacedNeedsNoGrant() async throws {
        // Polestar's late-401 shape: the caller was refused with "expired", but by the time its
        // retry reaches the lifecycle another caller's grant has already replaced that token.
        // Comparing against the session is what stops a fan-out of 401s from each spending a
        // grant – and it holds whether or not the second caller overlapped the first.
        let grants = GrantCounter()
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "replaced-by-another-grant"
        lifecycle.refreshToken = "rotated"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now.addingTimeInterval(300)

        let outcome = try await lifecycle.refresh(
            TokenLifecycle.Reason.serverRefused(rejectedToken: "expired"), now: now, epochIsCurrent: { true },
            grant: { await grants.record(); return Self.grant() })

        #expect(outcome == .notNeeded)
        #expect(await grants.value == 0)
    }

    @Test func concurrentCallersShareOneGrant() async throws {
        // A fan-out of callers all refused the same token. Every one of them is admitted while the
        // grant is still in flight – the way a burst on an expired token behaves – and the ones
        // that arrive after it lands must find the refused token already replaced rather than
        // spend a second grant. Either route leaves exactly one grant for the whole fan-out.
        let host = LifecycleHost(makeLifecycle())
        let grants = GrantCounter()
        let gate = GrantGate()
        await host.seedSession(accessToken: "expired", refreshToken: "stored", at: now)

        let callers = (0..<20).map { _ in
            Task {
                try await host.refresh(reason: .serverRefused(rejectedToken: "expired"), now: self.now) {
                    await grants.record()
                    await gate.arriveAndWait()
                    return TokenLifecycle.Grant(
                        accessToken: "refreshed-access", refreshToken: "rotated", expiresIn: 300)
                }
            }
        }
        await host.awaitEntries(20)
        await gate.waitForArrival()
        await gate.release()
        var outcomes: [TokenLifecycle.Outcome] = []
        for caller in callers { outcomes.append(try await caller.value) }

        #expect(outcomes.contains(.refreshed))
        #expect(outcomes.allSatisfy { $0 == .refreshed || $0 == .notNeeded })
        #expect(await grants.value == 1)
    }

    // MARK: - Reset

    @Test func resettingClearsTheSession() async throws {
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "live"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = now.addingTimeInterval(300)

        lifecycle.reset()

        #expect(lifecycle.accessToken == nil)
        #expect(lifecycle.refreshToken == nil)
        #expect(lifecycle.tokenExpiry == nil)
        #expect(lifecycle.tokenLifetime == 0)
    }

    @Test func resettingForAReSignInKeepsTheStoredRefreshToken() async throws {
        let lifecycle = makeLifecycle()
        lifecycle.accessToken = "live"
        lifecycle.refreshToken = "stored"
        lifecycle.tokenExpiry = now.addingTimeInterval(300)

        lifecycle.reset(keepingRefreshToken: true)

        #expect(lifecycle.accessToken == nil)
        #expect(lifecycle.refreshToken == "stored")
    }

    // MARK: - Provider policy

    @Test func theTwoStacksScaleTheirRenewalMarginsToTheAdvertisedLifetime() {
        // Polestar issues five-minute tokens: a flat five-minute margin could never be met.
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 300) == 30)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 0) == 60)
        #expect(PolestarAPI.tokenRenewalMargin(lifetime: 3_600) == 60)

        // Volvo's half previously had no coverage at all.
        #expect(VolvoAPI.tokenRenewalMargin(lifetime: 0) == 300)
        #expect(VolvoAPI.tokenRenewalMargin(lifetime: 120) == 60)
        #expect(VolvoAPI.tokenRenewalMargin(lifetime: 3_600) == 300)
    }

    // MARK: - Harness

    private func makeLifecycle(
        minimumRegrantInterval: TimeInterval = 0,
        persist: @escaping @Sendable (String) throws -> Void = { _ in },
        isDeadGrant: @escaping @Sendable (Error) -> Bool = { _ in false }
    ) -> TokenLifecycle {
        TokenLifecycle(
            policy: .init(
                renewalMargin: { lifetime in lifetime > 0 ? min(60, max(5, lifetime * 0.1)) : 30 },
                minimumRegrantInterval: minimumRegrantInterval),
            providerName: "Test",
            persist: persist,
            isDeadGrant: isDeadGrant)
    }

    private static func grant(refreshToken: String? = "rotated") -> TokenLifecycle.Grant {
        TokenLifecycle.Grant(accessToken: "refreshed-access", refreshToken: refreshToken, expiresIn: 300)
    }
}

private struct PersistFailure: Error {}
private struct GrantRejected: Error {}

private actor GrantCounter {
    private(set) var value = 0
    func record() { value += 1 }
}

/// Lock-protected rather than an actor: the engine persists synchronously while the provider
/// actor is applying a grant, and that is a property of the interface worth testing as-is.
private final class PersistRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func record(_ token: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(token)
    }

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private actor GrantGate {
    private var arrived = false
    private var released = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func arriveAndWait() async {
        arrived = true
        arrivalWaiters.forEach { $0.resume() }
        arrivalWaiters = []
        if !released { await withCheckedContinuation { releaseWaiters.append($0) } }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivalWaiters.append($0) } }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters = []
    }
}

/// Routes the fan-out through one actor so the test's own callers are serialized the way the
/// provider's are, and counts admissions so a test can hold a grant open until the whole burst is
/// inside. The lifecycle itself is not actor-isolated – its `refresh` runs on whatever executor
/// calls it – which is why the engine guards its own decision with a lock.
private actor LifecycleHost {
    private let lifecycle: TokenLifecycle
    private var entries = 0
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    init(_ lifecycle: TokenLifecycle) { self.lifecycle = lifecycle }

    func seedSession(accessToken: String?, refreshToken: String?, at now: Date) {
        lifecycle.accessToken = accessToken
        lifecycle.refreshToken = refreshToken
        lifecycle.tokenLifetime = 300
        lifecycle.tokenExpiry = accessToken == nil ? nil : now
    }

    /// Suspends until `count` callers have been admitted to the isolated region, so a test can
    /// hold a grant open until the whole fan-out has arrived.
    func awaitEntries(_ count: Int) async {
        if entries >= count { return }
        await withCheckedContinuation { entryWaiters.append((count, $0)) }
    }

    func refresh(
        reason: TokenLifecycle.Reason,
        now: Date,
        grant: @escaping @Sendable () async throws -> TokenLifecycle.Grant
    ) async throws -> TokenLifecycle.Outcome {
        entries += 1
        let ready = entryWaiters.filter { entries >= $0.count }
        entryWaiters.removeAll { entries >= $0.count }
        ready.forEach { $0.continuation.resume() }
        return try await lifecycle.refresh(reason, now: now, epochIsCurrent: { true }, grant: grant)
    }
}
