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

/// The vehicle and provider a command was approved for. This value stays fixed while
/// authorization and provider execution suspend, even if the visible selection changes.
struct RemoteCommandTarget: Equatable, Sendable {
    let vin: String
    let brand: VehicleBrand
    let displayName: String
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
    func presentResult(title: String, message: String, success: Bool, target: RemoteCommandTarget?)
    /// Hands the accepted command to the refresh module for telemetry confirmation.
    func beginCommandConfirmation(_ pending: PendingCommandSummary)
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
/// outcomes, and handoff to state-driven command confirmation.
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

    init(context: any CommandExecutionContext,
         preferences: PreferencesStore,
         database: VehicleDatabase,
         authorizer: any RemoteActionAuthorizing) {
        self.context = context
        self.preferences = preferences
        self.database = database
        self.authorizer = authorizer
    }

    /// Dispatches one Remote Command end to end: gating, authorization, provider execution,
    /// audit, optimistic patching, user-visible outcome, and confirmation handoff.
    /// The full human presentation still flows through `presentResult`; the return value is
    /// for programmatic callers that await the answer.
    @discardableResult
    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin = .userInitiated) async -> RemoteCommandDispatchOutcome {
        guard let context else { return .refused(reason: RemoteCommandError.missingContext.localizedDescription) }
        guard !isInProgress else {
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: RemoteCommandError.busy.localizedDescription, success: false, target: nil)
            return .refused(reason: RemoteCommandError.busy.localizedDescription)
        }
        guard context.sessionIsValid, let state = context.vehicleState,
              (preferences.vin.isEmpty || state.identity.vin.caseInsensitiveCompare(preferences.vin) == .orderedSame) else {
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
                success: false,
                target: nil)
            return .refused(reason: message)
        }
        let executor = context.currentCommandExecutor()
        let availability = gate.availability(
            for: command,
            state: state,
            commandCatalog: executor.commandCatalog,
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
                success: false,
                target: nil)
            return .refused(reason: message)
        }
        let adapted = command.adapted(to: state.capabilityProfile, settings: state.otaCapabilities?.controlSettings)
        let vehicle = [state.identity.modelName, state.identity.registrationNo].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: " - ")
        let target = RemoteCommandTarget(
            vin: state.identity.vin,
            brand: executor.brand,
            displayName: preferences.formattedVehicleTitle(
                vin: state.identity.vin,
                modelName: state.identity.modelName,
                modelYear: state.identity.modelYear,
                registrationNo: state.identity.registrationNo,
                fallbackBrand: executor.brand)
        )

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
        guard isCurrentExecutionContext(target) else {
            return .refused(reason: L10n.text("The selected vehicle changed while authorization was pending."))
        }
        return await execute(adapted, target: target, executor: executor)
    }

    private func isCurrentExecutionContext(_ target: RemoteCommandTarget) -> Bool {
        guard let context, context.sessionIsValid,
              context.currentCommandExecutor().brand == target.brand,
              let currentState = context.vehicleState else { return false }
        return currentState.identity.vin.caseInsensitiveCompare(target.vin) == .orderedSame
    }

    private func execute(
        _ command: RemoteCommand,
        target: RemoteCommandTarget,
        executor: any RemoteCommandExecuting
    ) async -> RemoteCommandDispatchOutcome {
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
            logger.info("Remote command \(command.identifier, privacy: .public) sent for \(target.vin, privacy: .private)")
            let result = try await executor.executeRemoteCommand(command, vin: target.vin)
            database.recordCommandAudit(
                vin: target.vin,
                command: command.identifier,
                status: result.outcome.rawValue,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
            logger.info("Remote command \(command.identifier, privacy: .public) outcome \(result.outcome.rawValue, privacy: .public)")
            let targetIsCurrent = isCurrentExecutionContext(target)
            if targetIsCurrent {
                applyOptimisticPatch(
                    for: command,
                    outcome: result.outcome,
                    issuedAt: startedAt,
                    providerBrand: target.brand)
            }
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
            let commandTitle = targetIsCurrent
                ? command.title
                : L10n.format("%@ (%@)", command.title, target.displayName)
            context.presentResult(
                title: L10n.text("Command sent"),
                message: L10n.format("%@ — %@", commandTitle, detail),
                success: true,
                target: target
            )
            if targetIsCurrent {
                context.beginCommandConfirmation(PendingCommandSummary(
                    commandIdentifier: command.identifier,
                    issuedAt: startedAt,
                    command: command
                ))
            }
            return .sent(result.outcome)
        } catch {
            let mapped = error as? LocalizedError
            logger.error("Remote command \(command.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let message = mapped?.errorDescription ?? error.localizedDescription
            database.recordCommandAudit(
                vin: target.vin,
                command: command.identifier,
                status: "failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                error: message
            )
            context.presentResult(
                title: L10n.text("Command failed"),
                message: L10n.format(
                    "%@ failed. %@",
                    isCurrentExecutionContext(target)
                        ? command.title
                        : L10n.format("%@ (%@)", command.title, target.displayName),
                    message),
                success: false,
                target: target
            )
            return .refused(reason: message)
        }
    }

    /// Patches the visible state to what a successful command should have produced, so the
    /// fan animation, lock icon, or charge-target slider flip immediately instead of waiting
    /// for telemetry. `mergingLastKnown` honors `optimisticCommandLockUntil` for 90 s, so a
    /// stale read cannot revert the patch before the car confirms it.
    ///
    /// The patch is partly synthesized (an assumed 30-minute climate window), so it is
    /// display-only and must never be persisted.
    private func applyOptimisticPatch(
        for command: RemoteCommand,
        outcome: RemoteCommandOutcome,
        issuedAt: Date,
        providerBrand: VehicleBrand
    ) {
        guard outcome == .accepted || outcome == .delivered || outcome == .completed else { return }
        guard let context, var current = context.vehicleState else { return }
        switch command {
        case .startClimate(let temperature, _, _, _, _, _):
            current.climateStatus = VehicleClimateStatus(
                activity: .heating,
                timeRemainingMinutes: 30,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: Double(temperature > 0 ? temperature : 22.0)
            )
        case .stopClimate:
            current.climateStatus = VehicleClimateStatus(
                activity: .idle,
                timeRemainingMinutes: nil,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .startPreCleaning, .stopPreCleaning:
            // Patch `airQuality`, not `climateStatus`; a synthesized climate session would
            // surface a "Stop Climate" button that does not target pre-cleaning.
            guard var air = current.airQuality else { break }
            air = VehicleAirQuality(
                cleaningState: command == .startPreCleaning ? .on : .off,
                airQualityIndex: air.airQualityIndex,
                particulateMatter25: air.particulateMatter25,
                particulateMatter10: air.particulateMatter10,
                externalParticulateMatter25: air.externalParticulateMatter25,
                filterRemainingPercent: air.filterRemainingPercent,
                runtimeRemainingMinutes: air.runtimeRemainingMinutes,
                hasError: air.hasError,
                reportedAt: air.reportedAt,
                startedAt: command == .startPreCleaning ? (air.startedAt ?? Date()) : air.startedAt,
                endingAt: air.endingAt,
                startReason: air.startReason,
                lastCycleValid: air.lastCycleValid,
                errorKind: air.errorKind
            )
            current.airQuality = air
        case .lock, .lockReducedGuard:
            guard var exterior = current.exteriorStatus else { break }
            exterior.isLocked = true
            current.exteriorStatus = exterior
        case .unlock:
            guard var exterior = current.exteriorStatus else { break }
            // Volvo unlock does not patch exterior; the official app behaves the same way.
            if providerBrand == .volvo { break }
            exterior.isLocked = false
            current.exteriorStatus = exterior
        case .unlockTrunk:
            // Trunk-only unlock leaves central locking engaged.
            break
        case .openTailgate, .closeTailgate:
            guard var exterior = current.exteriorStatus else { break }
            let patchedState: OpeningState = command == .openTailgate ? .open : .closed
            if let index = exterior.openings.firstIndex(where: { $0.opening == .tailgate }) {
                exterior.openings[index] = OpeningReading(opening: .tailgate, state: patchedState)
            } else {
                exterior.openings.append(OpeningReading(opening: .tailgate, state: patchedState))
            }
            current.exteriorStatus = exterior
        case .setChargeTarget(let target):
            current.energy.targetPercentage = target
        case .setAmpLimit(let amps):
            current.energy.currentLimitAmps = amps
        default:
            break
        }
        current.freshness.fetchedAt = Date()
        current.commandState.optimisticLockUntil = Date().addingTimeInterval(90)
        current.commandState.pending = PendingCommandSummary(
            commandIdentifier: command.identifier, issuedAt: issuedAt, command: command)
        context.applyOptimisticState(current)
    }
}
