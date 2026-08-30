import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let preferences = PreferencesStore()
    private let vehicleDatabase = VehicleDatabase()
    private lazy var stateStore = VehicleStateStore(database: vehicleDatabase, preferences: preferences)
    private let reverseGeocoder = ReverseGeocoder()
    private lazy var miniPanel = ChargingMiniPanelController(preferences: preferences)
    private let imageCache = CarImageCache()
    private lazy var polestarAPI = PolestarAPI(imageCache: imageCache, preferences: preferences)
    private lazy var volvoAPI = VolvoAPI(imageCache: imageCache, preferences: preferences)
    private let sessionManager = SessionManager()
    private let resultPresenter = RemoteResultPresenter()
    private lazy var dockWarningBadge = DockWarningBadge(preferences: preferences)
    private lazy var connectionTester = ConnectionTester(
        sessionManager: sessionManager, polestarAPI: polestarAPI,
        volvoAPI: volvoAPI, preferences: preferences)
    private lazy var launchAtLoginController = LaunchAtLoginController(preferences: preferences)
    private lazy var remoteAuthorizer = RemoteActionAuthorizer(preferences: preferences)
    private lazy var notifier = Notifier(stateStore: stateStore, preferences: preferences)
    private var vehicleSession: VehicleSessionController!
    private var signInCoordinator: SignInCoordinator!
    private var garageScanner: GarageScanner!
    private var urlRouter: URLCommandRouter!
    private var updateController: UpdateController!
    private var mainMenuController: MainMenuController!
    private var statusController: StatusItemController!
    /// Most recent remote-command outcome, mirrored into the Controls tab for an inline banner.
    private var lastRemoteCommandFeedback: RemoteCommandFeedback?
    private var commandCoordinator: CommandCoordinator!
    private var calendarPreconditioning: CalendarPreconditioningController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two menu-bar instances share rotating OAuth refresh tokens and the diagnostics
        // archive. Keep one owner; a second launch activates the existing process and exits
        // before touching Keychain or network state.
        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
                         && !$0.isTerminated }) {
            existing.activate()
            NSApp.terminate(nil)
            return
        }
        mainMenuController = MainMenuController(
            onCheckForUpdates: { [weak self] in self?.updateController.checkNow() })
        mainMenuController.install()
        preferences.applyAppearance()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        preferences.migrateLegacyDefaults()
        preferences.migrateLegacyPassword()
        HistoryRetention.pruneIfDue(database: vehicleDatabase)
        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.vehicleSession.refreshNow() },
            onSettings: { [weak self] in self?.toggleSettingsInPopover() },
            onCheckForUpdates: { [weak self] in self?.updateController.checkNow() },
            onRemoteCommand: { [weak self] command in self?.performRemoteCommand(command) },
             database: vehicleDatabase,
             reverseGeocoder: reverseGeocoder, imageCache: imageCache,
             preferences: preferences
        )
        statusController.onSelectCar = { [weak self] vin in self?.selectVehicle(vin: vin) }
        statusController.onOpenUpdate = { [weak self] in self?.updateController.checkNow() }
        statusController.onSettingsChanged = { [weak self] change in self?.settingsChanged(change) }
        statusController.onSignOut = { [weak self] in self?.signOut() }
        statusController.onTestConnection = { [weak self] brand in
            guard let self else { return (false, L10n.text("Hisingen is no longer running.")) }
            return await self.connectionTester.test(brand: brand)
        }
        notifier.onPermissionChanged = { [weak self] permission in
            self?.statusController.updateNotificationPermission(permission)
        }
        notifier.onQuickAction = { [weak self] action, vin in
            guard let self else { return }
            let targetBrand = self.vehicleSession.resolvedBrand(for: vin)
            guard self.preferences.hasResumableSession(for: targetBrand) else { return }
            if self.preferences.activeBrand != targetBrand || self.preferences.vin(for: targetBrand) != vin {
                self.selectVehicle(vin: vin)
            }
            switch action {
            case .lockVehicle:
                self.performRemoteCommand(.lock)
            case .resumeChargeSchedule:
                if self.preferences.activeBrand == .polestar {
                    self.performRemoteCommand(.stopChargingOverride)
                }
            }
        }
        notifier.onOpen = { [weak self] vin in
            self?.openVehicleFromNotification(vin: vin)
        }
        notifier.onWarningVehicleCountChanged = { [weak self] count in
            self?.dockWarningBadge.update(vehicleCount: count)
        }
        statusController.updateNotificationPermission(notifier.permission)
        commandCoordinator = CommandCoordinator(
            context: self, preferences: preferences,
            database: vehicleDatabase, authorizer: remoteAuthorizer)
        calendarPreconditioning = CalendarPreconditioningController(
            preferences: preferences,
            sendClimateStart: { [weak self] in self?.startCalendarClimate() }
        )
        vehicleSession = VehicleSessionController(
            context: self, preferences: preferences, stateStore: stateStore,
            imageCache: imageCache, sessionManager: sessionManager,
            polestarAPI: polestarAPI, volvoAPI: volvoAPI)
        signInCoordinator = SignInCoordinator(
            context: self, preferences: preferences,
            polestarAPI: polestarAPI, volvoAPI: volvoAPI)
        garageScanner = GarageScanner(
            context: self,
            preferences: preferences,
            provider: { [polestarAPI, volvoAPI] brand in
                switch brand {
                case .volvo: return volvoAPI
                case .polestar: return polestarAPI
                }
            },
            hasResumableSession: { [preferences] brand in preferences.hasResumableSession(for: brand) },
            restoreDormantSession: { [sessionManager, polestarAPI, volvoAPI, preferences] brand in
                switch brand {
                case .polestar:
                    _ = try await sessionManager.restorePolestarSession(api: polestarAPI, preferences: preferences)
                case .volvo:
                    _ = try await sessionManager.restoreVolvoSession(api: volvoAPI, preferences: preferences)
                }
            })
        urlRouter = URLCommandRouter(context: self)
        updateController = UpdateController(context: self, preferences: preferences)
        vehicleSession.primeDisplayState()
        let initiallyAuthenticated = preferences.hasResumableSession(for: preferences.activeBrand)
        launchAtLoginController.reconcile(userInitiated: false)
        updateController.applyConfiguration()
        vehicleSession.resume()
        garageScanner.startLoop()
        urlRouter.startHandlingAppleEvents()
        calendarPreconditioning.start()
        if !initiallyAuthenticated {
            statusController.openPopover()
        }
    }

    /// Caches dormant-brand snapshots so the fleet list and brand switches have data without a
    /// round trip. Also the `VehicleSessionControllerContext` witness.
    func cacheFleetSnapshots() {
        for brand in VehicleBrand.allCases {
            let vin = preferences.vin(for: brand)
            if !vin.isEmpty, statusController.cachedSnapshots[vin] == nil,
               let snapshot = stateStore.snapshot(for: vin) {
                statusController.cachedSnapshots[vin] = snapshot
            }
        }
    }

    func selectVehicle(vin: String) {
        vehicleSession.selectVehicle(vin: vin)
    }

    /// Banner tap: surface the app focused on the tapped vehicle, switching brand when
    /// the VIN belongs to the dormant account.
    private func openVehicleFromNotification(vin: String) {
        guard !vin.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        selectVehicle(vin: vin)
        statusController.openPopover()
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandCoordinator.cancelPendingWork()
        calendarPreconditioning.stop()
        garageScanner.stop()
        vehicleSession.stop()

        // The diagnostic store persists on a debounce; bridge one final flush onto a
        // semaphore so records from the last few seconds survive a normal quit. Bounded
        // wait: a hung write must not delay termination.
        let flushed = DispatchSemaphore(value: 0)
        // `applicationWillTerminate` runs on the main actor. A child `Task {}` inherits that
        // actor, so waiting on the semaphore below would prevent its continuation from ever
        // returning to the main actor to signal it. Keep this tiny final flush detached.
        Task.detached(priority: .utility) {
            await APIDiagnosticLogStore.shared.flushPendingWrites()
            flushed.signal()
        }
        _ = flushed.wait(timeout: .now() + 2)
    }

    private func signOut() {
        commandCoordinator.cancelPendingWork()
        SpotlightIndexer.removeAll()
        vehicleSession.signOut()
    }

    /// Spotlight handoff: searching the car's name and pressing Return opens Hisingen.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard SpotlightIndexer.isHisingenActivity(userActivity) else { return false }
        statusController.togglePopover()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        statusController.refreshGlobalHotKeyAccess()
        notifier.refreshAuthorizationStatus()
        if vehicleSession.sessionValid { vehicleSession.refreshIfStale() }
    }

    private func render() {
        let isAuth = vehicleSession.sessionValid || preferences.hasResumableSession(for: preferences.activeBrand)
        statusController.remoteCommandInProgress = commandCoordinator.isInProgress
        statusController.inFlightRemoteCommandID = commandCoordinator.inProgressCommandIdentifier
        statusController.lastRemoteCommandFeedback = lastRemoteCommandFeedback
        statusController.render(data: vehicleSession.latest, error: vehicleSession.lastError,
                               authenticated: isAuth, diagnostics: vehicleSession.lastDiagnostics)
    }

    private func toggleSettingsInPopover() {
        statusController.showSettings()
    }

    func performRemoteCommand(_ command: RemoteCommand) {
        commandCoordinator.perform(command)
    }

    private func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .credentials:
            let switchedFromAnotherBrand = vehicleSession.switchToPolestarForCredentialChange()
            launchAtLoginController.reconcile(userInitiated: true)
            notifier.featureSelectionDidChange()
            notifier.requestAuthorizationIfAnyAlertEnabled()
            updateController.applyConfiguration()
            vehicleSession.resumeAfterCredentialChange(switchedFromAnotherBrand: switchedFromAnotherBrand)
        case .volvoSignIn(let clientID, let clientSecret, let vccApiKey, let nickname):
            signInCoordinator.beginVolvoSignIn(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey, nickname: nickname)
        case .polestarCommandAuthorization:
            signInCoordinator.beginPolestarCommandAuthorization()
        case .polestarWebSignIn:
            signInCoordinator.beginPolestarWebSignIn()
        case .reauthenticate(let brand):
            switch brand {
            case .polestar:
                // Interactive browser window — no Polestar ID password re-entry.
                signInCoordinator.beginPolestarWebSignIn()
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
                statusController.dismissSettings()
            case .volvo:
                if preferences.hasResumableSession(for: .volvo) {
                    vehicleSession.switchToBrandAndResume(.volvo)
                    statusController.dismissSettings()
                } else {
                    signInCoordinator.beginVolvoSignIn(clientID: preferences.volvoClientID, clientSecret: "", vccApiKey: "", nickname: "")
                }
            }
        case .selectVehicle(let vin):
            selectVehicle(vin: vin)
            statusController.dismissSettings()
        case .closeSettings:
            statusController.dismissSettings()
        case .features:
            notifier.featureSelectionDidChange()
            notifier.requestAuthorizationIfAnyAlertEnabled()
            updateController.applyConfiguration()
            vehicleSession.reloadVehicleMetadata()
            dockWarningBadge.refresh()
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

    private func startCalendarClimate() {
        // Don't attempt (and don't spend a "Command not sent" banner) when the user has
        // turned the remote-climate feature off. Capability/session gating still happens
        // inside `CommandCoordinator`.
        guard preferences.features.contains(.remoteClimate) else { return }
        commandCoordinator.perform(.startClimate(
            temperatureCelsius: Float(preferences.remoteClimateTemperature),
            frontLeftSeat: preferences.remoteDriverSeatHeating,
            frontRightSeat: preferences.remoteFrontRightSeatHeating,
            rearLeftSeat: preferences.remoteRearLeftSeatHeating,
            rearRightSeat: preferences.remoteRearRightSeatHeating,
            steeringWheel: preferences.remoteSteeringWheelHeating
        ), origin: .automation)
    }

    @objc private func systemAppearanceDidChange() {
        // The observer is registered before the shell is fully wired; ignore a theme flip
        // that lands in that window. `vehicleSession` is the last dependency `render()` needs
        // to come online, so its presence implies the rest are too.
        guard preferences.appearanceMode == .system, vehicleSession != nil else { return }
        render()
        statusController?.refreshPopoverIfNeeded()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            urlRouter.route(url)
        }
    }
}

// MARK: - CommandExecutionContext

extension AppDelegate: CommandExecutionContext {
    var vehicleState: VehicleState? { vehicleSession.latest }
    var sessionIsValid: Bool { vehicleSession.sessionValid }

    func currentProvider() -> any VehicleProviding { vehicleSession.currentProvider() }
    func applyOptimisticState(_ state: VehicleState) {
        vehicleSession.applyOptimisticState(state)
    }
    func commandInProgressDidChange() {
        render()
    }
    func presentResult(title: String, message: String, success: Bool) {
        let subtitle = vehicleSession.latest.map { state -> String in
            let nick = preferences.vehicleNickname(for: state.vin)
            return nick.isEmpty ? state.model.brand.displayName : nick
        }
        // Inline banner in the Controls tab first — it is visible regardless of the system
        // notification permission — then the notification for when the panel is closed.
        lastRemoteCommandFeedback = RemoteCommandFeedback(
            title: title, message: message, success: success)
        render()
        resultPresenter.present(title: title, message: message, success: success, subtitle: subtitle)
    }
    func refreshNowAfterCommand() {
        vehicleSession.refreshNow()
    }
}

// MARK: - SignInCoordinatorContext

extension AppDelegate: SignInCoordinatorContext {
    func activateBrandAfterSignIn(_ brand: VehicleBrand) {
        vehicleSession.adoptBrandAfterSignIn(brand)
    }

    func dismissSettingsAfterSignIn() {
        statusController.dismissSettings()
    }

    func refreshSettingsSurface() {
        statusController.refreshPopoverIfNeeded()
    }

    func presentSignInNotice(title: String, body: String, subtitle: String?) {
        notifier.notifyCommandNotice(title: title, body: body, subtitle: subtitle)
    }
}

// MARK: - GarageScanContext

extension AppDelegate: GarageScanContext {
    var commandPipelineIsBusy: Bool { commandCoordinator.isInProgress }
    var refreshPipelineIsBusy: Bool { vehicleSession.isRefreshBusy }
    var refreshPipelineIsRateLimited: Bool { vehicleSession.isRefreshRateLimited }

    func garageScanDidCaptureState(_ state: VehicleState) {
        stateStore.save(state)
        statusController.cachedSnapshots[state.vin] = state
        notifier.vehicleStateDidUpdate(state)
    }

    func garageScanDidCompletePass() {
        render()
    }
}

// MARK: - URLCommandRouterContext

extension AppDelegate: URLCommandRouterContext {
    var selectedVehicleVIN: String? { vehicleSession.latest?.vin }
    var activeBrand: VehicleBrand { preferences.activeBrand }
    var defaultRemoteClimateTemperatureCelsius: Double { preferences.remoteClimateTemperature }

    func handleOAuthCallback(_ url: URL) {
        signInCoordinator.handleCallbackURL(url)
    }

    func selectVehicleByIndex(_ index: Int) {
        statusController.selectVehicleByIndex(index)
    }

    func showSettings() {
        statusController.showSettings()
    }

    func toggleSettings() {
        statusController.toggleSettings()
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

// MARK: - VehicleSessionControllerContext

extension AppDelegate: VehicleSessionControllerContext {
    func cachedSnapshot(forVIN vin: String) -> VehicleState? {
        statusController?.cachedSnapshots[vin]
    }

    func sessionStateDidChange() {
        render()
    }

    func showLoading() {
        statusController.showLoading()
    }

    func setActiveVIN(_ vin: String?) {
        statusController.activeVin = vin
    }

    func setFleet(_ cars: [CarSummary], activeVIN: String?) {
        statusController.cars = cars
        statusController.activeVin = activeVIN
    }

    func fillSnapshotCache(for cars: [CarSummary]) {
        var snapshots = statusController.cachedSnapshots
        for car in cars where snapshots[car.vin] == nil {
            if let snapshot = stateStore.snapshot(for: car.vin) { snapshots[car.vin] = snapshot }
        }
        statusController.cachedSnapshots = snapshots
    }

    func didReceiveVehicleState(_ state: VehicleState) {
        miniPanel.update(state: state)
        notifier.notifyChargingAnomalyIfNeeded(for: state)
        notifier.vehicleStateDidUpdate(state)
        statusController.cachedSnapshots[state.vin] = state
    }

    func authenticationRequired() {
        notifier.authenticationRequired()
    }

    func authenticationSucceeded() {
        notifier.authenticationSucceeded()
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
}
