import Foundation
import Testing
@testable import Hisingen

@MainActor
struct RefreshCoordinatorTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func testConcurrentManualRefreshesCoalesceWithLaunchRefresh() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMTEST"
        let provider = MockVehicleProvider()
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            clearPasswordAfterSession: {},
            readStoredSessionToken: { nil },
            readStoredPassword: { nil }
        )
        await withCheckedContinuation { continuation in
            coordinator.onState = { _ in continuation.resume() }
            coordinator.start(email: "test@example.invalid", password: nil,
                              sessionToken: "test-session", preferredVIN: "YSMTEST")
            coordinator.refreshNow()
            coordinator.refreshNow()
        }

        let fetchCount = await provider.fetchCount
        XCTAssertEqual(fetchCount, 1)
        coordinator.stop()
    }

    /// Regression for the permanent authentication-failure loop: after a successful session
    /// the coordinator drops its in-memory credentials by design. When the access token later
    /// expires mid-run, `beginSession` must recover the refresh token from storage instead of
    /// throwing `.noStoredSession` forever.
    @Test
    func testTokenExpiryMidRunRecoversSessionFromStorage() async throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.vin = "YSMTEST"
        let provider = RecoveryMockProvider()
        let storedToken: String? = "stored-refresh-token"
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            imageCache: CarImageCache(),
            preferences: preferences,
            clearPasswordAfterSession: {},
            // Simulates the Keychain-backed token that outlives a successful session.
            readStoredSessionToken: { storedToken },
            readStoredPassword: { nil },
            // Collapse production backoff (minutes at the top of its curve) so the
            // expiry→recovery cycle completes in milliseconds.
            retryDelay: { _, _, _ in 0.05 }
        )

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coordinator.onState = { _ in continuation.resume() }
            coordinator.start(email: "test@example.invalid", password: nil,
                              sessionToken: nil, preferredVIN: "YSMTEST")
        }

        // Simulate mid-run access-token expiry: the next fetch fails as an auth problem and
        // the coordinator must re-enter via the *stored* token, not wedge on `.noStoredSession`.
        await provider.expireSession()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            coordinator.onState = { _ in continuation.resume() }
            coordinator.refreshNow()
        }

        let restoreCount = await provider.restoreCount
        XCTAssertEqual(restoreCount, 2, "Expected the coordinator to recover from storage after expiry")
        coordinator.stop()
    }
}

private actor MockVehicleProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
    var hasWarmSession: Bool { true }
    private(set) var fetchCount = 0

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? cars.first?.vin }
    func selectCar(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        try await Task.sleep(nanoseconds: 50_000_000)
        return vehicle(vin: vin)
    }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}

/// Provider whose first restore succeeds; after `expireSession()` every fetch fails with an
/// auth error until the coordinator restores again — mirroring a real token expiry.
private actor RecoveryMockProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
    var hasWarmSession: Bool { !expired }
    private(set) var expired = false
    private(set) var restoreCount = 0

    init() {}

    func expireSession() { expired = true }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? "YSMTEST" }
    func selectCar(vin: String, features: FeatureSelection) async throws {}

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        guard !token.isEmpty else {
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .noStoredSession)
        }
        restoreCount += 1
        expired = false
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        if expired {
            throw VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        }
        return vehicle(vin: vin)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
