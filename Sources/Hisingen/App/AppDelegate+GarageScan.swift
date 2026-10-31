// MARK: - GarageScanContext

extension AppDelegate: GarageScanContext {
    var commandPipelineIsBusy: Bool { commandCoordinator.isInProgress }
    var refreshPipelineIsBusy: Bool { vehicleSession.isRefreshBusy }
    var refreshPipelineIsRateLimited: Bool { vehicleSession.isRefreshRateLimited }

    func garageScanDidCaptureState(_ state: VehicleState) {
        stateStore.save(state)
        fleetStore.retain(state)
        notifier.vehicleStateDidUpdate(state)
    }

    func garageScanDidCompletePass() {
        render()
    }
}
