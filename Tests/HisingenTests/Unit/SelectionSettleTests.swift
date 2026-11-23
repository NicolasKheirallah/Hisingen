import Foundation
import Testing
@testable import Hisingen

/// `selectionSettled` is the awaited seam for "this VIN is selected and its telemetry
/// applied". These tests pin the wake-on-completion behavior deterministically: no polling,
/// no wall-clock budgets beyond the injected scheduler's own sleeps.
@Suite("SelectionSettle")
@MainActor
struct SelectionSettleTests {

    @Test func returnsImmediatelyWhenTheSelectionIsAlreadySettled() async throws {
        let provider = SettleMockProvider()
        let coordinator = makeCoordinator(provider: provider)
        // No selection has ever run: the VIN is unknown, so not settled.
        let settled = await coordinator.selectionSettled(vin: "YSMTEST", timeout: 0.2)
        #expect(!settled)
    }

    @Test func wakesTrueWhenTheSelectionApplies() async throws {
        let provider = SettleMockProvider()
        let coordinator = makeCoordinator(provider: provider)
        coordinator.selectCar(vin: "YSMTEST")
        let settled = await coordinator.selectionSettled(vin: "YSMTEST", timeout: 30)
        #expect(settled)
        let fetches = await provider.fetchCount
        #expect(fetches >= 1)
        coordinator.stop()
    }

    @Test func wakesFalseWhenTheSelectionFails() async throws {
        let provider = SettleMockProvider()
        await provider.failFetch()
        let coordinator = makeCoordinator(provider: provider)
        coordinator.selectCar(vin: "YSMTEST")
        let settled = await coordinator.selectionSettled(vin: "YSMTEST", timeout: 30)
        #expect(!settled)
        coordinator.stop()
    }

    @Test func aSupersedingSelectionReleasesTheEarlierWaiter() async throws {
        let provider = SettleMockProvider()
        await provider.holdFetch()
        let coordinator = makeCoordinator(provider: provider)
        coordinator.selectCar(vin: "YSMTEST")

        let firstTask = Task { await coordinator.selectionSettled(vin: "YSMTEST", timeout: 30) }
        // Give the first waiter time to register before superseding it.
        try await Task.sleep(for: .milliseconds(50))
        coordinator.selectCar(vin: "YSMTEST2")
        let firstOutcome = await firstTask.value
        #expect(!firstOutcome)

        await provider.releaseFetch()
        coordinator.stop()
    }

    /// A brand switch is served by `beginSession`, never by the selection task. Its first state
    /// must still answer the waiter instead of leaving it to the timeout.
    @Test func wakesTrueWhenASessionStartAppliesTheTarget() async throws {
        let provider = SettleMockProvider()
        await provider.holdFetch()
        let coordinator = makeCoordinator(provider: provider)
        coordinator.start(preferredVIN: "YSMTEST")

        let waiter = Task { await coordinator.selectionSettled(vin: "YSMTEST", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        await provider.releaseFetch()
        #expect(await waiter.value)
        coordinator.stop()
    }

    /// A command for the car that is already selected, arriving while a poll is in flight, waits
    /// on that poll. The poll ending is what answers it.
    @Test func wakesTrueWhenAnOrdinaryRefreshEndsOnTheSelectedCar() async throws {
        let provider = SettleMockProvider()
        let coordinator = makeCoordinator(provider: provider)
        coordinator.start(preferredVIN: "YSMTEST")
        #expect(await coordinator.selectionSettled(vin: "YSMTEST", timeout: 5))

        await provider.holdFetch()
        coordinator.refreshNow()
        #expect(coordinator.isBusy)
        let waiter = Task { await coordinator.selectionSettled(vin: "YSMTEST", timeout: 5) }
        try await Task.sleep(for: .milliseconds(100))
        await provider.releaseFetch()
        #expect(await waiter.value)
        coordinator.stop()
    }

    /// With nothing in flight and nothing pending, a car that is not loaded cannot become
    /// loaded, so the waiter is told at once rather than after its timeout.
    @Test func answersFalseAtOnceWhenNothingCouldSettleTheCar() async throws {
        let provider = SettleMockProvider()
        let coordinator = makeCoordinator(provider: provider)
        let started = Date()
        let settled = await coordinator.selectionSettled(vin: "YSMTEST", timeout: 30)
        #expect(!settled)
        #expect(Date().timeIntervalSince(started) < 5)
        coordinator.stop()
    }

    @MainActor
    private func makeCoordinator(provider: SettleMockProvider) -> RefreshCoordinator {
        let defaults = UserDefaults(suiteName: "SelectionSettleTests.\(UUID())")!
        let preferences = PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: VehicleStateStore(defaults: defaults, database: .inMemory()),
            observesEnvironment: false,
            preferences: preferences,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            scheduler: AsyncTimerLoop(),
            streaming: nil)
        return coordinator
    }
}

private actor SettleMockProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    let cars = [CarSummary(vin: "YSMTEST", title: "Test vehicle"),
                CarSummary(vin: "YSMTEST2", title: "Second test vehicle")]
    var hasWarmSession: Bool { true }
    private(set) var fetchCount = 0
    private var shouldFail = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var isHeld = false

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) -> String? { preferred ?? cars.first?.vin }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}

    func failFetch() { shouldFail = true }

    func holdFetch() { isHeld = true }

    func releaseFetch() {
        isHeld = false
        heldContinuations.forEach { $0.resume() }
        heldContinuations.removeAll()
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        fetchCount += 1
        if isHeld {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                heldContinuations.append(continuation)
            }
        }
        if shouldFail {
            throw VehicleServiceError.rateLimited(retryAfter: 60)
        }
        return vehicle(vin: vin)
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        RemoteCommandResult(outcome: .completed, message: nil)
    }
}
