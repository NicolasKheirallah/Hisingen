import Foundation

// MARK: - URLCommandRouterContext

extension AppDelegate: URLCommandRouterContext {
    var activeBrand: VehicleBrand { preferences.activeBrand }
    var defaultRemoteClimateTemperatureCelsius: Double { preferences.remoteClimateTemperature }

    func handleOAuthCallback(_ url: URL) {
        signInCoordinator.handleCallbackURL(url)
    }

    func selectVehicleByIndex(_ index: Int) {
        statusController.selectVehicleByIndex(index)
    }

    func showSettings() {
        showSettingsWindow()
    }

    func toggleSettings() {
        if settingsWindow?.isVisible == true {
            closeSettingsWindow()
        } else {
            showSettingsWindow()
        }
    }

    func togglePopover() {
        statusController.togglePopover()
    }

    func refreshNow() {
        vehicleSession.refreshNow()
    }

    func notifyCommandNotice(title: String, body: String) {
        notifier.notifyCommandNotice(title: title, body: body)
    }
}
