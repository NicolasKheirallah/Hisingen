import Foundation
import LocalAuthentication

/// The answer the command line gives where the app shows its confirmation alert.
///
/// The surface does not decide *whether* a command needs confirming — `RemoteActionAuthorizer`
/// does, from the same risk table the Controls tab and the deep links go through. This only
/// supplies the answer: the `--confirm` flag standing in for the person who would click
/// "Send Command". Without it the dispatch is refused before a provider is touched.
@MainActor
final class CommandLineConfirmation {
    private let confirmed: Bool
    private(set) var declinedReason: String?

    init(confirmed: Bool) {
        self.confirmed = confirmed
    }

    /// Matches `RemoteActionAuthorizer.Confirmation`, so the app's own authorizer asks this
    /// instead of opening a modal the terminal cannot show.
    func confirm(_ command: RemoteCommand, vehicle: String) -> Bool {
        if confirmed { return true }
        declinedReason = L10n.format(
            "Hisingen asks before it sends %@. Add --confirm to send it anyway.", command.title)
        return false
    }
}

/// The app's authorizer, with the outcome of its two questions kept so the terminal can say which
/// one was not answered. It deliberately delegates rather than reimplementing the policy: risk
/// classes, `--confirm`, and the device-owner prompt are the app's, unchanged.
@MainActor
final class CommandLineAuthorizer: RemoteActionAuthorizing {
    private var base: (any RemoteActionAuthorizing)?
    private let confirmation: CommandLineConfirmation
    /// The sentence to print when authorization was not granted, and why.
    private(set) var declinedReason: String?

    init(confirmation: CommandLineConfirmation) {
        self.confirmation = confirmation
    }

    /// Installed after construction because the app's authorizer needs this object's failure
    /// reporter, which is how the device-owner question reports a cancellation.
    func install(_ base: any RemoteActionAuthorizing) {
        self.base = base
    }

    func authorize(_ command: RemoteCommand, vehicle: String, origin: RemoteCommandOrigin) async -> Bool {
        guard let base = self.base else { return false }
        let granted = await base.authorize(command, vehicle: vehicle, origin: origin)
        if !granted {
            declinedReason = declinedReason
                ?? confirmation.declinedReason
                ?? L10n.text("Authorization was not granted.")
        }
        return granted
    }

    /// The app answers this with an alert; a terminal session answers on the error stream and
    /// leaves the sentence for the report.
    func authenticationDidFail(_ error: NSError?) {
        declinedReason = error?.localizedDescription
            ?? L10n.text("This command was cancelled because device-owner authentication did not succeed.")
    }
}

/// The last thing the app's own banner would have said about a dispatch.
struct CommandLinePresentation: Equatable, Sendable {
    let title: String
    let message: String
    let success: Bool
}

/// What the coordinator needs from a shell.
///
/// Small on purpose: gating, authorization, execution, audit and the optimistic patch all stay in
/// `CommandCoordinator`. The only thing this supplies is the vehicle the command is about, a
/// place to put the banner text, and the app's own receipt ledger for the confirmation lifecycle.
@MainActor
final class CommandLineExecutionContext: CommandExecutionContext {
    private let executor: any RemoteCommandExecuting
    private let store: VehicleStateStore
    private let sessionIsValidFlag: Bool
    private var state: VehicleState?
    private(set) var presentation: CommandLinePresentation?

    var vehicleState: VehicleState? { state }
    var sessionIsValid: Bool { sessionIsValidFlag }

    init(executor: any RemoteCommandExecuting, state: VehicleState, store: VehicleStateStore) {
        self.executor = executor
        self.store = store
        self.state = state
        self.sessionIsValidFlag = true
    }

    func currentCommandExecutor() -> any RemoteCommandExecuting { executor }

    func commandInProgressDidChange() {}

    func presentResult(
        title: String,
        message: String,
        success: Bool,
        target: RemoteCommandTarget?,
        command: RemoteCommand,
        remedy: RemoteCommandRemedy?,
        followUp: RemoteCommandFollowUp?
    ) {
        presentation = CommandLinePresentation(title: title, message: message, success: success)
    }

    /// The receipt is filed through the app's ledger, under the vehicle the command was approved
    /// for, so the next launch or selection restores the same confirmation the app would have
    /// been proving. Nothing is invented here; the terminal has no live refresh loop to prove it.
    func beginCommandConfirmation(_ receipt: CommandReceipt, optimisticState: VehicleState?) {
        if let optimisticState { state = optimisticState }
        CommandReceiptLedger(store: store).begin(receipt, selectedVIN: state?.identity.vin)
    }
}

/// The `RemoteCommandDispatching` seam with no shell in front of it. Deep links and Shortcuts
/// reach `AppDelegate`, which resolves the vehicle through `VehicleSessionController`; the
/// terminal has already fetched the vehicle it means, so it holds the coordinator directly. Both
/// cross this same protocol.
@MainActor
final class CommandLineDispatcher: RemoteCommandDispatching {
    private let coordinator: CommandCoordinator

    init(coordinator: CommandCoordinator) {
        self.coordinator = coordinator
    }

    /// Selecting is the shell's job. The terminal names one vehicle per invocation and never
    /// changes what the app has selected.
    func selectVehicle(vin: String) {}

    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin) async -> RemoteCommandDispatchOutcome {
        await coordinator.perform(command, origin: origin)
    }

    func perform(
        _ command: RemoteCommand,
        targetVIN: String?,
        origin: RemoteCommandOrigin
    ) async -> RemoteCommandDispatchOutcome {
        await coordinator.perform(command, origin: origin, expectedVIN: targetVIN)
    }
}

/// Turns one awaited dispatch into the report and the exit code.
///
/// Kept separate from the live wiring so the mapping is pinned by a test that runs the real
/// coordinator and the real authorizer: a command the gate refuses must read as `refused`, never
/// as a send, and the sentence must be the gate's own.
@MainActor
struct CommandLineDispatchMapper {
    let authorizer: CommandLineAuthorizer

    struct Vehicle {
        let vin: String
        let name: String
    }

    func report(
        for outcome: RemoteCommandDispatchOutcome,
        presentation: CommandLinePresentation?,
        command: RemoteCommand,
        vehicle: Vehicle?
    ) -> CommandLineSendReport {
        switch outcome {
        case .sent(let sent):
            return CommandLineSendReport(
                status: .sent,
                command: command.identifier,
                vin: vehicle?.vin,
                vehicle: vehicle?.name,
                outcome: sent.rawValue,
                message: presentation?.message ?? command.outcomeDescription)

        case .deferred(let reason):
            return CommandLineSendReport(
                status: .notSent,
                command: command.identifier,
                vin: vehicle?.vin,
                vehicle: vehicle?.name,
                outcome: nil,
                message: presentation?.message ?? reason)

        case .refused(let reason):
            // Authorization is the one refusal the terminal can explain better than the app can:
            // it knows which of the two questions went unanswered.
            if let declined = authorizer.declinedReason {
                return CommandLineSendReport(
                    status: .confirmationRequired,
                    command: command.identifier,
                    vin: vehicle?.vin,
                    vehicle: vehicle?.name,
                    outcome: nil,
                    message: declined)
            }
            return CommandLineSendReport(
                status: .refused,
                command: command.identifier,
                vin: vehicle?.vin,
                vehicle: vehicle?.name,
                outcome: nil,
                message: presentation?.message ?? reason)
        }
    }
}
