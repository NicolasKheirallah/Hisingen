import AppKit
import OSLog
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "application")
    private let stateStore = VehicleStateStore()
    private let polestarAPI = PolestarAPI()
    private let volvoAPI = VolvoAPI()
    private let volvoSignInPresenter = VolvoSignInPresenter()
    private let updateChecker = UpdateChecker()
    private let remoteAuthorizer = RemoteActionAuthorizer()
    private lazy var notifier = Notifier(stateStore: stateStore)
    private var refreshCoordinator: RefreshCoordinator!
    private var statusController: StatusItemController!
    private var latest: VehicleState?
    private var lastError: String?
    private var sessionValid = false
    private var lastDiagnostics: DiagnosticsSnapshot?
    private var remoteCommandInProgress = false


    private var activeProvider: any VehicleProviding {
        Preferences.activeBrand == .volvo ? volvoAPI : polestarAPI
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Preferences.migrateLegacyPassword()
        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.refreshCoordinator.refreshNow() },
            onSettings: { [weak self] in self?.toggleSettingsInPopover() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onRemoteCommand: { [weak self] command in self?.performRemoteCommand(command) }
        )
        statusController.onSelectCar = { [weak self] vin in self?.refreshCoordinator.selectCar(vin: vin) }
        statusController.onOpenUpdate = { NSWorkspace.shared.open(UpdateChecker.releasesPage) }
        statusController.onSettingsChanged = { [weak self] change in self?.settingsChanged(change) }
        statusController.onSignOut = { [weak self] in self?.refreshCoordinator.signOut() }
        notifier.onPermissionChanged = { [weak self] permission in
            self?.statusController.updateNotificationPermission(permission)
        }
        statusController.updateNotificationPermission(notifier.permission)
        refreshCoordinator = RefreshCoordinator(api: activeProvider, stateStore: stateStore)
        connectCoordinator()
        statusController.render(data: nil, error: nil, authenticated: false)
        applyLaunchAtLogin(userInitiated: false)
        checkForUpdatesIfEnabled()
        resumeStoredSession()
    }


    private func resumeStoredSession() {
        switch Preferences.activeBrand {
        case .polestar:
            let sessionToken = (try? Keychain.readSessionToken()) ?? nil
            let password = sessionToken?.isEmpty == false ? nil : ((try? Keychain.readPassword()) ?? nil)
            guard sessionToken?.isEmpty == false || (!Preferences.email.isEmpty && password?.isEmpty == false) else { return }
            refreshCoordinator.start(
                email: Preferences.email, password: password, sessionToken: sessionToken,
                preferredVIN: Preferences.vin.isEmpty ? nil : Preferences.vin
            )
        case .volvo:
            guard !Preferences.volvoClientID.isEmpty,
                  let clientSecret = (try? Keychain.readVolvoClientSecret()) ?? nil, !clientSecret.isEmpty,
                  let vccApiKey = (try? Keychain.readVolvoApiKey()) ?? nil, !vccApiKey.isEmpty,
                  let sessionToken = (try? Keychain.readVolvoSessionToken()) ?? nil, !sessionToken.isEmpty
            else { return }
            let clientID = Preferences.volvoClientID
            Task { [weak self] in
                guard let self else { return }
                await volvoAPI.configure(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey)


                guard Preferences.activeBrand == .volvo else { return }
                refreshCoordinator.start(
                    email: "", password: nil, sessionToken: sessionToken,
                    preferredVIN: Preferences.vin.isEmpty ? nil : Preferences.vin
                )
            }
        }
    }


    private func switchActiveBrand(to brand: VehicleBrand) {
        guard Preferences.activeBrand != brand else { return }
        refreshCoordinator?.stop()
        Preferences.activeBrand = brand
        latest = nil
        lastError = nil
        sessionValid = false
        statusController.cars = []
        statusController.activeVin = nil
        refreshCoordinator = RefreshCoordinator(api: activeProvider, stateStore: stateStore)
        connectCoordinator()
        render()
    }


    private func beginVolvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String) {
        let trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            showRemoteResult(
                title: L10n.text("Volvo sign-in unavailable"),
                message: VolvoError.appNotConfigured.localizedDescription, success: false
            )
            return
        }


        if clientSecret.isEmpty, vccApiKey.isEmpty, trimmedClientID == Preferences.volvoClientID,
           let storedSecret = (try? Keychain.readVolvoClientSecret()) ?? nil, !storedSecret.isEmpty,
           let storedApiKey = (try? Keychain.readVolvoApiKey()) ?? nil, !storedApiKey.isEmpty,
           let sessionToken = (try? Keychain.readVolvoSessionToken()) ?? nil, !sessionToken.isEmpty {
            switchActiveBrand(to: .volvo)
            Task { [weak self] in
                guard let self else { return }
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                    Preferences.setVehicleNickname(trimmedNickname, for: vin)
                }
            }
            resumeStoredSession()
            return
        }
        guard !clientSecret.isEmpty, !vccApiKey.isEmpty else {
            showRemoteResult(
                title: L10n.text("Volvo sign-in unavailable"),
                message: VolvoError.appNotConfigured.localizedDescription, success: false
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                await volvoAPI.configure(clientID: trimmedClientID, clientSecret: clientSecret, vccApiKey: vccApiKey)
                let authorizeURL = try await volvoAPI.beginSignIn()
                let callbackURL = try await volvoSignInPresenter.signIn(
                    authorizeURL: authorizeURL, callbackScheme: "hisingen"
                )
                try await volvoAPI.completeSignIn(callbackURL: callbackURL, preferredVIN: nil, features: Preferences.features)
                Preferences.volvoClientID = trimmedClientID
                try Keychain.saveVolvoClientSecret(clientSecret)
                try Keychain.saveVolvoApiKey(vccApiKey)
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                    Preferences.setVehicleNickname(trimmedNickname, for: vin)
                }
                switchActiveBrand(to: .volvo)
                resumeStoredSession()
            } catch {
                let mapped = error as? LocalizedError
                showRemoteResult(
                    title: L10n.text("Volvo sign-in failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription, success: false
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshCoordinator.stop()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        statusController.refreshGlobalHotKeyAccess()
        notifier.refreshAuthorizationStatus()
        if sessionValid { refreshCoordinator.refreshIfStale() }
    }

    private func connectCoordinator() {
        refreshCoordinator.onLoading = { [weak self] in self?.statusController.showLoading() }
        refreshCoordinator.onCars = { [weak self] cars, vin in
            guard let self else { return }
            statusController.cars = cars
            statusController.activeVin = vin


            var snapshots = statusController.cachedSnapshots
            for car in cars where snapshots[car.vin] == nil {
                if let snapshot = stateStore.snapshot(for: car.vin) { snapshots[car.vin] = snapshot }
            }
            statusController.cachedSnapshots = snapshots
        }
        refreshCoordinator.onState = { [weak self] state in
            guard let self else { return }
            notifier.vehicleStateDidUpdate(state)
            latest = state
            lastError = nil
            statusController.cachedSnapshots[state.vin] = state
            render()
        }
        refreshCoordinator.onError = { [weak self] error in
            guard let self else { return }
            lastError = error.localizedDescription
            if error.requiresAuthentication && Preferences.features.contains(.notifications) {
                sessionValid = false
                notifier.authenticationRequired()
            }
            render()
        }
        refreshCoordinator.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            sessionValid = diagnostics.sessionValid
            lastDiagnostics = diagnostics
            if diagnostics.sessionValid && Preferences.features.contains(.notifications) {
                notifier.authenticationSucceeded()
            }
            render()
        }
        refreshCoordinator.onSignedOut = { [weak self] in
            guard let self else { return }
            latest = nil
            lastError = nil
            sessionValid = false
            statusController.cars = []
            statusController.activeVin = nil
            render()
        }
        refreshCoordinator.onCleared = { [weak self] in
            guard let self else { return }
            latest = nil
            lastError = nil
            sessionValid = false
            statusController.cars = []
            statusController.activeVin = nil
            render()
        }
    }

    private func render() {
        statusController.remoteCommandInProgress = remoteCommandInProgress
        statusController.render(data: latest, error: lastError, authenticated: sessionValid)
    }

    private func toggleSettingsInPopover() {
        statusController.showSettings()
    }

    private func performRemoteCommand(_ command: RemoteCommand) {
        guard !remoteCommandInProgress else {
            showRemoteResult(title: L10n.text("Command not sent"),
                             message: RemoteCommandError.busy.localizedDescription, success: false)
            return
        }
        guard Preferences.features.contains(command.feature) else {
            showRemoteResult(title: L10n.text("Command not sent"),
                             message: RemoteCommandError.disabled.localizedDescription, success: false)
            return
        }
        guard sessionValid, let state = latest,
              (Preferences.vin.isEmpty || state.vin.caseInsensitiveCompare(Preferences.vin) == .orderedSame) else {
            showRemoteResult(title: L10n.text("Command not sent"),
                             message: RemoteCommandError.missingContext.localizedDescription, success: false)
            return
        }
        guard state.capabilityProfile.permits(command.requiredCapability) else {
            showRemoteResult(title: L10n.text("Command not sent"),
                             message: RemoteCommandError.unsupported.localizedDescription, success: false)
            return
        }
        let command = command.adapted(to: state.capabilityProfile)
        let vehicle = [state.modelName, state.registrationNo].compactMap { value in
            value?.isEmpty == false ? value : nil
        }.joined(separator: " · ")
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await remoteAuthorizer.authorize(
                command, vehicle: vehicle.isEmpty ? L10n.text("the selected vehicle") : vehicle
            ) else { return }
            guard !remoteCommandInProgress else { return }
            remoteCommandInProgress = true
            render()
            defer {
                remoteCommandInProgress = false
                render()
            }
            do {
                let result = try await activeProvider.executeRemoteCommand(command, vin: state.vin)
                let message: String
                if let backendMessage = result.message, !backendMessage.isEmpty {
                    message = backendMessage
                } else {
                    switch result.outcome {
                    case .accepted: message = L10n.text("The vehicle service accepted the command.")
                    case .delivered: message = L10n.text("The command was delivered to the vehicle.")
                    case .completed: message = L10n.text("The vehicle completed the command.")
                    }
                }
                showRemoteResult(title: L10n.text("Command sent"), message: message, success: true)
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                refreshCoordinator.refreshNow()
            } catch {
                let mapped = error as? LocalizedError
                showRemoteResult(
                    title: L10n.text("Command failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription,
                    success: false
                )
            }
        }
    }

    private func showRemoteResult(title: String, message: String, success: Bool) {
        let alert = NSAlert()
        alert.alertStyle = success ? .informational : .critical
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.text("Quit Hisingen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.text("Edit"))
        editMenu.addItem(withTitle: L10n.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L10n.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L10n.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L10n.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L10n.text("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .credentials:


            let switchedFromAnotherBrand = Preferences.activeBrand != .polestar
            switchActiveBrand(to: .polestar)
            applyLaunchAtLogin(userInitiated: true)
            notifier.featureSelectionDidChange()
            updateNotificationAuthorizationIfNeeded()
            updateCheckConfiguration()
            let password = (try? Keychain.readPassword()) ?? nil
            if switchedFromAnotherBrand, password?.isEmpty ?? true {


                resumeStoredSession()
            } else {
                refreshCoordinator.credentialsChanged(
                    email: Preferences.email,
                    password: password,
                    preferredVIN: Preferences.vin.isEmpty ? nil : Preferences.vin
                )
            }
        case .volvoSignIn(let clientID, let clientSecret, let vccApiKey, let nickname):
            beginVolvoSignIn(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey, nickname: nickname)
        case .switchToBrand(let brand):


            switch brand {
            case .polestar:
                switchActiveBrand(to: .polestar)
                resumeStoredSession()
            case .volvo:
                beginVolvoSignIn(clientID: Preferences.volvoClientID, clientSecret: "", vccApiKey: "", nickname: "")
            }
        case .features:
            notifier.featureSelectionDidChange()
            updateNotificationAuthorizationIfNeeded()
            updateCheckConfiguration()
            refreshCoordinator.reloadVehicleMetadata()
        case .notifications:
            updateNotificationAuthorizationIfNeeded()
        case .presentation:
            break
        case .launchAtLogin:
            applyLaunchAtLogin(userInitiated: true)
        }
        render()
    }

    private func updateNotificationAuthorizationIfNeeded() {
        if Preferences.features.contains(.notifications)
            && (Preferences.notifyChargingStarted || Preferences.notifyChargingComplete
                || Preferences.notifyChargingProblem || Preferences.notifyLowBattery
                || Preferences.notifySoftwareUpdates || Preferences.notifyVehicleWarnings
                || Preferences.notifyRainWithWindowsOpen || Preferences.notifyEveningUnlocked) {
            notifier.requestAuthorizationFromSettings()
        }
    }

    private func updateCheckConfiguration() {
        if Preferences.features.contains(.updateChecks) {
            checkForUpdatesIfEnabled()
        } else {
            statusController.updateVersion = nil
        }
    }

    private func checkForUpdates() {
        guard Preferences.features.contains(.updateChecks) else { return }
        statusController.checkingForUpdates = true
        render()
        updateChecker.checkNow { [weak self] result in
            guard let self else { return }
            statusController.checkingForUpdates = false
            let alert = NSAlert()
            switch result {
            case .updateAvailable(let version):
                statusController.updateVersion = version
                alert.messageText = L10n.format("Hisingen %@ is available", version)
                alert.informativeText = L10n.text("The release page includes the signed download and SHA-256 checksums.")
                alert.addButton(withTitle: L10n.text("Open Release Page"))
                alert.addButton(withTitle: L10n.text("Later"))
                render()
                if alert.runModal() == .alertFirstButtonReturn {
                    NSWorkspace.shared.open(UpdateChecker.releasesPage)
                }
            case .upToDate:
                alert.messageText = L10n.text("Hisingen is up to date")
                alert.informativeText = L10n.text("You are running the latest stable release.")
                alert.addButton(withTitle: L10n.text("OK"))
                render()
                alert.runModal()
            case .failed:
                alert.messageText = L10n.text("Couldn't check for updates")
                alert.informativeText = L10n.text("Check your internet connection and try again later.")
                alert.addButton(withTitle: L10n.text("OK"))
                render()
                alert.runModal()
            }
        }
    }

    private func checkForUpdatesIfEnabled() {
        guard Preferences.features.contains(.updateChecks) else { return }
        updateChecker.checkIfDue { [weak self] version in
            guard let self, Preferences.features.contains(.updateChecks) else { return }
            statusController.updateVersion = version
            render()
        }
    }

    private func applyLaunchAtLogin(userInitiated: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if Preferences.launchAtLogin {
                switch service.status {
                case .notRegistered:
                    try service.register()
                case .requiresApproval:
                    if userInitiated { SMAppService.openSystemSettingsLoginItems() }
                case .enabled:
                    break
                case .notFound:
                    Preferences.launchAtLogin = false
                @unknown default:
                    Preferences.launchAtLogin = false
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            Preferences.launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            logger.error("Launch-at-login update failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
