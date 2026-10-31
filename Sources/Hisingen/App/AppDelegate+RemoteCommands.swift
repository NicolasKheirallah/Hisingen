extension AppDelegate {
    func performRemoteCommand(_ command: RemoteCommand) {
        // Interactive surfaces stay fire-and-forget: the banner/notification presentation
        // happens inside the coordinator; nothing here needs the outcome.
        Task { _ = await commandCoordinator.perform(command) }
    }

    func performRemoteCommand(_ command: RemoteCommand, targetVIN: String?) {
        Task { _ = await perform(command, targetVIN: targetVIN, origin: .userInitiated) }
    }
}

// MARK: - RemoteCommandDispatching

extension AppDelegate {
    // `selectVehicle(vin:)` is declared on the class above; the dispatch protocol shares it
    // so entry points select then send through one seam.
    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin) async -> RemoteCommandDispatchOutcome {
        await commandCoordinator.perform(command, origin: origin)
    }

    func perform(
        _ command: RemoteCommand,
        targetVIN: String?,
        origin: RemoteCommandOrigin
    ) async -> RemoteCommandDispatchOutcome {
        if let targetVIN, !targetVIN.isEmpty {
            guard await vehicleSession.prepareVehicle(vin: targetVIN) else {
                return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
            }
        }
        return await commandCoordinator.perform(command, origin: origin)
    }
}

// MARK: - CommandExecutionContext

extension AppDelegate: CommandExecutionContext {
    var vehicleState: VehicleState? { vehicleSession.latest }
    var sessionIsValid: Bool { vehicleSession.sessionValid }

    func currentCommandExecutor() -> any RemoteCommandExecuting { vehicleSession.currentProvider() }
    func commandInProgressDidChange() {
        render()
    }
    func presentResult(
        title: String,
        message: String,
        success: Bool,
        target: RemoteCommandTarget?,
        remedy: RemoteCommandRemedy?,
        followUp: RemoteCommandFollowUp?
    ) {
        let subtitle = target?.displayName ?? vehicleSession.latest.map { state -> String in
            let nick = preferences.vehicleNickname(for: state.identity.vin)
            return nick.isEmpty ? state.model.brand.displayName : nick
        }
        // Inline banner in the Controls tab first – it is visible regardless of the system
        // notification permission – then the notification for when the panel is closed.
        lastRemoteCommandFeedback = RemoteCommandFeedback(
            title: title, message: message, success: success, remedy: remedy, followUp: followUp)
        render()
        resultPresenter.present(title: title, message: message, success: success, subtitle: subtitle)
    }
    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState?
    ) {
        // The refresh module's receipt ledger decides where the receipt is filed: the selected
        // vehicle's live collection, or the Remote Command target's VIN when that target is not
        // the visible vehicle. The shell holds no part of that rule.
        vehicleSession.beginCommandConfirmation(receipt, optimisticState: optimisticState)
    }
    func requestExpeditedRefresh() {
        vehicleSession.refreshNow()
    }
}
