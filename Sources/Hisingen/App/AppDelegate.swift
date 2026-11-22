import AppKit
import CoreSpotlight
import HisingenIntents
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
    /// Optional Home Assistant integration for a home charger. Inert until the reader pairs one.
    lazy var homeCharging = HomeChargingModel(preferences: preferences, database: vehicleDatabase)
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Drop expired caches before restoring the session.
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
        preferences.migrateRenamedThemeIdentifiersOnce()
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
        statusController.homeCharging = homeCharging
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
        statusController.onSignOut = { [weak self] selection in self?.signOut(selection: selection) }
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
                self.performNotificationCommand(.lock, targetVIN: vin)
            case .unlockVehicle:
                self.performNotificationCommand(.unlock, targetVIN: vin)
            case .startClimate:
                // The banner carries no temperature, so the saved comfort setpoint applies;
                // the same default the deep link uses.
                self.performNotificationCommand(
                    .startClimate(temperatureCelsius: Float(self.preferences.remoteClimateTemperature),
                                  frontLeftSeat: .off, frontRightSeat: .off,
                                  rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off),
                    targetVIN: vin
                )
            case .viewDetails:
                self.openVehicleFromNotification(vin: vin)
            case .resumeChargeSchedule:
                if targetBrand == .polestar {
                    self.performNotificationCommand(.stopChargingOverride, targetVIN: vin)
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
        // Tibber first when connected, Elpriser when it is not or cannot answer.
        let plannerPrices = PlannerPriceProvider.shared
        plannerPrices.setTibberSource { [weak self] in
            await MainActor.run { self?.homeCharging.plannerTibberSource() }
        }
        chargingPlannerController = ChargingPlannerController(
            preferences: preferences,
            notifier: notifier,
            priceSource: PlannerPriceProvider.shared,
            database: vehicleDatabase,
            latestState: { [weak self] in self?.vehicleSession.latest },
            // While Home Assistant runs a plan for the car, the vehicle-side scheduler waits.
            plannerOwnedByHomeAssistant: { [weak self] vin in self?.homeCharging.ownsPlan(for: vin) ?? false },
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
            },
            isVehicleDetached: { [preferences] vin in preferences.isVehicleDetached(vin) })
        urlRouter = URLCommandRouter(context: self)
        // Composition is complete: Shortcuts intents may now dispatch in-process. They
        // await this install, so a cold-launch intent waits here instead of round-tripping
        // through a URL open and polling the command audit table.
        AutomationHandoff.install(self)
        AutomationHandoff.installRefreshAction { [weak self] in self?.refreshNow() }
        // The shared widget intents run in this process (openAppWhenRun), so they need the
        // app's dispatcher registered before a button tap can perform one.
        VehicleWidgetCommandRouter.install(WidgetIntentCommandHandler())
        updateController = UpdateController(context: self, preferences: preferences)
        vehicleSession.primeDisplayState()
        // Before any sign-in flow can run: installs upgrading from earlier versions carry
        // session material and must never be greeted by the first-run setup pass.
        preferences.seedSetupPassForExistingInstall()
        launchAtLoginController.reconcile(userInitiated: false)
        if !preferences.isDemoMode { updateController.applyConfiguration() }
        vehicleSession.resume()
        urlRouter.startHandlingAppleEvents()
        if !preferences.isDemoMode {
            // Demo mode is a local sample: no provider session, no garage scan, no price or
            // charger traffic. The session controller already served the seeded snapshot.
            garageScanner.startLoop()
            calendarPreconditioning.start()
            chargingPlannerController.reload()
            homeCharging.start()
            homeCharging.houseMeter.start()
        }
        if vehicleSession.signInRequired {
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

    /// Spotlight handoff: searching the car's name and pressing Return opens Hisingen on that
    /// car. The index key is a digest, never the VIN, so the match is resolved against the
    /// vehicles this Mac already knows — otherwise two indexed cars both landed on whichever
    /// one happened to be active.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard SpotlightIndexer.isHisingenActivity(userActivity) else { return false }
        let identifier = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String
        let known = VehicleBrand.allCases.flatMap { preferences.knownVINs(for: $0) }
        if let identifier,
           let vin = SpotlightIndexer.vin(forActivityIdentifier: identifier, among: known) {
            NSApp.activate(ignoringOtherApps: true)
            selectVehicle(vin: vin)
        }
        statusController.togglePopover()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        statusController.refreshGlobalHotKeyAccess()
        notifier.refreshAuthorizationStatus()
        if vehicleSession.sessionValid { vehicleSession.refreshIfStale() }
    }

    func render() {
        statusController.remoteCommandInProgress = commandCoordinator.isInProgress
        statusController.inFlightRemoteCommandID = commandCoordinator.inProgressCommandIdentifier
        statusController.lastRemoteCommandFeedback = lastRemoteCommandFeedback
        statusController.render(data: vehicleSession.latest, error: vehicleSession.lastError,
                               signInRequired: vehicleSession.signInRequired,
                               diagnostics: vehicleSession.lastDiagnostics)
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
