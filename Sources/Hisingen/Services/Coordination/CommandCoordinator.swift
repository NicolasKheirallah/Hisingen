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

    func currentProvider() -> any VehicleProviding
    /// Applies an optimistic post-command state (display-only; never persisted).
    func applyOptimisticState(_ state: VehicleState)
    /// Called when command-busyness changes so the shell can re-render controls.
    func commandInProgressDidChange()
    /// Presents a command outcome to the user.
    func presentResult(title: String, message: String, success: Bool)
    /// Requests the post-command authoritative refresh.
    func refreshNowAfterCommand()
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

    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin = .userInitiated) {
        guard let context else { return }
        guard !isInProgress else {
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: RemoteCommandError.busy.localizedDescription, success: false)
            return
        }
        guard context.sessionIsValid, let state = context.vehicleState,
              (preferences.vin.isEmpty || state.vin.caseInsensitiveCompare(preferences.vin) == .orderedSame) else {
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: RemoteCommandError.missingContext.localizedDescription, success: false)
            return
        }
        let availability = gate.availability(
            for: command,
            state: state,
            brand: context.currentProvider().brand,
            enabledFeatures: preferences.features.enabled,
            commandInProgress: isInProgress
        )
        guard availability == .available else {
            context.presentResult(
                title: L10n.text("Command not sent"),
                message: {
                    switch availability {
                    case .disabledBySettings: return RemoteCommandError.disabled.localizedDescription
                    case .unavailableUntilRefresh: return RemoteCommandError.missingContext.localizedDescription
                    case .unavailableWhileBusy: return RemoteCommandError.busy.localizedDescription
                    default: return RemoteCommandError.unsupported.localizedDescription
                    }
                }(),
                success: false)
            return
        }
        let adapted = command.adapted(to: state.capabilityProfile)
        let providerBrand = context.currentProvider().brand
        let vehicle = [state.modelName, state.registrationNo].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: " - ")
        Task { [weak self] in
            guard let self else { return }
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
            guard approved else { return }
            guard !self.isInProgress else { return }
            // Authorization can show a modal sheet or biometric prompt. The active account,
            // provider, or vehicle may change while it is visible; never send the command
            // that was approved for the old snapshot through the newly selected provider.
            guard self.isCurrentExecutionContext(vin: state.vin, brand: providerBrand) else { return }
            await self.execute(adapted, vin: state.vin)
        }
    }

    private func isCurrentExecutionContext(vin: String, brand: VehicleBrand) -> Bool {
        guard let context, context.sessionIsValid,
              context.currentProvider().brand == brand,
              let currentState = context.vehicleState else { return false }
        return currentState.vin.caseInsensitiveCompare(vin) == .orderedSame
    }

    private func execute(_ command: RemoteCommand, vin: String) async {
        guard let context else { return }
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
            let result = try await context.currentProvider().executeRemoteCommand(command, vin: vin)
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
                message: L10n.format("%@ — %@", command.outcomeDescription, detail),
                success: true
            )
            scheduleFollowUpRefresh(vin: vin)
        } catch {
            let mapped = error as? LocalizedError
            logger.error("Remote command \(command.identifier, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            database.recordCommandAudit(
                vin: vin,
                command: command.identifier,
                status: "failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                error: mapped?.errorDescription ?? error.localizedDescription
            )
            context.presentResult(
                title: L10n.text("Command failed"),
                message: L10n.format("%@ failed. %@",
                                     command.title,
                                     mapped?.errorDescription ?? error.localizedDescription),
                success: false
            )
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

    /// Patches the visible state to what a command should have produced, so the lock icon or
    /// climate row flips immediately instead of waiting for the follow-up refresh. In-memory
    /// only: the patch is partly synthesized (e.g. an assumed 30-minute climate window), so it
    /// must never be persisted as if the vehicle had reported it. `optimisticCommandLockUntil`
    /// keeps stale responses from reverting the visible state until the real snapshot lands.
    private func applyOptimisticPatch(for command: RemoteCommand, outcome: RemoteCommandOutcome) {
        guard let context else { return }
        guard outcome == .completed || outcome == .accepted || outcome == .delivered,
              var current = context.vehicleState else { return }
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
                activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .startPreCleaning:
            current.climateStatus = VehicleClimateStatus(
                activity: .ventilating, timeRemainingMinutes: 10, timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .stopPreCleaning:
            current.climateStatus = VehicleClimateStatus(
                activity: .idle, timeRemainingMinutes: nil, timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .lock, .lockReducedGuard, .unlock, .unlockTrunk:
            guard var exterior = current.exteriorStatus else { return }
            if command == .unlock, context.currentProvider().brand == .volvo {
                // Volvo unlock is two-phase ("ready to unlock"); the door event completes it.
                return
            }
            exterior.isLocked = (command == .lock || command == .lockReducedGuard)
            current.exteriorStatus = exterior
        case .openTailgate, .closeTailgate:
            guard var exterior = current.exteriorStatus else { return }
            let isOpening = command == .openTailgate
            if let idx = exterior.openings.firstIndex(where: { $0.opening == .tailgate }) {
                exterior.openings[idx] = OpeningReading(opening: .tailgate,
                                                        state: isOpening ? .open : .closed)
            } else {
                exterior.openings.append(OpeningReading(opening: .tailgate,
                                                        state: isOpening ? .open : .closed))
            }
            current.exteriorStatus = exterior
        case .setChargeTarget(let target):
            current.chargeTargetPercentage = target
        case .setAmpLimit(let amps):
            current.chargingCurrentLimitAmps = amps
        default:
            return
        }
        current.fetchedAt = Date()
        current.optimisticCommandLockUntil = Date().addingTimeInterval(90)
        current.pendingCommand = PendingCommandSummary(
            commandIdentifier: command.identifier, issuedAt: Date())
        context.applyOptimisticState(current)
    }
}
