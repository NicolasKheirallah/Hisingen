import AppKit

extension AppDelegate {
    func signOut() {
        signInCoordinator.cancelPolestarSignIn()
        SpotlightIndexer.removeAll()
        vehicleSession.signOut()
        // Cached addresses are derived from the signed-out account's locations.
        Task { [reverseGeocoder] in await reverseGeocoder.clear() }
    }
}

// MARK: - SignInCoordinatorContext

extension AppDelegate: SignInCoordinatorContext {
    func activateBrandAfterSignIn(_ brand: VehicleBrand) {
        // The browser flow has just written a new refresh token. Discard any earlier negative
        // presence result before the brand switch derives `sessionValid` from preferences.
        preferences.invalidateSessionCache()
        vehicleSession.adoptBrandAfterSignIn(brand)
    }

    func dismissSettingsAfterSignIn() {
        // A first successful sign-in hands off to the one-time setup pass instead of the
        // dashboard. The pass itself sets hasCompletedSetupPass on completion or skip.
        if !preferences.hasCompletedSetupPass {
            closeSettingsWindow()
            statusController.showSetupPass()
            return
        }
        closeSettingsWindow()
    }

    func refreshSettingsSurface() {
        guard settingsWindow?.isVisible == true else { return }
        closeSettingsWindow()
        showSettingsWindow()
    }

    func presentSignInNotice(title: String, body: String, subtitle: String?) {
        notifier.notifyCommandNotice(title: title, body: body, subtitle: subtitle)
    }
}
