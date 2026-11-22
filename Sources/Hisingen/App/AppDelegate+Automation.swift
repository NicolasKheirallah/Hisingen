import Foundation

extension AppDelegate {
    func startCalendarClimate() async -> RemoteCommandDispatchOutcome {
        // Don't attempt (and don't spend a "Command not sent" banner) when the user has
        // turned the remote-climate feature off. Capability/session gating still happens
        // inside `CommandCoordinator`.
        guard preferences.features.contains(.remoteClimate) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        return await commandCoordinator.perform(
            .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: preferences.remoteDriverSeatHeating,
                frontRightSeat: preferences.remoteFrontRightSeatHeating,
                rearLeftSeat: preferences.remoteRearLeftSeatHeating,
                rearRightSeat: preferences.remoteRearRightSeatHeating,
                steeringWheel: preferences.remoteSteeringWheelHeating
            ),
            origin: .automation)
    }

    /// The planner's unattended start-charging path. Guarded on the remote-charging
    /// feature so turning that off also disarms auto-start; `.automation` origin means
    /// the coordinator runs the routine-risk `startChargingOverride` silently (no sheet,
    /// no biometrics) – auto-start is its own explicit consent in the planner settings.
    func startPlannerCharging(targetVIN: String) async -> RemoteCommandDispatchOutcome {
        guard preferences.features.contains(.remoteCharging) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        guard !targetVIN.isEmpty, let currentVIN = vehicleSession.latest?.identity.vin,
              currentVIN.caseInsensitiveCompare(targetVIN) == .orderedSame else {
            return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
        }
        return await commandCoordinator.perform(.startChargingOverride, origin: .automation)
    }

    /// The planner's unattended stop at the end of the window it started. Same consent and same
    /// `.automation` origin as the start: ending the override is what makes the cheap window a
    /// window rather than a permanent charge-now.
    func stopPlannerCharging(targetVIN: String) async -> RemoteCommandDispatchOutcome {
        guard preferences.features.contains(.remoteCharging) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        guard !targetVIN.isEmpty, let currentVIN = vehicleSession.latest?.identity.vin,
              currentVIN.caseInsensitiveCompare(targetVIN) == .orderedSame else {
            return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
        }
        return await commandCoordinator.perform(.stopChargingOverride, origin: .automation)
    }
}

// MARK: - Scheduled actions, triggers and the fleet broadcast

extension AppDelegate {
    /// The one unattended send path: queue, cooldown, then the coordinator's own gating,
    /// authorization and provider execution.
    ///
    /// `targetVIN` names a vehicle for the fleet broadcast; `nil` means the active one, which is
    /// what a schedule and a location trigger act on.
    func sendAutomationCommand(_ template: RemoteCommand, to targetVIN: String?) async -> AutomationSendResult {
        let command = AutomationCommandPolicy.resolved(template, saved: savedClimate())
        // The schedule and trigger editors only offer routine actions, but the check belongs on
        // the path itself: a decoded schedule or a Shortcut could still carry anything.
        guard AutomationCommandPolicy.allows(command) else {
            return .failed(reason: RemoteCommandError.unsupported.localizedDescription)
        }
        let vin: String
        if let targetVIN, !targetVIN.isEmpty {
            guard await vehicleSession.prepareVehicle(vin: targetVIN) else {
                return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
            }
            vin = targetVIN.normalizedVIN
        } else {
            vin = (vehicleSession.latest?.identity.vin ?? preferences.vin).normalizedVIN
        }
        guard !vin.isEmpty else {
            // Nothing was sent, so this is a retryable deferral: a schedule that fired before the
            // snapshot landed can still go out inside its catch-up window.
            return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
        }
        return await automationDispatcher.send(command, to: vin)
    }

    private func savedClimate() -> AutomationCommandPolicy.SavedClimate {
        AutomationCommandPolicy.SavedClimate(
            temperatureCelsius: Float(preferences.remoteClimateTemperature),
            frontLeftSeat: preferences.remoteDriverSeatHeating,
            frontRightSeat: preferences.remoteFrontRightSeatHeating,
            rearLeftSeat: preferences.remoteRearLeftSeatHeating,
            rearRightSeat: preferences.remoteRearRightSeatHeating,
            steeringWheel: preferences.remoteSteeringWheelHeating)
    }

    /// Sends one command to every vehicle the connected account has, then puts the reader back
    /// on the car they were looking at.
    ///
    /// The coordinator can only reach the vehicle it has loaded, so a broadcast necessarily
    /// selects each car in turn; leaving the selection on the last one would quietly change what
    /// every other surface is showing.
    func broadcastToFleet(_ command: RemoteCommand) async -> FleetCommandReport {
        let previousVIN = preferences.vin
        let report = await fleetBroadcaster.broadcast(command)
        if !previousVIN.isEmpty, previousVIN.normalizedVIN != preferences.vin.normalizedVIN {
            vehicleSession.selectVehicle(vin: previousVIN)
        }
        return report
    }

    /// Every vehicle the connected account knows about, named the way the rest of the app names
    /// it. Detached vehicles are already excluded by `FleetStore`.
    func configuredFleetVehicles() -> [FleetCommandVehicle] {
        let brand = preferences.activeBrand
        return fleetStore.knownVINs(for: brand).compactMap { vin in
            let key = vin.normalizedVIN
            guard !key.isEmpty else { return nil }
            let state = fleetStore.snapshot(for: key)
            return FleetCommandVehicle(
                vin: key,
                displayName: preferences.formattedVehicleTitle(
                    vin: key,
                    modelName: state?.identity.modelName,
                    modelYear: state?.identity.modelYear,
                    registrationNo: state?.identity.registrationNo,
                    fallbackBrand: brand))
        }
    }

    /// The Automations card's broadcast button: send, then say what happened. A partial result is
    /// shown as a failure on purpose – the reader asked for every car and one of them did not
    /// answer, so "sent" alone would be a lie.
    func runFleetBroadcast(_ command: RemoteCommand) async {
        let report = await broadcastToFleet(command)
        let message = report.summary()
        let succeeded = report.vehiclesConsidered > 0 && report.failed.isEmpty
        let title: String = report.vehiclesConsidered == 0
            ? L10n.text("Command not sent")
            : (succeeded ? L10n.text("Command sent") : L10n.text("Command failed"))
        lastRemoteCommandFeedback = RemoteCommandFeedback(
            title: title, message: message, success: succeeded, remedy: nil, followUp: nil,
            commandIdentifier: command.identifier,
            targetVIN: vehicleSession.latest?.identity.vin)
        render()
        resultPresenter.present(title: title, message: message, success: succeeded, subtitle: nil)
    }
}
