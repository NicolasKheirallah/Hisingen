import Foundation
import Testing
@testable import Hisingen

/// Regression coverage for same-account, same-brand multi-vehicle selection.
///
/// The original failure: with two cars on one brand's account the switcher locked up after
/// a single use. `statusController.activeVin` was only ever synced from `onCars` (fired by
/// session establishment, never by a switch), so the UI-level `vin != activeVin` guard kept
/// vetoing switches BACK to the launch vehicle while `RefreshCoordinator`'s own
/// `vin != preferences.vin` guard vetoed repeating the forward switch — and every path
/// (chips, switcher menu, ⌃⌥[ / ⌃⌥] cycling, context menu) funnels through those guards.
@MainActor
struct MultiVehicleSelectionTests {
    private static let vinA = "YV1AAAA1111111111"
    private static let vinB = "YV2BBBB2222222222"

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @discardableResult
    private func makeCoordinator(
        provider: TwoCarProvider,
        defaults: UserDefaults,
        preferences: PreferencesStore,
        selectionRetryDelay: TimeInterval = 0.05
    ) -> RefreshCoordinator {
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            clearPasswordAfterSession: {},
            readStoredSessionToken: { nil },
            readStoredPassword: { nil },
            retryDelay: { _, _, _ in 0.01 },
            selectionRetryDelay: selectionRetryDelay
        )
        return coordinator
    }

    /// One-shot continuation helper: resumes exactly once, on the first matching event.
    private final class OnceBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }
        func resume(_ value: T) {
            lock.lock(); defer { lock.unlock() }
            guard let pending = continuation else { return }
            continuation = nil
            pending.resume(returning: value)
        }
    }

    private func awaitState(
        _ coordinator: RefreshCoordinator, vin: String? = nil
    ) async -> VehicleState {
        await withCheckedContinuation { (continuation: CheckedContinuation<VehicleState, Never>) in
            let box = OnceBox(continuation)
            coordinator.onState = { state in
                if let vin, state.vin != vin { return }
                box.resume(state)
            }
        }
    }

    private func awaitError(_ coordinator: RefreshCoordinator) async -> VehicleServiceError {
        await withCheckedContinuation { (continuation: CheckedContinuation<VehicleServiceError, Never>) in
            let box = OnceBox(continuation)
            coordinator.onError = { error in box.resume(error) }
        }
    }

    @Test
    func switchingBetweenTwoSameAccountCarsWorksRoundTrip() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = Self.vinA
        let provider = TwoCarProvider(vins: [Self.vinA, Self.vinB])
        let coordinator = makeCoordinator(provider: provider, defaults: defaults, preferences: preferences)

        var selections: [String] = []
        coordinator.onSelectionChanged = { selections.append($0) }
        var switchPendingFlags: [Bool] = []
        coordinator.onDiagnostics = { switchPendingFlags.append($0.vehicleSwitchPending) }

        coordinator.start(email: "test@example.invalid", password: nil,
                          sessionToken: "test-session", preferredVIN: Self.vinA)
        _ = await awaitState(coordinator, vin: Self.vinA)
        XCTAssertEqual(preferences.vin, Self.vinA)

        // Forward switch.
        coordinator.selectCar(vin: Self.vinB)
        let stateB = await awaitState(coordinator, vin: Self.vinB)
        XCTAssertEqual(stateB.vin, Self.vinB)
        XCTAssertEqual(preferences.vin, Self.vinB)

        // Switch back — this was the direction permanently blocked before the fix.
        coordinator.selectCar(vin: Self.vinA)
        let stateA = await awaitState(coordinator, vin: Self.vinA)
        XCTAssertEqual(stateA.vin, Self.vinA)
        XCTAssertEqual(preferences.vin, Self.vinA)

        let orderRoundTrip = await provider.selectionOrder
        XCTAssertEqual(orderRoundTrip, [Self.vinB, Self.vinA])
        XCTAssertTrue(selections.contains(Self.vinB))
        XCTAssertTrue(selections.contains(Self.vinA))

        // Diagnostics must expose an unresolved switch (support-bundle visibility for
        // exactly the state where the original lockup lived) and settle to false once
        // the last selection resolves.
        XCTAssertTrue(switchPendingFlags.contains(true), "Switch-in-progress must be visible in diagnostics")
        if let lastFlag = switchPendingFlags.last {
            XCTAssertFalse(lastFlag, "Diagnostics must report the switch as resolved afterwards")
        }
        coordinator.stop()
    }

    @Test
    func retryingAFailedSwitchIsAllowed() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = Self.vinA
        let provider = TwoCarProvider(vins: [Self.vinA, Self.vinB])
        // First attempt to select B fails terminally; the optimistic preferences write has
        // already happened at that point, so the old `vin != preferences.vin` guard made a
        // manual retry a silent no-op and the user could never reach car B again.
        await provider.setFailingVIN(Self.vinB)
        let coordinator = makeCoordinator(provider: provider, defaults: defaults, preferences: preferences)

        coordinator.start(email: "test@example.invalid", password: nil,
                          sessionToken: "test-session", preferredVIN: Self.vinA)
        _ = await awaitState(coordinator, vin: Self.vinA)

        coordinator.selectCar(vin: Self.vinB)
        let error = await awaitError(coordinator)
        guard case .notConfigured = error else {
            Issue.record("Expected terminal notConfigured error, got \(error)")
            return
        }
        XCTAssertEqual(preferences.vin, Self.vinB, "Selection is recorded optimistically")
        let attemptsBeforeRetry = await provider.selectCount
        XCTAssertTrue(attemptsBeforeRetry > 1, "The coordinator retried the raced selection before surfacing the error")

        // The user clicks the same car again: the retry must run, not be swallowed.
        // (Under the old guard this click was a silent no-op because the optimistic
        // `preferences.vin` write had already recorded car B.)
        await provider.setFailingVIN(nil)
        coordinator.selectCar(vin: Self.vinB)
        _ = await awaitState(coordinator, vin: Self.vinB)
        XCTAssertEqual(preferences.vin, Self.vinB)
        let attemptsAfterRetry = await provider.selectCount
        XCTAssertEqual(attemptsAfterRetry, attemptsBeforeRetry + 1, "Exactly one more provider attempt")
        coordinator.stop()
    }

    @Test
    func racedSelectionAutoRecoversWithoutTerminalError() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = Self.vinA
        let provider = TwoCarProvider(vins: [Self.vinA, Self.vinB])
        await provider.setFailingVIN(Self.vinB, onceOnly: true)
        let coordinator = makeCoordinator(provider: provider, defaults: defaults, preferences: preferences,
                                          selectionRetryDelay: 0.02)

        var surfacedErrors: [VehicleServiceError] = []
        coordinator.onError = { surfacedErrors.append($0) }

        coordinator.start(email: "test@example.invalid", password: nil,
                          sessionToken: "test-session", preferredVIN: Self.vinA)
        _ = await awaitState(coordinator, vin: Self.vinA)

        // The first selectCar fails with notConfigured (the shape Polestar reports when the
        // background garage scan flips the shared selection mid-discovery). The coordinator
        // must retry on its own instead of dead-ending the refresh loop.
        coordinator.selectCar(vin: Self.vinB)
        let stateB = await awaitState(coordinator, vin: Self.vinB)
        XCTAssertEqual(stateB.vin, Self.vinB)
        XCTAssertEqual(preferences.vin, Self.vinB)
        let attemptsRaced = await provider.selectCount
        XCTAssertEqual(attemptsRaced, 2, "Expected exactly one automatic retry after the raced failure")
        XCTAssertTrue(surfacedErrors.isEmpty, "Transient race must not surface as an error")
        coordinator.stop()
    }

    @Test
    func selectingTheSettledCurrentCarIsANoOp() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = Self.vinA
        let provider = TwoCarProvider(vins: [Self.vinA, Self.vinB])
        let coordinator = makeCoordinator(provider: provider, defaults: defaults, preferences: preferences)

        coordinator.start(email: "test@example.invalid", password: nil,
                          sessionToken: "test-session", preferredVIN: Self.vinA)
        _ = await awaitState(coordinator, vin: Self.vinA)
        let selectsBefore = await provider.selectCount
        let fetchesBefore = await provider.fetchCount

        coordinator.selectCar(vin: Self.vinA)
        try await Task.sleep(for: .milliseconds(120))

        let selectsAfter = await provider.selectCount
        let fetchesAfter = await provider.fetchCount
        XCTAssertEqual(selectsAfter, selectsBefore, "Settled re-selection must not hit the provider")
        XCTAssertEqual(fetchesAfter, fetchesBefore)
        XCTAssertEqual(preferences.vin, Self.vinA)
        coordinator.stop()
    }
}

/// Two-vehicle provider with injectable per-VIN selection failures.
private actor TwoCarProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let vins: [String]
    private(set) var selectionOrder: [String] = []
    private(set) var selectCount = 0
    private(set) var fetchCount = 0
    var failingVIN: String?
    var failOnlyOnce = false

    init(vins: [String]) { self.vins = vins }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, vins.contains(preferred) { return preferred }
        return vins.first
    }

    func selectCar(vin: String, features: FeatureSelection) async throws {
        selectCount += 1
        if vin == failingVIN {
            if failOnlyOnce { failingVIN = nil } else { selectionOrder.append(vin) }
            throw PolestarError.notConfigured
        }
        selectionOrder.append(vin)
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        try await Task.sleep(nanoseconds: 20_000_000)
        return vehicle(vin: vin)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }

    func setFailingVIN(_ vin: String?, onceOnly: Bool = false) {
        failingVIN = vin
        failOnlyOnce = onceOnly
    }
}
