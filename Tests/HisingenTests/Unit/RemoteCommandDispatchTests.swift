import Foundation
import Testing
@testable import Hisingen

/// The awaited dispatch seam: URL routes, Shortcuts intents, and the Controls tab must all
/// get the same answer for the same Remote Command — the brand policy lives in
/// `CapabilityGate` + `ProviderCommandCatalog`, never in an entry point. Serialized: the
/// dispatch hub holds process-wide state.
@Suite("Remote command dispatch", .serialized)
struct RemoteCommandDispatchTests {
    private let vin = "YSMDISPATCH01"

    // MARK: - URL router

    /// Regression: the router used to refuse every Polestar write with a
    /// "paired mobile devices" notice while the Controls tab dispatched the same command
    /// happily. Deep links now share the one gate-backed policy.
    @Test
    @MainActor
    func deepLinkLockRoutesOnBothBrands() {
        for brand in [VehicleBrand.polestar, .volvo] {
            let context = RouterContextMock(activeBrand: brand)
            let router = URLCommandRouter(context: context)
            router.route(URL(string: "hisingen://lock")!)
            XCTAssertEqual(context.commands, [.lock])
            XCTAssertTrue(context.notices.isEmpty)
        }
    }

    @Test
    @MainActor
    func deepLinkChargeTargetStaysPolestarOnly() {
        let polestar = RouterContextMock(activeBrand: .polestar)
        URLCommandRouter(context: polestar).route(URL(string: "hisingen://charge-target?percent=70")!)
        XCTAssertEqual(polestar.commands, [.setChargeTarget(70)])

        // Volvo's official API exposes no charging writes — a capability fact, not policy.
        let volvo = RouterContextMock(activeBrand: .volvo)
        URLCommandRouter(context: volvo).route(URL(string: "hisingen://charge-target?percent=70")!)
        XCTAssertTrue(volvo.commands.isEmpty)
        XCTAssertTrue(volvo.notices.count == 1)
    }

    @Test
    @MainActor
    func deepLinkVINQuerySelectsBeforeDispatching() {
        let context = RouterContextMock(activeBrand: .volvo)
        let router = URLCommandRouter(context: context)
        router.route(URL(string: "hisingen://lock?vin=YSMZTEST01")!)
        XCTAssertEqual(context.selectedVINs, ["YSMZTEST01"])
        XCTAssertEqual(context.commands, [.lock])
    }

    // MARK: - Dispatch hub

    /// Install-before-wait: a context already installed resolves immediately.
    @Test
    @MainActor
    func installedContextResolvesWaitersImmediately() async {
        AutomationHandoff.resetForTesting()
        let context = DispatchMock(enabledFeatures: [.remoteLocks], vin: vin)
        AutomationHandoff.install(context)
        let awaited = await AutomationHandoff.waitForContext()
        XCTAssertTrue(awaited === context)
    }

    /// Wait-before-install: a shortcut that fires while the app is still launching waits
    /// for the shell to finish composition instead of round-tripping through a URL open.
    @Test
    @MainActor
    func waitersResumeWhenTheShellInstallsLater() async {
        AutomationHandoff.resetForTesting()
        async let awaited: any RemoteCommandDispatching = AutomationHandoff.waitForContext()
        try? await Task.sleep(for: .milliseconds(10))
        let late = DispatchMock(enabledFeatures: [.remoteLocks], vin: vin)
        AutomationHandoff.install(late)
        let resolved = await awaited
        XCTAssertTrue(resolved === late)
    }

    /// The intents' full path: resolve → select → dispatch → dialog copy.
    @Test
    @MainActor
    func sendSelectsTheVehicleAndDescribesTheOutcome() async {
        AutomationHandoff.resetForTesting()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: "RemoteCommandDispatchTests.send")!)
        preferences.vin = vin
        preferences.setVehicleNickname("My Volvo", for: vin)

        let context = DispatchMock(enabledFeatures: [.remoteLocks], vin: vin)
        AutomationHandoff.install(context)
        let dialog = await AutomationHandoff.send(.lock, vehicle: "My Volvo", preferences: preferences)
        XCTAssertEqual(context.selectedVINs, [vin])
        XCTAssertEqual(context.provider.executedCommands, [.lock])
        XCTAssertEqual(dialog, RemoteCommand.lock.outcomeDescription)
    }

    /// Gate refusals surface as dialog text without a provider round-trip.
    @Test
    @MainActor
    func sendSurfacesGateRefusalReasons() async {
        AutomationHandoff.resetForTesting()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: "RemoteCommandDispatchTests.refusal")!)

        let context = DispatchMock(enabledFeatures: [], vin: vin)
        AutomationHandoff.install(context)
        let dialog = await AutomationHandoff.send(.honkAndFlash, vehicle: nil, preferences: preferences)
        XCTAssertFalse(dialog.isEmpty)
        XCTAssertEqual(context.provider.executedCommands, [])
    }

    /// Volvo lock without the Approved scope tier is refused by the shared gate — the same
    /// answer the Controls tab now gives (both read the same precondition).
    @Test
    @MainActor
    func volvoLockWithoutApprovedScopesIsRefused() async {
        AutomationHandoff.resetForTesting()
        let preferences = PreferencesStore(defaults: UserDefaults(suiteName: "RemoteCommandDispatchTests.scopes")!)

        let context = DispatchMock(
            enabledFeatures: [.remoteLocks], vin: vin, brand: .volvo,
            restrictedScopesEnabled: false)
        AutomationHandoff.install(context)
        let dialog = await AutomationHandoff.send(.lock, vehicle: nil, preferences: preferences)
        XCTAssertEqual(context.provider.executedCommands, [])
        XCTAssertEqual(
            dialog,
            CommandAvailability.requiresAccountApproval.shortReason)
    }
}

// MARK: - Mocks

@MainActor
private final class RouterContextMock: URLCommandRouterContext {
    let activeBrand: VehicleBrand
    var selectedVehicleVIN: String? { nil }
    var defaultRemoteClimateTemperatureCelsius: Double { 21 }
    private(set) var selectedVINs: [String] = []
    private(set) var commands: [RemoteCommand] = []
    private(set) var notices: [(String, String)] = []

    init(activeBrand: VehicleBrand) { self.activeBrand = activeBrand }

    func handleOAuthCallback(_ url: URL) {}
    func selectVehicle(vin: String) { selectedVINs.append(vin) }
    func selectVehicleByIndex(_ index: Int) {}
    func showSettings() {}
    func toggleSettings() {}
    func togglePopover() {}
    func refreshNow() {}
    func performRemoteCommand(_ command: RemoteCommand) { commands.append(command) }
    func notifyCommandNotice(title: String, body: String) { notices.append((title, body)) }
}

/// Records what actually reached the provider — the real signal behind "was it sent".
@MainActor
private final class RecordingProvider: RemoteCommandExecuting {
    nonisolated let brand: VehicleBrand
    private(set) var executedCommands: [RemoteCommand] = []
    init(brand: VehicleBrand) { self.brand = brand }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        executedCommands.append(command)
        return RemoteCommandResult(outcome: .completed, message: nil)
    }
}

@MainActor
private final class DispatchMock: RemoteCommandDispatching, CommandExecutionContext {
    let provider: RecordingProvider
    let preferences: PreferencesStore
    var vehicleState: VehicleState?
    var sessionIsValid = true
    private(set) var selectedVINs: [String] = []

    /// Each instance gets its own isolated defaults suite, so parallel tests never share
    /// feature selections or brand state.
    init(enabledFeatures: Set<AppFeature>, vin: String,
         brand: VehicleBrand = .polestar, restrictedScopesEnabled: Bool = true) {
        self.provider = RecordingProvider(brand: brand)
        self.preferences = PreferencesStore(defaults: UserDefaults(
            suiteName: "RemoteCommandDispatchTests.mock.\(UUID().uuidString)")!)
        preferences.features = {
            var selection = FeatureSelection.default
            for feature in enabledFeatures { selection.set(feature, enabled: true) }
            return selection
        }()
        preferences.volvoRestrictedScopesEnabled = restrictedScopesEnabled
        vehicleState = VehicleState(
            batteryPercentage: 80, rangeKm: nil, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: nil,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .none, chargerConnection: .disconnected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: nil, vin: vin,
            ownerFirstName: nil, odometerKm: nil, imageData: nil,
            fetchedAt: Date(), vehicleReportedAt: Date(), dataWarnings: [])
    }

    func selectVehicle(vin: String) { selectedVINs.append(vin) }

    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin) async -> RemoteCommandDispatchOutcome {
        // Mirror the production shell: delegate straight into a real coordinator so the
        // gate, authorization, and audit path are exercised.
        let coordinator = CommandCoordinator(
            context: self, preferences: preferences, database: .inMemory(),
            authorizer: AlwaysAllowAuthorizer())
        return await coordinator.perform(command, origin: origin)
    }

    func currentCommandExecutor() -> any RemoteCommandExecuting { provider }
    func applyOptimisticState(_ state: VehicleState) { vehicleState = state }
    func commandInProgressDidChange() {}
    func presentResult(title: String, message: String, success: Bool) {}
    func beginCommandConfirmation(_ command: RemoteCommand) {}
    func refreshNowAfterCommand() {}
}

@MainActor
private final class AlwaysAllowAuthorizer: RemoteActionAuthorizing {
    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool { true }
}
