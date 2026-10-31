import Foundation
import Testing
@testable import Hisingen

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct VehicleSessionControllerTests {
    @Test func aRefreshDoesNotDiscardAnUnconfirmedCommandReceipt() async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults,
                                           keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        preferences.email = "test@example.invalid"
        preferences.vin = "P1"
        let store = VehicleStateStore(defaults: defaults, database: .inMemory(), preferences: preferences)
        let context = SessionTestContext()
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: SessionManager(readPassword: { "password" }, clearPassword: {}),
            providers: ProviderRegistry(polestar: SessionTestProvider(brand: .polestar),
                                        volvo: SessionTestProvider(brand: .volvo)),
            fleetStore: FleetStore(stateStore: store, preferences: preferences), observesEnvironment: false)
        defer { controller.stop() }
        controller.resume()
        _ = try await context.states.next()
        let current = try #require(controller.latest)
        let receipt = CommandReceipt(commandIdentifier: "honk-horn", issuedAt: Date(), command: .honkHorn)
        controller.beginCommandConfirmation(receipt, optimisticState: current)
        context.states.removePending()
        let previousCount = context.receivedStates
        controller.refreshNow()
        _ = try await context.states.next()
        #expect(context.receivedStates > previousCount)
        #expect(controller.latest?.commandState.receipt == receipt)
        #expect(store.database.snapshots.loadSnapshot(for: "P1")?.commandState.receipt == nil)
    }
    /// The other half of the reported silence: with notifications switched off, an expired
    /// session left the app looking signed in and never asked for a sign-in. A dead session is
    /// a state, not a notification preference.
    @Test
    func anExpiredSessionAsksForSignInEvenWithNotificationsOff() async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults,
                                           keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())"))
        var features = FeatureSelection.default
        features.set(.notifications, enabled: false)
        preferences.features = features
        preferences.email = "test@example.invalid"
        preferences.vin = "P1"
        let store = VehicleStateStore(defaults: defaults, database: .inMemory(), preferences: preferences)
        let context = SessionTestContext()
        let provider = SessionTestProvider(brand: .polestar)
        let expired = VehicleServiceError.authenticationRequired(provider: .polestar, reason: .expiredSession)
        await provider.failRestore(with: expired)
        await provider.failAuthentication(reason: .expiredSession)
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: SessionManager(readPassword: { "password" }, clearPassword: {}),
            providers: ProviderRegistry(polestar: provider, volvo: SessionTestProvider(brand: .volvo)),
            fleetStore: FleetStore(stateStore: store, preferences: preferences), observesEnvironment: false)
        defer { controller.stop() }

        controller.resume()

        _ = try await context.authentication.next()
        #expect(context.authenticationRequiredCount == 1)
        #expect(!controller.sessionValid)
    }

    @Test(arguments: [VehicleBrand.polestar, .volvo])
    func credentialChangeAdoptsPolestarAndReconcilesBeforeRestoring(from originalBrand: VehicleBrand) async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"))
        preferences.activeBrand = originalBrand
        preferences.email = "new@example.invalid"
        preferences.setVin("P1", for: .polestar)
        preferences.setVin("V1", for: .volvo)
        let store = VehicleStateStore(defaults: defaults, database: .inMemory(), preferences: preferences)
        let fleet = FleetStore(stateStore: store, preferences: preferences)
        let context = SessionTestContext()
        context.onCredentialsChanged = {
            #expect(preferences.activeBrand == .polestar)
        }
        let manager = SessionManager(readPassword: { "new-password" },
                                     clearPassword: {}, configure: { _, _ in
                                         #expect(context.reconciliations == 1)
                                     })
        let polestar = SessionTestProvider(brand: .polestar)
        let volvo = SessionTestProvider(brand: .volvo)
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: manager,
            providers: ProviderRegistry(polestar: polestar, volvo: volvo), fleetStore: fleet,
            observesEnvironment: false)
        defer { controller.stop() }
        controller.credentialsDidChange(for: .polestar)
        _ = try await context.states.next()
        #expect(controller.latest?.identity.vin == "P1")
        #expect(context.reconciliations == 1)
        #expect(await polestar.calls == ["reset", "authenticate:new@example.invalid:new-password"])
        #expect(await volvo.calls.isEmpty)
    }

    @Test
    func changingAccountsBeforeDiscoveryClearsThePreviouslyCachedVIN() throws {
        let scoped = ScopedPreferences(label: "session-rapid-account-switch")
        let preferences = scoped.store
        preferences.email = "old@example.invalid"
        preferences.vin = "P1"
        let database = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: scoped.defaults, database: database, preferences: preferences)
        let fleet = FleetStore(stateStore: store, preferences: preferences)
        store.save(vehicle(vin: "P1"))
        store.save(vehicle(vin: "V1", brand: .volvo))
        fleet.retain(vehicle(vin: "P1"))
        fleet.retain(vehicle(vin: "V1", brand: .volvo))
        let context = SessionTestContext()
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: SessionManager(readPassword: { "password" }, clearPassword: {}),
            providers: ProviderRegistry(polestar: SessionTestProvider(brand: .polestar),
                                        volvo: SessionTestProvider(brand: .volvo)),
            fleetStore: fleet, observesEnvironment: false)
        defer { controller.stop() }

        controller.resume()
        #expect(controller.latest?.identity.vin == "P1")
        preferences.email = "new@example.invalid"
        preferences.vin = "P2"
        controller.credentialsDidChange(for: .polestar)

        #expect(controller.latest == nil)
        #expect(database.snapshots.loadSnapshot(for: "P1") == nil)
        #expect(fleet.snapshot(for: "P1") == nil)
        #expect(database.snapshots.loadSnapshot(for: "V1") != nil)
    }

    @Test
    func changingAccountsClearsTheOldFleetBeforePublishingNewTelemetry() async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"))
        preferences.email = "old@example.invalid"
        preferences.vin = "P1"
        #expect(preferences.email == "old@example.invalid")
        let database = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: defaults, database: database, preferences: preferences)
        let fleet = FleetStore(stateStore: store, preferences: preferences)
        let context = SessionTestContext()
        let manager = SessionManager(readPassword: { "new-password" }, clearPassword: {})
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: manager,
            providers: ProviderRegistry(polestar: SessionTestProvider(brand: .polestar),
                                        volvo: SessionTestProvider(brand: .volvo)),
            fleetStore: fleet, observesEnvironment: false)
        defer { controller.stop() }
        controller.resume()
        _ = try await context.states.next()
        #expect(controller.latest?.identity.vin == "P1")
        fleet.retain(vehicle(vin: "P1"))
        fleet.retain(vehicle(vin: "V1", brand: .volvo))
        preferences.email = "new@example.invalid"
        preferences.vin = "P2"
        controller.credentialsDidChange(for: .polestar)
        #expect(controller.latest == nil)
        #expect(fleet.snapshot(for: "P1") == nil)
        #expect(database.snapshots.loadSnapshot(for: "P1") == nil)
        #expect(fleet.snapshot(for: "V1") != nil)
        _ = try await context.states.next()
        #expect(controller.latest?.identity.vin == "P2")
    }
}

@MainActor
private final class SessionTestContext: VehicleSessionControllerContext {
    let states = TestEvent<VehicleState>()
    let authentication = TestEvent<Void>()
    var receivedStates = 0
    var reconciliations = 0
    var authenticationRequiredCount = 0
    var onCredentialsChanged: (() -> Void)?
    func sessionStateDidChange() {}
    func showLoading() {}
    func setActiveVIN(_ vin: String?) {}
    func didReceiveVehicleState(_ state: VehicleState) {
        receivedStates += 1
        states.yield(state)
    }
    func authenticationRequired() {
        authenticationRequiredCount += 1
        authentication.yield(())
    }
    func authenticationSucceeded() {}
    func vehicleSwitchDidPause() {}
    func sessionDidEstablish() {}
    func sessionCredentialsDidChange() {
        reconciliations += 1
        onCredentialsChanged?()
    }
}
