import Foundation
import Testing
@testable import Hisingen

/// Regressions from the whole-project review: a deep link must be confirmed even for a routine
/// command, a VIN-targeted request must not be redirected to another loaded vehicle, and a
/// command that finishes after a sign-out must not write its receipt or audit row back.
@Suite("Command coordinator hardening")
@MainActor
struct CommandCoordinatorHardeningTests {
    private let vin = "YSMHARDEN0001"

    // MARK: - Deep links

    @Test("A deep link asks for confirmation even when the command is routine")
    func deepLinkRoutineCommandIsConfirmedBeforeItIsSent() async {
        let rig = Rig(label: "hardening-deeplink-confirm", vin: vin)
        #expect(rig.command.risk == .routine)

        let outcome = await rig.coordinator.perform(rig.command, origin: .deepLink)

        if case .sent = outcome {} else { Issue.record("expected the confirmed command to be sent, got \(outcome)") }
        #expect(rig.recorder.confirmations == [rig.command])
        #expect(rig.recorder.authenticationReasons.isEmpty)
        #expect(rig.executor.executedCount == 1)
    }

    @Test("A declined deep-link confirmation sends nothing")
    func declinedDeepLinkSendsNothing() async {
        let rig = Rig(label: "hardening-deeplink-declined", vin: vin)
        rig.recorder.confirmAnswer = false

        let outcome = await rig.coordinator.perform(rig.command, origin: .deepLink)

        if case .refused = outcome {} else { Issue.record("expected a refusal, got \(outcome)") }
        #expect(rig.recorder.confirmations == [rig.command])
        #expect(rig.executor.executedCount == 0)
    }

    @Test("A command from the app itself stays prompt-free when biometrics are off")
    func userInitiatedRoutineCommandIsStillSilent() async {
        let rig = Rig(label: "hardening-user-silent", vin: vin)

        _ = await rig.coordinator.perform(rig.command, origin: .userInitiated)

        #expect(rig.recorder.confirmations.isEmpty)
        #expect(rig.executor.executedCount == 1)
    }

    // MARK: - Expected vehicle

    @Test("A command is held back when the loaded vehicle is not the one the caller named")
    func expectedVINMismatchSendsNothing() async {
        let rig = Rig(label: "hardening-expected-vin", vin: vin)

        let outcome = await rig.coordinator.perform(
            rig.command, origin: .userInitiated, expectedVIN: "YSMOTHERCAR01")

        if case .deferred = outcome {} else { Issue.record("expected a deferral, got \(outcome)") }
        #expect(rig.executor.executedCount == 0)
        #expect(rig.context.presented.last?.success == false)
    }

    @Test("The expected VIN is compared without regard to case or padding")
    func expectedVINMatchSendsTheCommand() async {
        let rig = Rig(label: "hardening-expected-vin-match", vin: vin)

        let outcome = await rig.coordinator.perform(
            rig.command, origin: .userInitiated, expectedVIN: " \(vin.lowercased()) ")

        if case .sent = outcome {} else { Issue.record("expected the command to be sent, got \(outcome)") }
        #expect(rig.executor.executedCount == 1)
    }

    // MARK: - Sign-out while a command is in flight

    @Test("A command that finishes after a sign-out files no receipt")
    func signOutDuringACommandFilesNoReceipt() async {
        let rig = Rig(label: "hardening-signout-receipt", vin: vin)
        rig.signOutWhenTheProviderReplies()

        let outcome = await rig.coordinator.perform(rig.command)

        if case .sent = outcome {} else { Issue.record("the banner must still report the command, got \(outcome)") }
        #expect(rig.context.receipts.isEmpty)
        #expect(rig.context.presented.last?.success == true)
        // Durable history survives a sign-out unless the reader chose to erase it.
        #expect(rig.database.history.recentCommandAudits(for: nil).count == 1)
    }

    @Test("With erase-on-sign-out, a command that finishes afterwards writes no audit row")
    func eraseOnSignOutKeepsTheAuditLogEmpty() async {
        let rig = Rig(label: "hardening-signout-audit", vin: vin)
        rig.preferences.eraseHistoryOnSignOut = true
        rig.signOutWhenTheProviderReplies()

        _ = await rig.coordinator.perform(rig.command)

        #expect(rig.context.receipts.isEmpty)
        #expect(rig.database.history.recentCommandAudits(for: nil).isEmpty)
    }

    @Test("A failed command after an erasing sign-out writes no audit row either")
    func failureAfterErasingSignOutWritesNothing() async {
        let rig = Rig(label: "hardening-signout-failure", vin: vin)
        rig.preferences.eraseHistoryOnSignOut = true
        rig.executor.failure = RemoteCommandError.rejected("no")
        rig.signOutWhenTheProviderReplies()

        _ = await rig.coordinator.perform(rig.command)

        #expect(rig.database.history.recentCommandAudits(for: nil).isEmpty)
    }

    @Test("Without a sign-out the receipt and audit row are written as before")
    func normalCommandStillFilesItsReceipt() async {
        let rig = Rig(label: "hardening-receipt-normal", vin: vin)

        _ = await rig.coordinator.perform(rig.command)

        #expect(rig.context.receipts.count == 1)
        #expect(rig.database.history.recentCommandAudits(for: nil).count == 1)
    }
}

// MARK: - Rig

@MainActor
private final class Rig {
    let scoped: ScopedPreferences
    var preferences: PreferencesStore { scoped.store }
    let database = VehicleDatabase.inMemory()
    let recorder = RemoteActionAuthorizerTests.Recorder()
    let executor = HardeningExecutor()
    let context: HardeningContext
    let coordinator: CommandCoordinator
    /// A routine command the default Polestar fixture can run, the one the existing coordinator
    /// tests use.
    let command = RemoteCommand.lock

    init(label: String, vin: String) {
        scoped = ScopedPreferences(label: label)
        let store = scoped.store
        store.vin = vin
        var features = FeatureSelection.default
        features.set(.remoteLocks, enabled: true)
        store.features = features
        store.requireBiometricsForRemoteControls = false

        context = HardeningContext(executor: executor, vehicleState: vehicle(vin: vin))
        coordinator = CommandCoordinator(
            context: context, preferences: store, database: database,
            authorizer: recorder.authorizer(preferences: store))
    }

    /// The sign-out lands while the provider call is still in flight, which is when the explicit
    /// flag is set and local data is cleared.
    func signOutWhenTheProviderReplies() {
        executor.beforeReturning = { [weak self] in self?.preferences.setExplicitSignOut(for: .polestar) }
    }
}

@MainActor
private final class HardeningContext: CommandExecutionContext {
    var vehicleState: VehicleState?
    var sessionIsValid = true
    var presented: [(title: String, success: Bool)] = []
    var receipts: [CommandReceipt] = []
    private let executor: HardeningExecutor

    init(executor: HardeningExecutor, vehicleState: VehicleState) {
        self.executor = executor
        self.vehicleState = vehicleState
    }

    func currentCommandExecutor() -> any RemoteCommandExecuting { executor }
    func commandInProgressDidChange() {}
    func presentResult(
        title: String, message: String, success: Bool, target: RemoteCommandTarget?,
        command: RemoteCommand, remedy: RemoteCommandRemedy?, followUp: RemoteCommandFollowUp?
    ) {
        presented.append((title, success))
    }
    func beginCommandConfirmation(_ receipt: CommandReceipt, optimisticState: VehicleState?) {
        receipts.append(receipt)
    }
}

/// Main-actor bound so a test can flip preferences from inside "the provider call", the way a
/// sign-out lands while a command is in flight.
@MainActor
private final class HardeningExecutor: RemoteCommandExecuting {
    nonisolated let brand: VehicleBrand = .polestar
    var failure: (any Error)?
    var beforeReturning: (@MainActor () -> Void)?
    private(set) var executedCount = 0

    nonisolated func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        try await reply()
    }

    private func reply() throws -> RemoteCommandResult {
        executedCount += 1
        beforeReturning?()
        if let failure { throw failure }
        return RemoteCommandResult(outcome: .completed, message: nil)
    }
}
