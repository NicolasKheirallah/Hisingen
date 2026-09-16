import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The process-wide store: intents and other non-view call sites read the same
    /// `.shared` instance, so per-instance caches cannot drift between the shell and them.
    private let preferences = PreferencesStore.shared
    /// The one process-wide storage handle: intents, image caching, and Settings default to
    /// `VehicleDatabase.shared`, so every consumer must share this same instance (and its
    /// SQLite handle) rather than opening parallel connections to the same file.
    private let vehicleDatabase = VehicleDatabase.shared
    private lazy var stateStore = VehicleStateStore(database: vehicleDatabase, preferences: preferences)
    private lazy var fleetStore = FleetStore(stateStore: stateStore, preferences: preferences)
    private let reverseGeocoder = ReverseGeocoder()
    private lazy var miniPanel = ChargingMiniPanelController(preferences: preferences)
    private let imageCache = CarImageCache()
    private lazy var polestarAPI = PolestarAPI(imageCache: imageCache, preferences: preferences)
    private lazy var volvoAPI = VolvoAPI(imageCache: imageCache, preferences: preferences)
    /// The one authority for which adapter backs which brand; every other holder of a brand asks
    /// this rather than repeating the choice.
    private lazy var providerRegistry = ProviderRegistry(polestar: polestarAPI, volvo: volvoAPI)
    private let sessionManager = SessionManager()
    private let resultPresenter = RemoteResultPresenter()
    private lazy var dockWarningBadge = DockWarningBadge(preferences: preferences)
    private lazy var connectionTester = ConnectionTester(
        sessionManager: sessionManager, providers: providerRegistry, preferences: preferences)
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
    private var chargingPlannerController: ChargingPlannerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One maintenance pass, before anything can read: legacy plist snapshots move into SQLite,
        // expired caches are dropped, and the legacy charging-summary repair starts. It used to be
        // split between construction and the read paths themselves.
        stateStore.activate()
        mainMenuController = MainMenuController(
            onCheckForUpdates: { [weak self] in self?.updateController.checkNow() },
            onOpenSettings: { [weak self] in self?.toggleSettingsInPopover() }
        )
        mainMenuController.install()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        preferences.migrateLegacyDefaults()
        preferences.migrateLegacyPassword()
        // Applied after the legacy-defaults migration: on the one launch that carries the
        // old domain's keys over, the migrated appearance is the one that must take effect.
        preferences.applyAppearance()
        HistoryRetention.pruneIfDue(database: vehicleDatabase)
        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.vehicleSession.refreshNow() },
            onSettings: { [weak self] in self?.toggleSettingsInPopover() },
            onCheckForUpdates: { [weak self] in self?.updateController.checkNow() },
            onRemoteCommand: { [weak self] command in self?.performRemoteCommand(command) },
             database: vehicleDatabase,
             reverseGeocoder: reverseGeocoder, imageCache: imageCache,
             preferences: preferences, fleetStore: fleetStore
        )
        statusController.onSelectCar = { [weak self] vin in self?.selectVehicle(vin: vin) }
        statusController.onCommandBrand = { [weak self] in
            guard let self else { return .polestar }
            return self.vehicleSession.currentProvider().brand
        }
        statusController.onDismissCommandReceipt = { [weak self] id in
            self?.vehicleSession.dismissCommandReceipt(id: id)
        }
        statusController.onOpenUpdate = { [weak self] in self?.updateController.checkNow() }
        statusController.onSettingsChanged = { [weak self] change in self?.settingsChanged(change) }
        statusController.onSignOut = { [weak self] in self?.signOut() }
        statusController.onTestConnection = { [weak self] brand in
            guard let self else { return (false, L10n.text("Hisingen is no longer running."), nil) }
            return await self.connectionTester.test(brand: brand)
        }
        notifier.onPermissionChanged = { [weak self] permission in
            self?.statusController.updateNotificationPermission(permission)
        }
        notifier.onQuickAction = { [weak self] action, vin in
            guard let self else { return }
            let targetBrand = self.vehicleSession.resolvedBrand(for: vin)
            guard self.preferences.hasResumableSession(for: targetBrand) else { return }
            switch action {
            case .lockVehicle:
                self.performRemoteCommand(.lock, targetVIN: vin)
            case .resumeChargeSchedule:
                if targetBrand == .polestar {
                    self.performRemoteCommand(.stopChargingOverride, targetVIN: vin)
                }
            }
        }
        notifier.onOpen = { [weak self] vin in
            self?.openVehicleFromNotification(vin: vin)
        }
        notifier.onWarningVehicleCountChanged = { [weak self] count in
            self?.dockWarningBadge.update(vehicleCount: count)
        }
        // The in-memory tiers an erase has to reach. Registered here because both holders are
        // built from `stateStore`, so an initializer edge back into the eraser would be a
        // cycle; Settings drives an eraser of its own, which shares this registry.
        VehicleMemoryCacheRegistry.shared.register(notifier)
        VehicleMemoryCacheRegistry.shared.register(fleetStore)
        statusController.updateNotificationPermission(notifier.permission)
        commandCoordinator = CommandCoordinator(
            context: self, preferences: preferences,
            database: vehicleDatabase, authorizer: remoteAuthorizer)
        calendarPreconditioning = CalendarPreconditioningController(
            preferences: preferences,
            sendClimateStart: { [weak self] in
                guard let self else {
                    return .deferred(reason: L10n.text("Hisingen is no longer running."))
                }
                return await self.startCalendarClimate()
            }
        )
        chargingPlannerController = ChargingPlannerController(
            preferences: preferences,
            notifier: notifier,
            priceService: .shared,
            database: vehicleDatabase,
            latestState: { [weak self] in self?.vehicleSession.latest },
            activeVINs: { [preferences] in
                [preferences.vin, preferences.vin(for: .polestar), preferences.vin(for: .volvo)]
                    .filter { !$0.isEmpty }
            },
            startCharging: { [weak self] in
                guard let self else {
                    return .deferred(reason: L10n.text("Hisingen is no longer running."))
                }
                return await self.startPlannerCharging()
            }
        )
        vehicleSession = VehicleSessionController(
            context: self, preferences: preferences, stateStore: stateStore,
            imageCache: imageCache, sessionManager: sessionManager,
            providers: providerRegistry, fleetStore: fleetStore)
        signInCoordinator = SignInCoordinator(
            context: self, preferences: preferences,
            polestarAPI: polestarAPI, volvoAPI: volvoAPI)
        garageScanner = GarageScanner(
            context: self,
            preferences: preferences,
            provider: { [providerRegistry] brand in providerRegistry.provider(for: brand) },
            hasResumableSession: { [preferences] brand in preferences.hasResumableSession(for: brand) },
            restoreDormantSession: { [sessionManager, providerRegistry, preferences] brand in
                let provider = providerRegistry.provider(for: brand)
                try await sessionManager.restore(api: provider, preferences: preferences)
            })
        urlRouter = URLCommandRouter(context: self)
        // Composition is complete: Shortcuts intents may now dispatch in-process. They
        // await this install, so a cold-launch intent waits here instead of round-tripping
        // through a URL open and polling the command audit table.
        AutomationHandoff.install(self)
        AutomationHandoff.installRefreshAction { [weak self] in self?.refreshNow() }
        updateController = UpdateController(context: self, preferences: preferences)
        vehicleSession.primeDisplayState()
        // Before any sign-in flow can run: installs upgrading from earlier versions carry
        // session material and must never be greeted by the first-run setup pass.
        preferences.seedSetupPassForExistingInstall()
        let initiallyAuthenticated = preferences.hasResumableSession(for: preferences.activeBrand)
        launchAtLoginController.reconcile(userInitiated: false)
        updateController.applyConfiguration()
        vehicleSession.resume()
        garageScanner.startLoop()
        urlRouter.startHandlingAppleEvents()
        calendarPreconditioning.start()
        chargingPlannerController.start()
        if !initiallyAuthenticated {
            statusController.openPopover()
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
        calendarPreconditioning.stop()
        chargingPlannerController.stop()
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
        signInCoordinator.cancelPolestarSignIn()
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
        // Interactive surfaces stay fire-and-forget: the banner/notification presentation
        // happens inside the coordinator; nothing here needs the outcome.
        Task { _ = await commandCoordinator.perform(command) }
    }

    func performRemoteCommand(_ command: RemoteCommand, targetVIN: String?) {
        Task { _ = await perform(command, targetVIN: targetVIN, origin: .userInitiated) }
    }

    private func settingsChanged(_ change: SettingsChange) {
        switch change {
        case .credentials:
            vehicleSession.credentialsDidChange(for: .polestar)
        case .volvoSignIn(let clientID, let clientSecret, let vccApiKey, let nickname):
            signInCoordinator.beginVolvoSignIn(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey, nickname: nickname)
        case .polestarCommandAuthorization:
            signInCoordinator.beginPolestarCommandAuthorization()
        case .polestarWebSignIn:
            signInCoordinator.beginPolestarWebSignIn()
        case .reauthenticate(let brand):
            switch brand {
            case .polestar:
                // Interactive browser window – no Polestar ID password re-entry.
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

    /// Builds the redacted diagnostic bundle off the main thread and offers a save panel.
    /// Reached from Settings → Privacy & Data and from the sign-in failure card, where
    /// attaching the failed exchanges to a bug report is the whole point.
    private func exportDiagnosticLogs() {
        let database = vehicleDatabase
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try await DiagnosticLogExporter.buildReport(database: database)
                }.value
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "hisingen_diagnostics_\(Int(Date().timeIntervalSince1970)).json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    presentExportFailure(error)
                }
            } catch {
                presentExportFailure(error)
            }
        }
    }

    /// A silently missing export file reads as lost data; surface the underlying cause
    /// (permissions, disk full) instead of swallowing it after the user picked a target.
    private func presentExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("Export Failed")
        alert.informativeText = "\(L10n.text("The diagnostic report could not be written."))\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }

    private func startCalendarClimate() async -> RemoteCommandDispatchOutcome {
        // Don't attempt (and don't spend a "Command not sent" banner) when the user has
        // turned the remote-climate feature off. Capability/session gating still happens
        // inside `CommandCoordinator`.
        guard preferences.features.contains(.remoteClimate) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        return await commandCoordinator.perform(
            .startClimate(
                temperatureCelsius: Float(preferences.remoteClimateTemperature),
                frontLeftSeat: preferences.remoteDriverSeatHeating,
                frontRightSeat: preferences.remoteFrontRightSeatHeating,
                rearLeftSeat: preferences.remoteRearLeftSeatHeating,
                rearRightSeat: preferences.remoteRearRightSeatHeating,
                steeringWheel: preferences.remoteSteeringWheelHeating
            ),
            origin: .automation)
    }

    /// The planner's unattended start-charging path. Guarded on the remote-charging
    /// feature so turning that off also disarms auto-start; `.automation` origin means
    /// the coordinator runs the routine-risk `startChargingOverride` silently (no sheet,
    /// no biometrics) – auto-start is its own explicit consent in the planner settings.
    private func startPlannerCharging() async -> RemoteCommandDispatchOutcome {
        guard preferences.features.contains(.remoteCharging) else {
            return .refused(reason: RemoteCommandError.disabled.localizedDescription)
        }
        return await commandCoordinator.perform(.startChargingOverride, origin: .automation)
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

// MARK: - RemoteCommandDispatching

extension AppDelegate: RemoteCommandDispatching {
    // `selectVehicle(vin:)` is declared on the class above; the dispatch protocol shares it
    // so entry points select then send through one seam.
    func perform(_ command: RemoteCommand, origin: RemoteCommandOrigin) async -> RemoteCommandDispatchOutcome {
        await commandCoordinator.perform(command, origin: origin)
    }

    func perform(
        _ command: RemoteCommand,
        targetVIN: String?,
        origin: RemoteCommandOrigin
    ) async -> RemoteCommandDispatchOutcome {
        if let targetVIN, !targetVIN.isEmpty {
            guard await vehicleSession.prepareVehicle(vin: targetVIN) else {
                return .deferred(reason: L10n.text("The target vehicle could not be loaded."))
            }
        }
        return await commandCoordinator.perform(command, origin: origin)
    }
}

// MARK: - CommandExecutionContext

extension AppDelegate: CommandExecutionContext {
    var vehicleState: VehicleState? { vehicleSession.latest }
    var sessionIsValid: Bool { vehicleSession.sessionValid }

    func currentCommandExecutor() -> any RemoteCommandExecuting { vehicleSession.currentProvider() }
    func commandInProgressDidChange() {
        render()
    }
    func presentResult(
        title: String,
        message: String,
        success: Bool,
        target: RemoteCommandTarget?
    ) {
        let subtitle = target?.displayName ?? vehicleSession.latest.map { state -> String in
            let nick = preferences.vehicleNickname(for: state.identity.vin)
            return nick.isEmpty ? state.model.brand.displayName : nick
        }
        // Inline banner in the Controls tab first – it is visible regardless of the system
        // notification permission – then the notification for when the panel is closed.
        lastRemoteCommandFeedback = RemoteCommandFeedback(
            title: title, message: message, success: success)
        render()
        resultPresenter.present(title: title, message: message, success: success, subtitle: subtitle)
    }
    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState?
    ) {
        // The refresh module's receipt ledger decides where the receipt is filed: the selected
        // vehicle's live collection, or the Remote Command target's VIN when that target is not
        // the visible vehicle. The shell holds no part of that rule.
        vehicleSession.beginCommandConfirmation(receipt, optimisticState: optimisticState)
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
            statusController.showSetupPass()
            return
        }
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
        fleetStore.retain(state)
        notifier.vehicleStateDidUpdate(state)
    }

    func garageScanDidCompletePass() {
        render()
    }
}

// MARK: - URLCommandRouterContext

extension AppDelegate: URLCommandRouterContext {
    var selectedVehicleVIN: String? { vehicleSession.latest?.identity.vin }
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
    func sessionStateDidChange() {
        render()
    }

    func showLoading() {
        statusController.showLoading()
    }

    func setActiveVIN(_ vin: String?) {
        statusController.activeVin = vin
    }

    func didReceiveVehicleState(_ state: VehicleState) {
        miniPanel.update(state: state)
        notifier.notifyChargingAnomalyIfNeeded(for: state)
        notifier.vehicleStateDidUpdate(state)
        chargingPlannerController.vehicleStateDidUpdate(state)
        if !state.commandState.receipts.contains(where: {
            $0.status.isAwaiting && $0.supportsTelemetryConfirmation
        }) {
            fleetStore.retain(state)
        }
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

    func sessionCredentialsDidChange() {
        launchAtLoginController.reconcile(userInitiated: true)
        notifier.featureSelectionDidChange()
        notifier.requestAuthorizationIfAnyAlertEnabled()
        updateController.applyConfiguration()
    }
}
