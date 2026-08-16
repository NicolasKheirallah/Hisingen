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
        Preferences.applyAppearance()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
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
        let initialAuthenticated = Preferences.hasResumableSession(for: Preferences.activeBrand)
        let initialVIN = Preferences.vin(for: Preferences.activeBrand)
        let initialNickname = Preferences.vehicleNickname(for: initialVIN)
        let initialCar = initialVIN.isEmpty ? nil : CarSummary(vin: initialVIN, title: initialNickname.isEmpty ? Preferences.activeBrand.displayName : initialNickname)
        if let initialCar {
            statusController.cars = [initialCar]
            statusController.activeVin = initialVIN
        }
        let initialSnapshot = initialVIN.isEmpty ? nil : stateStore.snapshot(for: initialVIN)
        sessionValid = initialAuthenticated
        latest = initialSnapshot
        statusController.render(data: initialSnapshot, error: nil, authenticated: initialAuthenticated)
        applyLaunchAtLogin(userInitiated: false)
        checkForUpdatesIfEnabled()
        resumeStoredSession()
        cacheDormantBrandSnapshot()
        setupURLEventHandling()
        if !initialAuthenticated {
            statusController.openPopover()
        }
    }

    private func setupURLEventHandling() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    private func cacheDormantBrandSnapshot() {
        let dormantBrand: VehicleBrand = Preferences.activeBrand == .polestar ? .volvo : .polestar
        let dormantVIN = Preferences.vin(for: dormantBrand)
        guard !dormantVIN.isEmpty, statusController.cachedSnapshots[dormantVIN] == nil,
              let snapshot = stateStore.snapshot(for: dormantVIN) else { return }
        statusController.cachedSnapshots[dormantVIN] = snapshot
    }


    private func resumeStoredSession() {
        switch Preferences.activeBrand {
        case .polestar:
            guard !Preferences.email.isEmpty else { return }
            let sessionToken = (try? Keychain.readSessionToken()) ?? nil
            let password = sessionToken?.isEmpty == false ? nil : ((try? Keychain.readPassword()) ?? nil)
            guard sessionToken != nil || password != nil else { return }
            refreshCoordinator.start(
                email: Preferences.email, password: password, sessionToken: sessionToken,
                preferredVIN: Preferences.vin.isEmpty ? nil : Preferences.vin
            )
        case .volvo:
            let clientID = !Preferences.volvoClientID.isEmpty ? Preferences.volvoClientID : BuiltinVolvoSecrets.clientID
            let clientSecret = ((try? Keychain.readVolvoClientSecret()) ?? nil) ?? (BuiltinVolvoSecrets.clientSecret.isEmpty ? nil : BuiltinVolvoSecrets.clientSecret)
            let vccApiKey = ((try? Keychain.readVolvoApiKey()) ?? nil) ?? (BuiltinVolvoSecrets.vccApiKey.isEmpty ? nil : BuiltinVolvoSecrets.vccApiKey)
            let sessionToken = (try? Keychain.readVolvoSessionToken()) ?? nil

            guard !clientID.isEmpty,
                  let clientSecret, !clientSecret.isEmpty,
                  let vccApiKey, !vccApiKey.isEmpty,
                  let sessionToken, !sessionToken.isEmpty
            else { return }
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


    private func switchActiveBrand(to brand: VehicleBrand, force: Bool = false) {
        if !force && Preferences.activeBrand == brand { return }
        refreshCoordinator?.stop()
        Preferences.activeBrand = brand
        Preferences.syncAppThemeStorageKey()
        let hasSession = Preferences.hasResumableSession(for: brand)
        sessionValid = hasSession
        let vin = Preferences.vin(for: brand)
        let nick = Preferences.vehicleNickname(for: vin)
        latest = vin.isEmpty ? nil : (statusController.cachedSnapshots[vin] ?? stateStore.snapshot(for: vin))
        lastError = nil
        statusController.cars = vin.isEmpty ? [] : [CarSummary(vin: vin, title: nick.isEmpty ? brand.displayName : nick)]
        statusController.activeVin = vin.isEmpty ? nil : vin
        refreshCoordinator = RefreshCoordinator(api: activeProvider, stateStore: stateStore)
        connectCoordinator()
        render()
        cacheDormantBrandSnapshot()
    }

    private func beginVolvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String) {
        var trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedClientID.isEmpty && BuiltinVolvoSecrets.isConfigured {
            trimmedClientID = BuiltinVolvoSecrets.clientID
        }
        let trimmedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedClientID.isEmpty else {
            showRemoteResult(
                title: L10n.text("Volvo sign-in unavailable"),
                message: VolvoError.appNotConfigured.localizedDescription, success: false
            )
            return
        }

        var effectiveSecret = !clientSecret.isEmpty ? clientSecret : ((try? Keychain.readVolvoClientSecret()) ?? "")
        if effectiveSecret.isEmpty && BuiltinVolvoSecrets.isConfigured {
            effectiveSecret = BuiltinVolvoSecrets.clientSecret
        }

        var effectiveApiKey = !vccApiKey.isEmpty ? vccApiKey : ((try? Keychain.readVolvoApiKey()) ?? "")
        if effectiveApiKey.isEmpty && BuiltinVolvoSecrets.isConfigured {
            effectiveApiKey = BuiltinVolvoSecrets.vccApiKey
        }

        let sessionToken = (try? Keychain.readVolvoSessionToken()) ?? nil

        if !effectiveSecret.isEmpty, !effectiveApiKey.isEmpty, let sessionToken, !sessionToken.isEmpty,
           trimmedClientID == Preferences.volvoClientID, clientSecret.isEmpty, vccApiKey.isEmpty {
            switchActiveBrand(to: .volvo, force: true)
            Task { [weak self] in
                guard let self else { return }
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                    Preferences.setVehicleNickname(trimmedNickname, for: vin)
                }
            }
            resumeStoredSession()
            statusController.dismissSettings()
            return
        }

        guard !effectiveSecret.isEmpty, !effectiveApiKey.isEmpty else {
            showRemoteResult(
                title: L10n.text("Volvo sign-in unavailable"),
                message: VolvoError.appNotConfigured.localizedDescription, success: false
            )
            return
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                await volvoAPI.configure(clientID: trimmedClientID, clientSecret: effectiveSecret, vccApiKey: effectiveApiKey)
                let authorizeURL = try await volvoAPI.beginSignIn()
                let callbackURL = try await volvoSignInPresenter.signIn(
                    authorizeURL: authorizeURL, callbackScheme: "hisingen"
                )
                try await volvoAPI.completeSignIn(callbackURL: callbackURL, preferredVIN: nil, features: Preferences.features)
                Preferences.volvoClientID = trimmedClientID
                try Keychain.saveVolvoClientSecret(effectiveSecret)
                try Keychain.saveVolvoApiKey(effectiveApiKey)
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                    Preferences.setVehicleNickname(trimmedNickname, for: vin)
                }
                switchActiveBrand(to: .volvo, force: true)
                resumeStoredSession()
                statusController.dismissSettings()
                showRemoteResult(
                    title: L10n.text("Volvo sign-in successful"),
                    message: L10n.text("Successfully connected to your Volvo account! Fetching telemetry…"),
                    success: true
                )
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
            let hasStored = Preferences.hasResumableSession(for: Preferences.activeBrand)
            sessionValid = diagnostics.sessionValid || hasStored
            lastDiagnostics = diagnostics
            if (diagnostics.sessionValid || hasStored) && Preferences.features.contains(.notifications) {
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
        let isAuth = sessionValid || Preferences.hasResumableSession(for: Preferences.activeBrand)
        statusController.remoteCommandInProgress = remoteCommandInProgress
        statusController.render(data: latest, error: lastError, authenticated: isAuth)
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
                self.applyConfirmedStateChange(for: command, outcome: result.outcome)
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
                Task {
                    try? await Task.sleep(nanoseconds: 12_000_000_000)
                    await MainActor.run { [weak self] in
                        self?.refreshCoordinator.refreshNow()
                    }
                }
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

    /// Patches the visible state to what a command should have produced, so the lock icon or
    /// climate row flips immediately instead of waiting for the follow-up refresh.
    private func applyConfirmedStateChange(for command: RemoteCommand,
                                           outcome: RemoteCommandOutcome) {
        guard outcome == .completed || outcome == .accepted || outcome == .delivered,
              var current = latest else { return }
        switch command {
        case .startClimate(let temperature, _, _, _, _, _):
            current.climateStatus = VehicleClimateStatus(
                activity: .heating,
                timeRemainingMinutes: 30,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: Double(temperature > 0 ? temperature : 22.0)
            )
        case .stopClimate:
            current.climateStatus = VehicleClimateStatus(
                activity: .idle,
                timeRemainingMinutes: nil,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .startPreCleaning:
            current.climateStatus = VehicleClimateStatus(
                activity: .ventilating,
                timeRemainingMinutes: 10,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .stopPreCleaning:
            current.climateStatus = VehicleClimateStatus(
                activity: .idle,
                timeRemainingMinutes: nil,
                timerTriggered: false,
                interiorTemperatureCelsius: current.climateStatus?.interiorTemperatureCelsius,
                requestedTemperatureCelsius: current.climateStatus?.requestedTemperatureCelsius
            )
        case .lock, .unlock:
            guard var exterior = current.exteriorStatus else { return }
            exterior.isLocked = (command == .lock)
            current.exteriorStatus = exterior
        case .setChargeTarget(let target):
            current.chargeTargetPercentage = target
        case .setAmpLimit(let amps):
            current.chargingCurrentAmps = amps
        default:
            return
        }
        latest = current
        stateStore.save(current)
        render()
    }

    private func showRemoteResult(title: String, message: String, success: Bool) {
        guard !success else { return }
        Task { @MainActor in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: L10n.text("OK"))
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                alert.runModal()
            }
        }
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
                statusController.dismissSettings()
            case .volvo:
                if Preferences.hasResumableSession(for: .volvo) {
                    switchActiveBrand(to: .volvo)
                    resumeStoredSession()
                    statusController.dismissSettings()
                } else {
                    beginVolvoSignIn(clientID: Preferences.volvoClientID, clientSecret: "", vccApiKey: "", nickname: "")
                }
            }
        case .closeSettings:
            statusController.dismissSettings()
        case .features:
            notifier.featureSelectionDidChange()
            updateNotificationAuthorizationIfNeeded()
            updateCheckConfiguration()
            refreshCoordinator.reloadVehicleMetadata()
        case .notifications:
            updateNotificationAuthorizationIfNeeded()
        case .presentation:
            Preferences.applyAppearance()
            refreshCoordinator.reloadVehicleMetadata()
        case .launchAtLogin:
            applyLaunchAtLogin(userInitiated: true)
        }
        render()
    }

    @objc private func systemAppearanceDidChange() {
        guard Preferences.appearanceMode == .system else { return }
        render()
        statusController?.refreshPopoverIfNeeded()
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

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleIncomingURL(url)
        }
    }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        handleIncomingURL(url)
    }

    private func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == "hisingen" else { return }

        if url.host == "oauth" || url.path.contains("callback") || url.query?.contains("code=") == true {
            volvoSignInPresenter.handleCallbackURL(url)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let command = host.isEmpty ? path : (path.isEmpty ? host : "\(host)/\(path)")

        switch command {
        case "refresh":
            refreshCoordinator.refreshNow()

        case "settings", "preferences":
            statusController.showSettings()

        case "toggle-settings":
            statusController.toggleSettings()

        case "status", "toggle":
            statusController.togglePopover()

        case "copy-vin":
            if let vin = latest?.vin, !vin.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(vin, forType: .string)
            }

        case "climate/start", "climatization/start":
            if Preferences.activeBrand == .volvo {
                let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let temp = queryItems?.first(where: { $0.name == "temp" || $0.name == "temperature" })?
                    .value.flatMap { Float($0) } ?? Float(Preferences.remoteClimateTemperature)
                performRemoteCommand(.startClimate(temperatureCelsius: temp, frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off))
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "climate/stop", "climatization/stop":
            if Preferences.activeBrand == .volvo {
                performRemoteCommand(.stopClimate)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "lock":
            if Preferences.activeBrand == .volvo {
                performRemoteCommand(.lock)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "unlock":
            if Preferences.activeBrand == .volvo {
                performRemoteCommand(.unlock)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "flash", "flash-lights":
            if Preferences.activeBrand == .volvo {
                performRemoteCommand(.flashLights)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "honk-flash", "honk":
            if Preferences.activeBrand == .volvo {
                performRemoteCommand(.honkAndFlash)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        default:
            volvoSignInPresenter.handleCallbackURL(url)
        }
    }
}


