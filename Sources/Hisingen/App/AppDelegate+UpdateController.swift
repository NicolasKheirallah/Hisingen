// MARK: - UpdateControllerContext

extension AppDelegate: UpdateControllerContext {
    func setAvailableUpdateVersion(_ version: String?) {
        statusController.updateVersion = version
    }

    func setCheckingForUpdates(_ checking: Bool) {
        statusController.checkingForUpdates = checking
    }

    func updateStateDidChange() {
        render()
    }
}
