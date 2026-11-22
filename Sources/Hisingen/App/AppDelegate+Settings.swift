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
            refreshError: vehicleSession.lastError,
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
            onSignOut: { [weak self] selection in self?.signOut(selection: selection) },
            liveFleet: { [weak self] in
                self?.fleetStore.snapshot(activeState: self?.vehicleSession.latest) ?? FleetSnapshot()
            },
            accountConnection: statusController.accountConnection,
            onTestConnection: { [weak self] brand in
                guard let self else {
                    return ConnectionCheck(success: false, message: L10n.text("Hisingen is no longer running."), failureKind: nil)
                }
                return await self.connectionTester.test(brand: brand)
            }
        )
        .environment(\.preferencesStore, preferences)
        .environment(\.homeCharging, homeCharging)

        let host = NSHostingController(rootView: settings)
        let isNewWindow = settingsWindow == nil
        let openingSize = Self.settingsOpeningSize(on: NSScreen.main ?? NSScreen.screens.first)
        let window = settingsWindow ?? NSWindow(
            contentRect: NSRect(origin: .zero, size: openingSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L10n.text("Hisingen Settings")
        window.contentMinSize = NSSize(width: 820, height: 600)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        if isNewWindow {
            window.setContentSize(openingSize)
            window.center()
        }
        // V3: frames saved under V2 held the old 1080 by 760 opening size and would keep winning.
        window.setFrameAutosaveName("HisingenSettingsWindowV3")
        settingsWindow = window
        statusController.dismissSettings()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Four fifths of the screen's usable width and six sevenths of its height, never smaller than
    /// the old fixed size and capped so a large display does not stretch the sidebar and cards.
    static func settingsOpeningSize(on screen: NSScreen?) -> NSSize {
        let visible = screen?.visibleFrame.size ?? NSSize(width: 1_440, height: 900)
        return NSSize(
            width: min(1_400, max(1_080, (visible.width * 0.8).rounded())),
            height: min(1_000, max(760, (visible.height * 6 / 7).rounded()))
        )
    }

    func closeSettingsWindow() {
        settingsWindow?.orderOut(nil)
    }

    func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .credentials:
            preferences.accountStore.commitActiveAccount()
            vehicleSession.credentialsDidChange(for: .polestar)
        case .accountAdded:
            // The new account is empty until the sign-in form below completes; do not resume a
            // provider session for it, or the app would try to authenticate with no credentials.
            Task { @MainActor [weak self] in self?.refreshSettingsSurface() }
        case .accountSwitched:
            vehicleSession.accountDidSwitch(to: preferences.activeBrand)
            Task { @MainActor [weak self] in self?.refreshSettingsSurface() }
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
        case .reconnectVehicle(let vin):
            vehicleSession.reconnectVehicle(vin: vin)
            Task { @MainActor [weak self] in self?.refreshSettingsSurface() }
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
        case .panelLayout, .timeFormat:
            break
        case .launchAtLogin:
            launchAtLoginController.reconcile(userInitiated: true)
        case .dockIcon:
            applyDockIconPolicy()
            dockWarningBadge.refresh()
        case .updater:
            updateController.applyConfiguration()
        case .checkForUpdates:
            updateController.checkNow()
        case .broadcastCommand(let command):
            Task { @MainActor [weak self] in
                await self?.runFleetBroadcast(command)
            }
        case .reporting:
            recurringReports.reload()
        case .automation:
            calendarPreconditioning.reload()
            scheduledCommands.reload()
            // The reader may have changed what a trigger watches; the next snapshot should
            // establish where the car is rather than compare against a location they removed.
            locationTriggers.resetObservations()
        }
        render()
    }


    /// Applies the Dock icon preference. The bundle declares LSUIElement, so macOS starts the
    /// process as an accessory app and only this policy change can summon the Dock tile while
    /// running. The warning badge rides the same switch: a badge on a hidden tile paints
    /// nothing, and a freshly visible tile needs the current count.
    func applyDockIconPolicy() {
        NSApp.setActivationPolicy(preferences.showDockIcon ? .regular : .accessory)
    }
}
