import Foundation
import Testing
@testable import Hisingen

/// A provider stand-in that records what reached it. The point of these tests is that a refused
/// command leaves this empty.
private actor RecordingExecutor: RemoteCommandExecuting {
    nonisolated let brand: VehicleBrand
    private var commands: [RemoteCommand] = []

    init(brand: VehicleBrand) {
        self.brand = brand
    }

    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        commands.append(command)
        return RemoteCommandResult(outcome: .completed, message: nil)
    }

    func executed() -> [RemoteCommand] { commands }
}

/// The command line hands every send to `CommandCoordinator` through the same authorizer the app
/// uses. These tests run the real coordinator and the real `RemoteActionAuthorizer`; only the
/// confirmation answer (the `--confirm` flag), the device-owner answer and the provider are
/// supplied. A command the app would refuse must read as refused here, in the app's own words,
/// with nothing sent and nothing audited.
@Suite("Command line dispatch", .serialized)
@MainActor
struct CommandLineDispatchTests {
    private let vin = "YSMCLI0000000001"

    private struct Fixture {
        /// Holds the scoped defaults domain open: its `deinit` removes the domain the store reads.
        let scoped: ScopedPreferences
        let preferences: PreferencesStore
        let stateStore: VehicleStateStore
        let executor: RecordingExecutor
        let context: CommandLineExecutionContext
        let confirmation: CommandLineConfirmation
        let authorizer: CommandLineAuthorizer
        let dispatcher: CommandLineDispatcher
    }

    private func fixture(
        state: VehicleState,
        brand: VehicleBrand = .polestar,
        features: Set<AppFeature> = [.remoteLocks, .remoteClimate],
        confirmed: Bool,
        approvedScopes: Bool = true,
        deviceOwner: RemoteActionAuthorizer.OwnerAuthentication = .succeeded
    ) -> Fixture {
        let scoped = ScopedPreferences(label: "command-line-dispatch")
        let preferences = scoped.store
        preferences.vin = state.identity.vin
        preferences.setVin(state.identity.vin, for: brand)
        var selection = FeatureSelection.default
        for feature in features { selection.set(feature, enabled: true) }
        preferences.features = selection
        preferences.volvoRestrictedScopesEnabled = approvedScopes

        let database = VehicleDatabase.inMemory()
        let stateStore = VehicleStateStore(database: database, preferences: preferences)
        let executor = RecordingExecutor(brand: brand)
        let context = CommandLineExecutionContext(executor: executor, state: state, store: stateStore)
        let confirmation = CommandLineConfirmation(confirmed: confirmed)
        let authorizer = CommandLineAuthorizer(confirmation: confirmation)
        authorizer.install(RemoteActionAuthorizer(
            preferences: preferences,
            confirm: { command, vehicle in confirmation.confirm(command, vehicle: vehicle) },
            authenticateOwner: { _ in deviceOwner },
            reportAuthenticationFailure: { error in authorizer.authenticationDidFail(error) }))
        let coordinator = CommandCoordinator(
            context: context, preferences: preferences, database: database, authorizer: authorizer)
        return Fixture(
            scoped: scoped, preferences: preferences, stateStore: stateStore, executor: executor, context: context,
            confirmation: confirmation, authorizer: authorizer,
            dispatcher: CommandLineDispatcher(coordinator: coordinator))
    }

    private func report(
        _ fixture: Fixture,
        _ command: RemoteCommand
    ) async -> CommandLineSendReport {
        let outcome = await fixture.dispatcher.perform(
            command, targetVIN: vin, origin: .commandLine)
        return CommandLineDispatchMapper(authorizer: fixture.authorizer).report(
            for: outcome,
            presentation: fixture.context.presentation,
            command: command,
            vehicle: .init(vin: vin, name: "Blue"))
    }

    @Test
    func staleTelemetryIsRefusedInTheAppsOwnWordsAndNothingIsSent() async {
        var state = vehicle(vin: vin)
        state.freshness.fetchedAt = Date().addingTimeInterval(-11 * 60)
        let fixture = fixture(state: state, confirmed: true)

        let report = await report(fixture, .lock)

        #expect(report.status == .refused)
        #expect(report.message == RemoteCommandError.missingContext.localizedDescription)
        #expect(await fixture.executor.executed().isEmpty)
        #expect(report.outcome == nil)
    }

    @Test
    func aVehicleTheGateDoesNotPermitIsRefusedBeforeTheProvider() async {
        let state = vehicle(vin: vin, brand: .volvo, modelName: "XC40")
        let fixture = fixture(state: state, brand: .volvo, confirmed: true, approvedScopes: false)

        let report = await report(fixture, .lock)

        #expect(report.status == .refused)
        #expect(report.message == CommandAvailability.requiresAccountApproval.shortReason)
        #expect(await fixture.executor.executed().isEmpty)
    }

    /// The confirmation seam: the app asks before a security-sensitive command. The terminal's
    /// answer is the `--confirm` flag, and without it the command is not sent — the same refusal
    /// a person clicking Cancel gets.
    @Test
    func aSecuritySensitiveCommandWithoutConfirmIsNotSent() async {
        let fixture = fixture(state: vehicle(vin: vin), confirmed: false)

        let report = await report(fixture, .unlock)

        #expect(report.status == .confirmationRequired)
        #expect(report.message == L10n.format(
            "Hisingen asks before it sends %@. Add --confirm to send it anyway.", RemoteCommand.unlock.title))
        #expect(await fixture.executor.executed().isEmpty)
    }

    @Test
    func aDestructiveCommandWithoutConfirmIsNotSent() async {
        let state = vehicle(vin: vin)
        let fixture = fixture(state: state, features: [.remoteCharging], confirmed: false)

        let report = await report(fixture, .deleteChargeLocation(id: "abc"))

        #expect(report.status == .confirmationRequired)
        #expect(await fixture.executor.executed().isEmpty)
    }

    @Test
    func aRoutineCommandIsSentThroughTheSameCoordinatorWithoutAFlag() async {
        let fixture = fixture(state: vehicle(vin: vin), confirmed: false)

        let report = await report(fixture, .lock)

        #expect(report.status == .sent)
        #expect(report.outcome == RemoteCommandOutcome.completed.rawValue)
        #expect(report.message.isEmpty == false)
        #expect(await fixture.executor.executed() == [.lock])
    }

    @Test
    func theConfirmFlagSendsASecuritySensitiveCommand() async {
        let fixture = fixture(state: vehicle(vin: vin), confirmed: true)

        let report = await report(fixture, .unlock)

        #expect(report.status == .sent)
        #expect(await fixture.executor.executed() == [.unlock])
    }

    /// The accepted command leaves the same two records the app leaves: the audit row the
    /// coordinator writes and the receipt the app's own ledger files.
    @Test
    func anAcceptedCommandIsAuditedAndReceiptedByTheAppsOwnStores() async {
        let fixture = fixture(state: vehicle(vin: vin), confirmed: false)

        _ = await report(fixture, .lock)

        let receipts = fixture.stateStore.commandReceipts(for: vin)
        #expect(receipts.count == 1)
        #expect(receipts.first?.receipt.commandIdentifier == "lock")
        #expect(receipts.first?.receipt.targetVIN == vin)
    }

    /// A failed device-owner check is authorization, not a capability refusal: a script must be
    /// able to tell "the car will not do this" from "nobody approved it".
    @Test
    func aFailedDeviceOwnerCheckIsReportedAsNotAuthorized() async {
        let fixture = fixture(state: vehicle(vin: vin), confirmed: true, deviceOwner: .failed)

        let report = await report(fixture, .unlock)

        #expect(report.status == .confirmationRequired)
        #expect(report.message == L10n.text("This command was cancelled because device-owner authentication did not succeed."))
        #expect(await fixture.executor.executed().isEmpty)
    }
}
