import Foundation
import Testing
@testable import Hisingen

/// The coordinator reads the signed-in account's email off the main thread at launch, so it can
/// tell a changed account from the same one. The read used to be dropped when the coordinator's
/// generation moved meanwhile, and a vehicle switch is enough to move it.
@Suite("Account email resolution")
@MainActor
struct AccountEmailResolutionTests {
    private func makeCoordinator(email: String?) throws -> (RefreshCoordinator, PreferencesStore) {
        let defaults = UserDefaults(suiteName: "AccountEmailResolutionTests.\(UUID())")!
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())")
        if let email { try keychain.saveEmail(email) }
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)
        let coordinator = RefreshCoordinator(
            api: SettleMockProvider(),
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            scheduler: AsyncTimerLoop(),
            streaming: nil)
        return (coordinator, preferences)
    }

    private func settle(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test
    func theEmailSurvivesAVehicleSwitchDuringTheRead() async throws {
        let (coordinator, _) = try makeCoordinator(email: "owner@example.com")
        coordinator.start(preferredVIN: "YSMTEST")
        // A switch right behind the launch moves the generation before the Keychain read returns.
        coordinator.selectCar(vin: "YSMTEST2")

        #expect(await settle { coordinator.accountEmail == "owner@example.com" },
                "A vehicle switch must not discard the account email")
        coordinator.stop()
    }

    @Test
    func aSignOutDuringTheReadStillWinsOverIt() async throws {
        let (coordinator, _) = try makeCoordinator(email: "owner@example.com")
        coordinator.start(preferredVIN: "YSMTEST")
        coordinator.signOut()

        try await Task.sleep(for: .milliseconds(150))
        #expect(coordinator.accountEmail.isEmpty, "A signed-out account's email must not come back")
        coordinator.stop()
    }
}
