import Foundation
import Testing
@testable import Hisingen

@MainActor
struct RefreshCoordinatorTests {
    @Test
    func testConcurrentManualRefreshesCoalesceWithLaunchRefresh() async throws {
        let oldVIN = Preferences.vin
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            Preferences.vin = oldVIN
            defaults.removePersistentDomain(forName: suiteName)
        }
        Preferences.vin = "YSMTEST"
        let provider = MockVehicleProvider()
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            clearPasswordAfterSession: {}
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
}

private actor MockVehicleProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle")]
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


