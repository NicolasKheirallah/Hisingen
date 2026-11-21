import AppKit

extension AppDelegate {
    func signOut(selection: SignOutSelection = .vehicle) {
        signInCoordinator.cancelPolestarSignIn()
        let outcome = vehicleSession.signOut(forceAccount: selection == .account)
        switch outcome {
        case .vehicleDisconnected(let vin):
            // The account stays connected; only this car's Spotlight entry is stale.
            SpotlightIndexer.removeVehicle(vin)
            if !preferences.eraseHistoryOnSignOut,
               homeCharging.pairing?.vin.normalizedVIN == vin.normalizedVIN {
                homeCharging.unpair()
                notifier.notifyCommandNotice(
                    title: L10n.text("Home charger unpaired"),
                    body: L10n.text("The charger was paired to this vehicle. Pair it again from Settings after you bring the vehicle back.")
                )
            }
            if settingsWindow?.isVisible == true {
                Task { @MainActor [weak self] in self?.refreshSettingsSurface() }
            }
        case .switchedToBrand(_, _, let signedOutVINs):
            // Remove the signed-out account's entries without racing the fallback car's first
            // re-index. If discovery never reported a VIN, fall back to the domain-wide clear.
            if signedOutVINs.isEmpty {
                SpotlightIndexer.removeAll()
            } else {
                SpotlightIndexer.removeVehicles(signedOutVINs)
            }
            if settingsWindow?.isVisible == true {
                Task { @MainActor [weak self] in self?.refreshSettingsSurface() }
            }
        case .signedOut:
            SpotlightIndexer.removeAll()
            closeSettingsWindow()
            NSApp.activate(ignoringOtherApps: true)
            statusController.openPopover()
        }
        // Cached addresses are derived from the signed-out account's or vehicle's locations.
        Task { [reverseGeocoder] in await reverseGeocoder.clear() }
    }
}

// MARK: - SignInCoordinatorContext

extension AppDelegate: SignInCoordinatorContext {
    func activateBrandAfterSignIn(_ brand: VehicleBrand) {
        // The browser flow has just written a new refresh token. Discard any earlier negative
        // presence result before the brand switch decides what the panel should show.
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
