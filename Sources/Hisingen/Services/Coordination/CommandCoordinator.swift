import Foundation
import OSLog
import UserNotifications

/// Who asked for a command. `.userInitiated` goes through the normal interactive
/// authorization (confirmation sheet / device-owner prompt). `.automation` is a
/// pre-authorized background trigger (e.g. calendar preconditioning) with nobody at the
/// Mac to answer a prompt — it runs routine commands silently and refuses anything riskier.
enum RemoteCommandOrigin: Sendable {
    case userInitiated
    case automation
}

/// Context the coordinator needs from the app shell. Kept narrow on purpose: everything else
/// (gating, authorization, execution, audit, optimistic patching, follow-up refresh) lives
/// here so command behaviour has exactly one home.
@MainActor
protocol CommandExecutionContext: AnyObject {
    /// Latest known snapshot; commands require it for gating and optimistic patching.
    var vehicleState: VehicleState? { get }
    /// Whether the active brand's session currently allows commands.
    var sessionIsValid: Bool { get }

    func currentCommandExecutor() -> any RemoteCommandExecuting
    /// Applies an optimistic post-command state (display-only; never persisted).
    func applyOptimisticState(_ state: VehicleState)
    /// Called when command-busyness changes so the shell can re-render controls.
    func commandInProgressDidChange()
    /// Presents a command outcome to the user.
    func presentResult(title: String, message: String, success: Bool)
    /// Requests the post-command authoritative refresh.
    func beginCommandConfirmation(_ command: RemoteCommand)
    func refreshNowAfterCommand()
}

/// What a dispatch returned. The human presentation always flows through
/// `presentResult` regardless; the value exists so programmatic entry points
/// (Shortcuts intents) can surface the same answer the banner showed without
/// polling the command audit table.
enum RemoteCommandDispatchOutcome: Sendable {
    case sent(RemoteCommandOutcome)
    /// Not sent: busy, missing context, gate refusal, declined authorization, or a
    /// provider failure. `reason` is the same copy `presentResult` showed.
    case refused(reason: String)
}

/// The seam every Remote Command entry point crosses once the app shell is wired:
/// vehicle selection plus the awaited dispatch. Entrypoints (Controls tab, deep links,
/// Shortcuts intents) hold this, never the shell itself.
@MainActor
protocol RemoteCommandDispatching: AnyObject, Sendable {
    func selectVehicle(vin: String)
    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin) async -> RemoteCommandDispatchOutcome
}

/// Owns the full remote-command pipeline: capability gating, biometric authorization,
/// provider execution, audit logging, display-only optimistic state patching, user-visible
/// outcomes, and the single follow-up refresh ~12 s after a successful command.
///
/// Extracted from `AppDelegate`, which had become the de-facto command service while also
/// being the lifecycle owner, URL router, and garage scanner.
@MainActor
final class CommandCoordinator {
    private let logger = AppLog.logger("commands")
    private let preferences: PreferencesStore
    private let database: VehicleDatabase
    private let authorizer: any RemoteActionAuthorizing
    private let gate = CapabilityGate()
    private weak var context: (any CommandExecutionContext)?

    private(set) var isInProgress = false
    /// `RemoteCommand.identifier` of the command currently executing, so the Controls tab can
    /// show a "Sending…" state on the specific control that was tapped rather than dimming the
    /// whole page. `nil` whenever `isInProgress` is false.
    private(set) var inProgressCommandIdentifier: String?
    private var followUpRefreshTask: Task<Void, Never>?

    init(context: any CommandExecutionContext,
         preferences: PreferencesStore,
         database: VehicleDatabase,
         authorizer: any RemoteActionAuthorizing) {
        self.context = context
        self.preferences = preferences
        self.database = database
        self.authorizer = authorizer
    }

    /// Cancels any pending follow-up refresh (sign-out, brand switch, termination).
    func cancelPendingWork() {
        followUpRefreshTask?.cancel()
        followUpRefreshTask = nil
    }

    /// Dispatches one Remote Command end to end: gating, authorization, provider execution,
    /// audit, optimistic patching, user-visible outcome, and the single follow-up refresh.
    /// The full human presentation still flows through `presentResult`; the return value is
    /// for programmatic callers that await the answer.
    @discardableResult
    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin = .userInitiated) async -> RemoteCommandDispatchOutcome {
        guard let context else { return .refused(reason: RemoteCommandError.missingContext.localizedDescription) }
        guard !isInProgress else {
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: RemoteCommandError.busy.localizedDescription, success: false)
            return .refused(reason: RemoteCommandError.busy.localizedDescription)
        }
        guard context.sessionIsValid, let state = context.vehicleState,
              (preferences.vin.isEmpty || state.vin.caseInsensitiveCompare(preferences.vin) == .orderedSame) else {
            // Distinguish "still loading" (session fine, first telemetry fetch not back yet
            // right after launch) from "you need to refresh" — the command is hard-gated on a
            // snapshot for capability checks and the optimistic patch.
            let stillLoading = context.sessionIsValid && context.vehicleState == nil
            let message = stillLoading
                ? L10n.text("Vehicle data is still loading — try again in a moment.")
                : RemoteCommandError.missingContext.localizedDescription
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: message,
                success: false)
            return .refused(reason: message)
        }
        let availability = gate.availability(
            for: command,
            state: state,
            commandCatalog: context.currentCommandExecutor().commandCatalog,
            enabledFeatures: preferences.features.enabled,
            commandInProgress: isInProgress,
            volvoRestrictedScopesEnabled: preferences.volvoRestrictedScopesEnabled
        )
        guard availability == .available else {
            let message: String = {
                switch availability {
                case .disabledBySettings: return RemoteCommandError.disabled.localizedDescription
                case .unavailableUntilRefresh: return RemoteCommandError.missingContext.localizedDescription
                case .unavailableWhileBusy: return RemoteCommandError.busy.localizedDescription
                case .notVehicleOwner: return availability.shortReason
                    ?? RemoteCommandError.unsupported.localizedDescription
                case .requiresAccountApproval: return availability.shortReason
                    ?? RemoteCommandError.unsupported.localizedDescription
                case .invalidSettings(let reason): return reason
                default: return RemoteCommandError.unsupported.localizedDescription
                }
            }()
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: message,
                success: false)
            return .refused(reason: message)
        }
        let adapted = command.adapted(to: state.capabilityProfile, settings: state.otaCapabilities?.controlSettings)
        let providerBrand = context.currentCommandExecutor().brand
        let vehicle = [state.modelName, state.registrationNo].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: " - ")

        let approved: Bool
        switch origin {
        case .userInitiated:
            approved = await self.authorizer.authorize(
                adapted,
                vehicle: vehicle.isEmpty ? L10n.text("the selected vehicle") : vehicle
            )
        case .automation:
            // A user-configured automation pre-authorizes routine commands; there is no
            // one present to answer a confirmation sheet or a device-owner prompt when it
            // fires. Anything non-routine still requires an explicit person.
            approved = adapted.risk == .routine
        }
        guard approved else { return .refused(reason: L10n.text("Authorization was not granted.")) }
        guard !isInProgress else {
            return .refused(reason: RemoteCommandError.busy.localizedDescription)
        }
        // Authorization can show a modal sheet or biometric prompt. The active account,
        // provider, or vehicle may change while it is visible; never send the command
        // that was approved for the old snapshot through the newly selected provider.
        guard isCurrentExecutionContext(vin: state.vin, brand: providerBrand) else {
            return .refused(reason: L10n.text("The selected vehicle changed while authorization was pending."))
        }
        return await execute(adapted, vin: state.vin)
    }

    private func isCurrentExecutionContext(vin: String, brand: VehicleBrand) -> Bool {
        guard let context, context.sessionIsValid,
              context.currentCommandExecutor().brand == brand,
              let currentState = context.vehicleState else { return false }
        return currentState.vin.caseInsensitiveCompare(vin) == .orderedSame
    }

    private func execute(_ command: RemoteCommand, vin: String) async -> RemoteCommandDispatchOutcome {
        guard let context else { return .refused(reason: RemoteCommandError.missingContext.localizedDescription) }
        isInProgress = true
        inProgressCommandIdentifier = command.identifier
        context.commandInProgressDidChange()
        let startedAt = Date()
        defer {
            isInProgress = false
            inProgressCommandIdentifier = nil
            context.commandInProgressDidChange()
        }
        do {
            logger.info("Remote command \(command.identifier, privacy: .public) sent for \(vin, privacy: .private)")
            let result = try await context.currentCommandExecutor().executeRemoteCommand(command, vin: vin)
            database.recordCommandAudit(
                vin: vin,
                command: command.identifier,
                status: result.outcome.rawValue,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
            logger.info("Remote command \(command.identifier, privacy: .public) outcome \(result.outcome.rawValue, privacy: .public)")
            applyOptimisticPatch(for: command, outcome: result.outcome)
            // The banner must say *what* ran, not just that something did — a bare
            // "Command sent" while two cars are in range reads as noise.
            let detail: String
            if let backendMessage = result.message, !backendMessage.isEmpty {
                detail = backendMessage
            } else {
                switch result.outcome {
                case .accepted: detail = L10n.text("The vehicle service accepted the command.")
                case .delivered: detail = L10n.text("The command was delivered to the vehicle.")
                case .completed: detail = L10n.text("The vehicle completed the command.")
                }
            }
            context.presentResult(
                title: L10n.text("Command sent"),
                message: L10n.format("%@ — %@", command.title, detail),
                success: true
            )
            context.beginCommandConfirmation(command)
            scheduleFollowUpRefresh(vin: vin)
            return .sent(result.outcome)
        } catch {
            let mapped = error as? LocalizedError
            logger.error("Remote command \(command.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let message = mapped?.errorDescription ?? error.localizedDescription
            database.recordCommandAudit(
                vin: vin,
                command: command.identifier,
                status: "failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                error: message
            )
            context.presentResult(
                title: L10n.text("Command failed"),
                message: L10n.format("%@ failed. %@", command.title, message),
                success: false
            )
            return .refused(reason: message)
        }
    }

    /// One authoritative refresh ~12 s after a successful command; superseded by a newer
    /// command, sign-out, or termination via `cancelPendingWork()`.
    private func scheduleFollowUpRefresh(vin: String) {
        followUpRefreshTask?.cancel()
        followUpRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(12))
            } catch is CancellationError {
                return
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let self, let context = self.context else { return }
            self.followUpRefreshTask = nil
            guard context.sessionIsValid, context.vehicleState?.vin == vin else { return }
            context.refreshNowAfterCommand()
        }
    }

    /// Keep the reported values until telemetry confirms the operation.
    private func applyOptimisticPatch(for command: RemoteCommand, outcome: RemoteCommandOutcome) {
        guard let context, var current = context.vehicleState else { return }
        current.pendingCommand = PendingCommandSummary(
            commandIdentifier: command.identifier, issuedAt: Date(), command: command)
        context.applyOptimisticState(current)
    }
}
