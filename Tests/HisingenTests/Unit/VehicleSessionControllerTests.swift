import Foundation
import Testing
@testable import Hisingen

@MainActor
struct VehicleSessionControllerTests {
    @Test func aRefreshDoesNotDiscardAnUnconfirmedCommandReceipt() async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.email = "test@example.invalid"
        preferences.vin = "P1"
        let store = VehicleStateStore(defaults: defaults, database: .inMemory(), preferences: preferences)
        let context = SessionTestContext()
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: SessionManager(readToken: { _ in "token" }, readPassword: { "password" }, clearPassword: {}),
            polestarAPI: SessionTestProvider(brand: .polestar), volvoAPI: SessionTestProvider(brand: .volvo),
            fleetStore: FleetStore(stateStore: store, preferences: preferences), observesEnvironment: false)
        defer { controller.stop() }
        controller.resume()
        for _ in 0..<200 where controller.latest == nil { try await Task.sleep(for: .milliseconds(10)) }
        let current = try #require(controller.latest)
        let receipt = CommandReceipt(commandIdentifier: "honk-horn", issuedAt: Date(), command: .honkHorn)
        controller.beginCommandConfirmation(receipt, optimisticState: current)
        let previousCount = context.receivedStates
        controller.refreshNow()
        for _ in 0..<200 where context.receivedStates == previousCount { try await Task.sleep(for: .milliseconds(10)) }
        #expect(context.receivedStates > previousCount)
        #expect(controller.latest?.commandState.receipt == receipt)
        #expect(store.database.loadSnapshot(for: "P1")?.commandState.receipt == nil)
    }
    @Test(arguments: [VehicleBrand.polestar, .volvo])
    func credentialChangeAdoptsPolestarAndReconcilesBeforeRestoring(from originalBrand: VehicleBrand) async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
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
        let manager = SessionManager(readToken: { _ in "old-token" }, readPassword: { "new-password" },
                                     clearPassword: {}, configure: { _, _ in
                                         #expect(context.reconciliations == 1)
                                     })
        let polestar = SessionTestProvider(brand: .polestar)
        let volvo = SessionTestProvider(brand: .volvo)
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: manager, polestarAPI: polestar, volvoAPI: volvo, fleetStore: fleet,
            observesEnvironment: false)
        defer { controller.stop() }
        controller.credentialsDidChange(for: .polestar)
        for _ in 0..<200 where controller.latest == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.latest?.identity.vin == "P1")
        #expect(context.reconciliations == 1)
        #expect(await polestar.calls == ["reset", "authenticate:new@example.invalid:new-password"])
        #expect(await volvo.calls.isEmpty)
    }

    @Test
    func changingAccountsClearsTheOldFleetBeforePublishingNewTelemetry() async throws {
        let suite = "VehicleSessionControllerTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.email = "old@example.invalid"
        preferences.vin = "P1"
        let database = VehicleDatabase.inMemory()
        let store = VehicleStateStore(defaults: defaults, database: database, preferences: preferences)
        let fleet = FleetStore(stateStore: store, preferences: preferences)
        let context = SessionTestContext()
        let manager = SessionManager(readToken: { _ in "token" }, readPassword: { "new-password" }, clearPassword: {})
        let controller = VehicleSessionController(
            context: context, preferences: preferences, stateStore: store, imageCache: CarImageCache(),
            sessionManager: manager, polestarAPI: SessionTestProvider(brand: .polestar),
            volvoAPI: SessionTestProvider(brand: .volvo), fleetStore: fleet, observesEnvironment: false)
        defer { controller.stop() }
        controller.resume()
        for _ in 0..<200 where controller.latest == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.latest?.identity.vin == "P1")
        fleet.retain(vehicle(vin: "P1"))
        fleet.retain(vehicle(vin: "V1", brand: .volvo))
        preferences.email = "new@example.invalid"
        preferences.vin = "P2"
        controller.credentialsDidChange(for: .polestar)
        #expect(controller.latest == nil)
        #expect(fleet.snapshot(for: "P1") == nil)
        #expect(database.loadSnapshot(for: "P1") == nil)
        #expect(fleet.snapshot(for: "V1") != nil)
        for _ in 0..<200 where controller.latest == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.latest?.identity.vin == "P2")
    }
}

@MainActor
private final class SessionTestContext: VehicleSessionControllerContext {
    var receivedStates = 0
    var reconciliations = 0
    var onCredentialsChanged: (() -> Void)?
    func sessionStateDidChange() {}
    func showLoading() {}
    func setActiveVIN(_ vin: String?) {}
    func didReceiveVehicleState(_ state: VehicleState) { receivedStates += 1 }
    func authenticationRequired() {}
    func authenticationSucceeded() {}
    func vehicleSwitchDidPause() {}
    func sessionDidEstablish() {}
    func sessionCredentialsDidChange() {
        reconciliations += 1
        onCredentialsChanged?()
    }
}
