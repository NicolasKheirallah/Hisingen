import Foundation
import UserNotifications

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
    private let preferences: PreferencesStore
    private let database: VehicleDatabase
    private let authorizer: RemoteActionAuthorizer
    private let gate = CapabilityGate()
    private weak var context: (any CommandExecutionContext)?

    private(set) var isInProgress = false
    private var followUpRefreshTask: Task<Void, Never>?

    init(context: any CommandExecutionContext,
         preferences: PreferencesStore,
         database: VehicleDatabase,
         authorizer: RemoteActionAuthorizer) {
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

    func perform(_ command: RemoteCommand) {
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
                message: availability == .disabledBySettings
                    ? RemoteCommandError.disabled.localizedDescription
                    : RemoteCommandError.unsupported.localizedDescription,
                success: false)
            return
        }
        let adapted = command.adapted(to: state.capabilityProfile)
        let vehicle = [state.modelName, state.registrationNo].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: " - ")
        Task { [weak self] in
            guard let self else { return }
            guard await self.authorizer.authorize(
                adapted,
                vehicle: vehicle.isEmpty ? L10n.text("the selected vehicle") : vehicle
            ) else { return }
            guard !self.isInProgress else { return }
            await self.execute(adapted, vin: state.vin)
        }
    }

    private func execute(_ command: RemoteCommand, vin: String) async {
        guard let context else { return }
        isInProgress = true
        context.commandInProgressDidChange()
        let startedAt = Date()
        defer {
            isInProgress = false
            context.commandInProgressDidChange()
        }
        do {
            let result = try await context.currentProvider().executeRemoteCommand(command, vin: vin)
            database.recordCommandAudit(
                vin: vin,
                command: command.identifier,
                status: result.outcome.rawValue,
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
            applyOptimisticPatch(for: command, outcome: result.outcome)
            let message: String
            if let backendMessage = result.message, !backendMessage.isEmpty {
                message = backendMessage
            } else {
                switch result.outcome {
                case .accepted: message = L10n.text("The vehicle service accepted the command.")
                case .delivered: message = L10n.text("The command was delivered to the vehicle.")
                case .completed: message = L10n.text("The vehicle completed the command.")
                }
            }
            context.presentResult(title: L10n.text("Command sent"), message: message, success: true)
            scheduleFollowUpRefresh(vin: vin)
        } catch {
            let mapped = error as? LocalizedError
            database.recordCommandAudit(
                vin: vin,
                command: command.identifier,
                status: "failed",
                durationMs: Int(Date().timeIntervalSince(startedAt) * 1_000),
                error: mapped?.errorDescription ?? error.localizedDescription
            )
            context.presentResult(
                title: L10n.text("Command failed"),
                message: mapped?.errorDescription ?? error.localizedDescription,
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
