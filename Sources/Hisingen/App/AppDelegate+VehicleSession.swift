// MARK: - VehicleSessionControllerContext

extension AppDelegate: VehicleSessionControllerContext {
    func sessionStateDidChange() {
        render()
    }

    func showLoading() {
        statusController.showLoading()
    }

    func setActiveVIN(_ vin: String?) {
        statusController.activeVin = vin
    }

    func didReceiveVehicleState(_ state: VehicleState) {
        miniPanel.update(state: state)
        notifier.notifyChargingAnomalyIfNeeded(for: state)
        notifier.vehicleStateDidUpdate(state)
        chargingPlannerController.vehicleStateDidUpdate(state)
        if !state.commandState.receipts.contains(where: {
            $0.status.isAwaiting && $0.supportsTelemetryConfirmation
        }) {
            fleetStore.retain(state)
        }
    }

    func authenticationRequired() {
        notifier.authenticationRequired()
    }

    func authenticationSucceeded() {
        notifier.authenticationSucceeded()
    }

    func vehicleSwitchDidPause() {
        guard !statusController.isPopoverVisible else { return }
        notifier.notifyCommandNotice(
            title: L10n.text("Vehicle Switch Paused"),
            body: L10n.text("The vehicle service asked Hisingen to slow down. Switching vehicles will resume automatically."))
    }

    func sessionDidEstablish() {
        garageScanner.schedulePass(after: 8)
    }

    func sessionCredentialsDidChange() {
        launchAtLoginController.reconcile(userInitiated: true)
        notifier.featureSelectionDidChange()
        notifier.requestAuthorizationIfAnyAlertEnabled()
        updateController.applyConfiguration()
    }
}
