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
        chargingPlannerController.vehicleStateDidUpdate()
        if !state.commandState.hasAwaitingTelemetryConfirmation {
            fleetStore.retain(state)
        }
    }

    func authenticationRequired() {
        notifier.authenticationRequired()
    }

    func authenticationSucceeded() {
        notifier.authenticationSucceeded()
    }

    func signOutRevocationFailed(brand: VehicleBrand) {
        notifier.notifyCommandNotice(
            title: L10n.text("Sign out did not finish"),
            body: L10n.format(
                "Hisingen could not finish signing out of %@. The account was removed from this Mac, but the service did not confirm revocation. Sign in and out again to retry.",
                brand.displayName
            ),
            subtitle: brand.displayName
        )
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
