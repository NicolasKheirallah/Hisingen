import Foundation
import Testing
@testable import Hisingen

/// Sign-out is account-level in the providers, but the app should not drop a reader at the
/// login panel while another car is registered. These cover the three-way decision: a sibling
/// on the same account, another connected brand, and only then the login screen.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VehicleSignOutFallbackTests {
    private static let polestarOne = "YS2E1111111111111"
    private static let polestarTwo = "YS2E2222222222222"
    private static let volvoOne = "YV1A1111111111111"

    // MARK: - Same account

    @Test
    func aSiblingKeepsTheAccountAndBecomesTheActiveVehicle() async throws {
        let harness = try Harness(active: .polestar,
                                  cars: [.polestar: [Self.polestarOne, Self.polestarTwo],
                                         .volvo: []])
        defer { harness.controller.stop() }

        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.fleet.updateCars([
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])

        #expect(harness.controller.signOutPlan()
                == .disconnectVehicle(vin: Self.polestarOne, nextVIN: Self.polestarTwo))

        let outcome = harness.controller.signOut()
        #expect(outcome == .vehicleDisconnected(vin: Self.polestarOne))
        #expect(harness.preferences.isVehicleDetached(Self.polestarOne))
        #expect(harness.preferences.detachedVehicles(for: .polestar).map(\.vin) == [Self.polestarOne])
        #expect(harness.preferences.vin == Self.polestarTwo)
        #expect(!harness.preferences.hasExplicitSignOut(for: .polestar))
        #expect(harness.store.snapshot(for: Self.polestarOne) == nil)
        #expect(harness.fleet.knownVINs(for: .polestar) == [Self.polestarTwo])

        let state = try await harness.context.states.next()
        #expect(state.identity.vin == Self.polestarTwo)
        #expect(harness.controller.latest?.identity.vin == Self.polestarTwo)
        #expect(!harness.controller.signInRequired)
    }

    @Test
    func bringingABackVehicleBackRestoresTheSelection() async throws {
        let harness = try Harness(active: .polestar,
                                  cars: [.polestar: [Self.polestarOne, Self.polestarTwo],
                                         .volvo: []])
        defer { harness.controller.stop() }

        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.preferences.setVehicleNickname("One", for: Self.polestarOne)
        harness.preferences.setTheme(.charcoalGold, for: Self.polestarOne, brand: .polestar)
        harness.fleet.updateCars([
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])
        _ = harness.controller.signOut()
        _ = try await harness.context.states.next()

        // A deep link or old notification naming the signed-out car must not quietly re-add it.
        #expect(harness.controller.selectVehicle(vin: Self.polestarOne) == false)
        #expect(harness.preferences.isVehicleDetached(Self.polestarOne))
        #expect(harness.preferences.vin == Self.polestarTwo)
        // Bring Back is the explicit path, and it keeps the name and colour the reader chose.
        #expect(harness.preferences.vehicleNickname(for: Self.polestarOne) == "One")
        #expect(harness.preferences.theme(for: Self.polestarOne, brand: .polestar) == .charcoalGold)

        harness.controller.reconnectVehicle(vin: Self.polestarOne)

        #expect(!harness.preferences.isVehicleDetached(Self.polestarOne))
        #expect(harness.preferences.vin == Self.polestarOne)
        let state = try await harness.context.states.next()
        #expect(state.identity.vin == Self.polestarOne)
    }

    @Test
    func aSiblingDiscoveredInAnEarlierSessionIsStillKnownAfterRelaunch() throws {
        let harness = Harness(active: .polestar,
                              cars: [.polestar: [Self.polestarOne, Self.polestarTwo],
                                     .volvo: []])
        defer { harness.controller.stop() }

        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.fleet.updateCars([
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])
        #expect(harness.preferences.knownVINs(for: .polestar).contains(Self.polestarTwo))

        // A fresh launch has no in-memory car list, only the persisted set.
        let relaunchedFleet = FleetStore(stateStore: harness.store, preferences: harness.preferences)
        let relaunchedContext = SignOutContext()
        let relaunched = VehicleSessionController(
            context: relaunchedContext,
            preferences: harness.preferences,
            stateStore: harness.store,
            imageCache: CarImageCache(),
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
            providers: ProviderRegistry(
                polestar: SignOutProvider(brand: .polestar, vins: []),
                volvo: SignOutProvider(brand: .volvo, vins: []),
                preferences: harness.preferences
            ),
            fleetStore: relaunchedFleet,
            observesEnvironment: false
        )
        defer { relaunched.stop() }

        #expect(relaunched.signOutPlan()
                == .disconnectVehicle(vin: Self.polestarOne, nextVIN: Self.polestarTwo))
    }

    @Test
    func signingOutTheEntireAccountIsStillPossibleWithASibling() throws {
        let harness = Harness(active: .polestar,
                              cars: [.polestar: [Self.polestarOne, Self.polestarTwo],
                                     .volvo: []])
        defer { harness.controller.stop() }

        // The Volvo presence bits are app-wide; a prior test must not turn this into a fallback.
        try harness.keychain.deleteVolvoSessionToken()
        try harness.keychain.deleteVolvoClientSecret()
        try harness.keychain.deleteVolvoApiKey()
        harness.preferences.invalidateSessionCache()
        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.fleet.updateCars([
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])

        let outcome = harness.controller.signOut(forceAccount: true)

        #expect(outcome == .signedOut)
        #expect(harness.preferences.hasExplicitSignOut(for: .polestar))
        #expect(harness.preferences.vin(for: .polestar).isEmpty)
        #expect(!harness.preferences.isVehicleDetached(Self.polestarOne))
        #expect(harness.preferences.detachedVehicles(for: .polestar).isEmpty)
    }

    // MARK: - Another brand

    @Test
    func anotherConnectedBrandUsesItsStoredVehicleInsteadOfTheLoginScreen() async throws {
        let harness = try Harness(active: .polestar,
                                  cars: [.polestar: [Self.polestarOne],
                                         .volvo: [Self.volvoOne]])
        defer { harness.controller.stop() }

        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.preferences.setVin(Self.volvoOne, for: .volvo)
        harness.preferences.volvoClientID = "test-client"
        try harness.keychain.saveVolvoClientSecret("test-secret")
        try harness.keychain.saveVolvoApiKey("test-api-key")
        try harness.keychain.saveVolvoSessionToken("volvo-refresh")
        harness.preferences.invalidateSessionCache()

        #expect(harness.controller.signOutPlan()
                == .signOutAccount(fallback: SignOutFallback(brand: .volvo, vin: Self.volvoOne)))

        let outcome = harness.controller.signOut()
        #expect(outcome == .switchedToBrand(
            .volvo, vin: Self.volvoOne, signedOutVINs: [Self.polestarOne]))
        #expect(harness.preferences.activeBrand == .volvo)
        #expect(harness.preferences.vin(for: .volvo) == Self.volvoOne)
        #expect(harness.preferences.vin(for: .polestar).isEmpty)
        #expect(harness.preferences.hasExplicitSignOut(for: .polestar))
        #expect(!harness.controller.signInRequired)

        let state = try await harness.context.states.next()
        #expect(state.identity.vin == Self.volvoOne)
        #expect(harness.controller.latest?.identity.vin == Self.volvoOne)
    }

    @Test
    func noRegisteredVehicleFallsBackToTheLoginScreen() throws {
        let harness = Harness(active: .polestar, cars: [.polestar: [Self.polestarOne], .volvo: []])
        defer { harness.controller.stop() }

        // The Volvo presence bits are app-wide UserDefaults, not per-suite; a prior test that
        // saved a Volvo session must not turn this case into a fallback.
        try harness.keychain.deleteVolvoSessionToken()
        try harness.keychain.deleteVolvoClientSecret()
        try harness.keychain.deleteVolvoApiKey()
        harness.preferences.invalidateSessionCache()
        harness.preferences.setVin(Self.polestarOne, for: .polestar)

        #expect(harness.controller.signOutPlan() == .signOutAccount(fallback: nil))
        #expect(harness.controller.signOut() == .signedOut)
        #expect(harness.preferences.activeBrand == .polestar)
        #expect(harness.preferences.hasExplicitSignOut(for: .polestar))
        #expect(harness.controller.signInRequired)
    }

    @Test
    func theSignOutScopeFollowsTheLiveFleetNotTheWindowSnapshot() {
        let scoped = ScopedPreferences(label: "sign-out-scope")
        scoped.store.activeBrand = .polestar
        scoped.store.setVin(Self.polestarOne, for: .polestar)

        let twoCars = FleetSnapshot(cars: [
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])
        let oneCar = FleetSnapshot(cars: [
            CarSummary(vin: Self.polestarOne, title: "One")
        ])

        guard case .vehicle = SignOutScopeResolver.scope(
            fleet: twoCars, preferences: scoped.store) else {
            Issue.record("Two cars should sign out one vehicle")
            return
        }
        #expect(SignOutScopeResolver.scope(fleet: oneCar, preferences: scoped.store) == .account)
    }

    // MARK: - Detached vehicles stay out of the fleet

    @Test
    func aDetachedVehicleIsHiddenFromTheFleetAndTheGarage() {
        let harness = Harness(active: .polestar, cars: [.polestar: [Self.polestarOne], .volvo: []])
        defer { harness.controller.stop() }

        harness.preferences.setVin(Self.polestarOne, for: .polestar)
        harness.preferences.detachVehicle(
            vin: Self.polestarOne, brand: .polestar, title: "My car")
        harness.fleet.updateCars([
            CarSummary(vin: Self.polestarOne, title: "One"),
            CarSummary(vin: Self.polestarTwo, title: "Two")
        ])
        harness.fleet.retain(vehicle(vin: Self.polestarOne))

        #expect(harness.fleet.snapshot(for: Self.polestarOne) == nil)
        #expect(harness.fleet.knownVINs(for: .polestar) == [Self.polestarTwo])
        #expect(harness.fleet.snapshot().vehicles.contains(Self.polestarOne) == false)
    }

    // MARK: - Revocation outlives the coordinator

    @Test
    func stoppingTheCoordinatorDuringAFallbackDoesNotCancelSignOut() async throws {
        let scoped = ScopedPreferences(label: "sign-out-revocation")
        let store = VehicleStateStore(
            defaults: scoped.defaults, database: .inMemory(), preferences: scoped.store)
        let provider = RevocationProbeProvider()
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: store,
            observesEnvironment: false,
            preferences: scoped.store,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {})
        )
        defer { coordinator.stop() }

        coordinator.signOut()
        // A fallback brand switch retires this coordinator immediately.
        coordinator.stop()

        for _ in 0..<100 {
            if await provider.signOutCalled { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await provider.signOutCalled)
    }

    @Test
    func aRevocationFailureIsReportedAfterTheCoordinatorIsRetired() async throws {
        let scoped = ScopedPreferences(label: "sign-out-revocation-failure")
        let store = VehicleStateStore(
            defaults: scoped.defaults, database: .inMemory(), preferences: scoped.store)
        let provider = FailingRevocationProvider()
        let coordinator = RefreshCoordinator(
            api: provider,
            stateStore: store,
            observesEnvironment: false,
            preferences: scoped.store,
            sessionManager: SessionManager(readPassword: { nil }, clearPassword: {})
        )
        defer { coordinator.stop() }
        let failure = TestEvent<VehicleBrand>()
        coordinator.onSignOutRevocationFailure = { brand in failure.yield(brand) }

        coordinator.signOut()
        // The fallback brand has already replaced this coordinator.
        coordinator.stop()

        let brand = try await failure.next()
        #expect(brand == .polestar)
    }

    // MARK: - Harness

    @MainActor
    private final class Harness {
        private let scoped: ScopedPreferences
        let preferences: PreferencesStore
        let keychain: KeychainStore
        let store: VehicleStateStore
        let fleet: FleetStore
        let context: SignOutContext
        let controller: VehicleSessionController

        init(active: VehicleBrand, cars: [VehicleBrand: [String]]) {
            let scoped = ScopedPreferences(label: "sign-out")
            self.scoped = scoped
            preferences = scoped.store
            keychain = scoped.keychain
            preferences.activeBrand = active
            store = VehicleStateStore(
                defaults: scoped.defaults, database: .inMemory(), preferences: preferences)
            fleet = FleetStore(stateStore: store, preferences: preferences)
            context = SignOutContext()
            controller = VehicleSessionController(
                context: context,
                preferences: preferences,
                stateStore: store,
                imageCache: CarImageCache(),
                sessionManager: SessionManager(readPassword: { nil }, clearPassword: {}),
                providers: ProviderRegistry(
                    polestar: SignOutProvider(brand: .polestar, vins: cars[.polestar] ?? []),
                    volvo: SignOutProvider(brand: .volvo, vins: cars[.volvo] ?? []),
                    preferences: preferences
                ),
                fleetStore: fleet,
                observesEnvironment: false
            )
        }
    }
}

@MainActor
private final class SignOutContext: VehicleSessionControllerContext {
    let states = TestEvent<VehicleState>()
    func sessionStateDidChange() {}
    func showLoading() {}
    func setActiveVIN(_ vin: String?) {}
    func didReceiveVehicleState(_ state: VehicleState) { states.yield(state) }
    func authenticationRequired() {}
    func authenticationSucceeded() {}
    func signOutRevocationFailed(brand: VehicleBrand) {}
    func vehicleSwitchDidPause() {}
    func sessionDidEstablish() {}
    func sessionCredentialsDidChange() {}
}

private actor SignOutProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand
    private let vins: [String]

    init(brand: VehicleBrand, vins: [String]) {
        self.brand = brand
        self.vins = vins
    }

    var cars: [CarSummary] { vins.map { CarSummary(vin: $0, title: $0) } }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?,
                      features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws {}
    func resolvedVIN(preferred: String?) async -> String? {
        if let preferred, vins.contains(preferred) { return preferred }
        return vins.first
    }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin, brand: brand)
    }
    func executeRemoteCommand(
        _ command: RemoteCommand, vin: String
    ) async throws -> RemoteCommandResult {
        .init(outcome: .completed, message: nil)
    }
}

private actor RevocationProbeProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar
    private(set) var signOutCalled = false

    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?,
                      features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws { signOutCalled = true }
    func resolvedVIN(preferred: String?) async -> String? { nil }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(
        _ command: RemoteCommand, vin: String
    ) async throws -> RemoteCommandResult {
        .init(outcome: .completed, message: nil)
    }
}

private actor FailingRevocationProvider: VehicleProviding {
    nonisolated let brand: VehicleBrand = .polestar

    var cars: [CarSummary] { [] }
    var hasWarmSession: Bool { true }

    func authenticate(email: String, password: String, preferredVIN: String?,
                      features: FeatureSelection) async throws {}
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {}
    func resetSession() async {}
    func signOut() async throws { throw VehicleServiceError.secureStorage }
    func resolvedVIN(preferred: String?) async -> String? { nil }
    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {}
    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        vehicle(vin: vin)
    }
    func executeRemoteCommand(
        _ command: RemoteCommand, vin: String
    ) async throws -> RemoteCommandResult {
        .init(outcome: .completed, message: nil)
    }
}
