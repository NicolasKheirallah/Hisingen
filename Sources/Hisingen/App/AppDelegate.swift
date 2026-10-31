import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, RemoteCommandDispatching {
    /// The process-wide store: intents and other non-view call sites read the same
    /// `.shared` instance, so per-instance caches cannot drift between the shell and them.
    let preferences = PreferencesStore.shared
    /// The one process-wide storage handle: intents, image caching, and Settings default to
    /// `VehicleDatabase.shared`, so every consumer must share this same instance (and its
    /// SQLite handle) rather than opening parallel connections to the same file.
    let vehicleDatabase = VehicleDatabase.shared
    lazy var stateStore = VehicleStateStore(database: vehicleDatabase, preferences: preferences)
    lazy var fleetStore = FleetStore(stateStore: stateStore, preferences: preferences)
    let reverseGeocoder = ReverseGeocoder()
    lazy var miniPanel = ChargingMiniPanelController(preferences: preferences)
    /// The same instance `VehicleArtworkStore` reads and `LocalDataEraser` clears. A second
    /// instance meant sign-out erased a cache the renderer never used.
    let imageCache = CarImageCache.shared
    private lazy var polestarAPI = PolestarAPI(imageCache: imageCache, preferences: preferences)
    private lazy var polestarDataPortalAPI = PolestarDataPortalAPI(imageCache: imageCache, preferences: preferences)
    private lazy var volvoAPI = VolvoAPI(imageCache: imageCache, preferences: preferences)
    /// The one authority for which adapter backs which brand; every other holder of a brand asks
    /// this rather than repeating the choice.
    private lazy var providerRegistry = ProviderRegistry(
        polestar: polestarAPI, polestarDataPortal: polestarDataPortalAPI, volvo: volvoAPI, preferences: preferences)
    private let sessionManager = SessionManager()
    let resultPresenter = RemoteResultPresenter()
    lazy var dockWarningBadge = DockWarningBadge(preferences: preferences)
    lazy var connectionTester = ConnectionTester(
        sessionManager: sessionManager, providers: providerRegistry, preferences: preferences)
    lazy var launchAtLoginController = LaunchAtLoginController(preferences: preferences)
    private lazy var remoteAuthorizer = RemoteActionAuthorizer(preferences: preferences)
    lazy var notifier = Notifier(stateStore: stateStore, preferences: preferences)
    var vehicleSession: VehicleSessionController!
    var signInCoordinator: SignInCoordinator!
    var garageScanner: GarageScanner!
    private var urlRouter: URLCommandRouter!
    var updateController: UpdateController!
    private var mainMenuController: MainMenuController!
    var statusController: StatusItemController!
    /// Most recent remote-command outcome, mirrored into the Controls tab for an inline banner.
    var lastRemoteCommandFeedback: RemoteCommandFeedback?
    var commandCoordinator: CommandCoordinator!
    var calendarPreconditioning: CalendarPreconditioningController!
    var chargingPlannerController: ChargingPlannerController!
    var settingsWindow: NSWindow?

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
            guard let self else { return ConnectionCheck(success: false, message: L10n.text("Hisingen is no longer running."), failureKind: nil) }
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
            startCharging: { [weak self] vin in
                guard let self else {
                    return .deferred(reason: L10n.text("Hisingen is no longer running."))
                }
                return await self.startPlannerCharging(targetVIN: vin)
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

    func render() {
        let isAuth = vehicleSession.sessionValid || preferences.hasResumableSession(for: preferences.activeBrand)
        statusController.remoteCommandInProgress = commandCoordinator.isInProgress
        statusController.inFlightRemoteCommandID = commandCoordinator.inProgressCommandIdentifier
        statusController.lastRemoteCommandFeedback = lastRemoteCommandFeedback
        statusController.render(data: vehicleSession.latest, error: vehicleSession.lastError,
                               authenticated: isAuth, diagnostics: vehicleSession.lastDiagnostics)
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
