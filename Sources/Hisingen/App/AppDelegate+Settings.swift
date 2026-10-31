import AppKit
import SwiftUI

extension AppDelegate {
    func toggleSettingsInPopover() {
        showSettingsWindow()
    }

    func showSettingsWindow() {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settings = SettingsView(
            notificationPermission: statusController.notificationPermission,
            state: vehicleSession.latest,
            fleet: fleetStore.snapshot(activeState: vehicleSession.latest),
            database: vehicleDatabase,
            imageCache: imageCache,
            showsHeaderBar: false,
            onSettingsChanged: { [weak self] change in
                guard let self else { return }
                if case .closeSettings = change {
                    self.closeSettingsWindow()
                } else {
                    self.settingsChanged(change)
                }
            },
            onSignOut: { [weak self] in self?.signOut() },
            accountConnection: statusController.accountConnection,
            onTestConnection: { [weak self] brand in
                guard let self else {
                    return ConnectionCheck(success: false, message: L10n.text("Hisingen is no longer running."), failureKind: nil)
                }
                return await self.connectionTester.test(brand: brand)
            }
        )
        .environment(\.preferencesStore, preferences)

        let host = NSHostingController(rootView: settings)
        let isNewWindow = settingsWindow == nil
        let window = settingsWindow ?? NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_080, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Hisingen Settings")
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        if isNewWindow {
            window.setContentSize(NSSize(width: 1_080, height: 760))
            window.center()
        }
        window.setFrameAutosaveName("HisingenSettingsWindowV2")
        settingsWindow = window
        statusController.dismissSettings()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeSettingsWindow() {
        settingsWindow?.orderOut(nil)
    }

    func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .credentials:
            vehicleSession.credentialsDidChange(for: .polestar)
        case .volvoSignIn(let clientID, let clientSecret, let vccApiKey, let nickname):
            signInCoordinator.beginVolvoSignIn(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey, nickname: nickname)
        case .polestarCommandAuthorization:
            signInCoordinator.beginPolestarCommandAuthorization()
        case .polestarCommandAuthorizationForceLogin:
            signInCoordinator.beginPolestarCommandAuthorization(forceLogin: true)
        case .polestarWebSignIn:
            signInCoordinator.beginPolestarWebSignIn()
        case .reauthenticate(let brand):
            switch brand {
            case .polestar:
                if preferences.polestarConnectionMode == .dataPortal {
                    vehicleSession.credentialsDidChange(for: .polestar)
                } else {
                    // Interactive browser window – no Polestar ID password re-entry.
                    signInCoordinator.beginPolestarWebSignIn()
                }
            case .volvo:
                // Re-run the browser OAuth with the developer keys already on file.
                let volvoVIN = preferences.vin(for: .volvo)
                signInCoordinator.beginVolvoSignIn(
                    clientID: preferences.volvoClientID, clientSecret: "", vccApiKey: "",
                    nickname: volvoVIN.isEmpty ? "" : preferences.vehicleNickname(for: volvoVIN),
                    forceInteractive: true
                )
            }
        case .switchToBrand(let brand):
            switch brand {
            case .polestar:
                vehicleSession.switchToBrandAndResume(.polestar)
                closeSettingsWindow()
            case .volvo:
                if preferences.hasResumableSession(for: .volvo) {
                    vehicleSession.switchToBrandAndResume(.volvo)
                    closeSettingsWindow()
                } else {
                    signInCoordinator.beginVolvoSignIn(clientID: preferences.volvoClientID, clientSecret: "", vccApiKey: "", nickname: "")
                }
            }
        case .selectVehicle(let vin):
            selectVehicle(vin: vin)
            closeSettingsWindow()
        case .closeSettings:
            closeSettingsWindow()
        case .exportDiagnosticLogs:
            exportDiagnosticLogs()
        case .features:
            notifier.featureSelectionDidChange()
            notifier.requestAuthorizationIfAnyAlertEnabled()
            updateController.applyConfiguration()
            vehicleSession.reloadVehicleMetadata()
            dockWarningBadge.refresh()
            chargingPlannerController.reload()
        case .notifications:
            notifier.requestAuthorizationIfAnyAlertEnabled()
            dockWarningBadge.refresh()
        case .presentation:
            preferences.applyAppearance()
            vehicleSession.reloadVehicleMetadata()
        case .launchAtLogin:
            launchAtLoginController.reconcile(userInitiated: true)
        case .updater:
            updateController.applyConfiguration()
        case .checkForUpdates:
            updateController.checkNow()
        case .automation:
            calendarPreconditioning.reload()
        }
        render()
    }
}
