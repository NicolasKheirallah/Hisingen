import AppKit
import OSLog
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = AppLog.logger("application")
    private let preferences = PreferencesStore()
    private let vehicleDatabase = VehicleDatabase()
    private lazy var stateStore = VehicleStateStore(database: vehicleDatabase, preferences: preferences)
    private let reverseGeocoder = ReverseGeocoder()
    private lazy var miniPanel = ChargingMiniPanelController(preferences: preferences)
    private let imageCache = CarImageCache()
    private lazy var polestarAPI = PolestarAPI(imageCache: imageCache, preferences: preferences)
    private lazy var volvoAPI = VolvoAPI(imageCache: imageCache, preferences: preferences)
    private let volvoSignInPresenter = VolvoSignInPresenter()
    private let polestarCommandSignInPresenter = PolestarCommandSignInPresenter()
    private let polestarWebSignInPresenter = PolestarWebSignInPresenter()
    private let updateChecker = UpdateChecker()
    private let sessionManager = SessionManager()
    private lazy var remoteAuthorizer = RemoteActionAuthorizer(preferences: preferences)
    private lazy var notifier = Notifier(stateStore: stateStore, preferences: preferences)
    private var refreshCoordinator: RefreshCoordinator!
    private var statusController: StatusItemController!
    private var latest: VehicleState?
    private var lastError: String?
    private var sessionValid = false
    private var lastDiagnostics: DiagnosticsSnapshot?
    private var commandCoordinator: CommandCoordinator!
    private var garageRefreshTask: Task<Void, Never>?
    private var garageScanInProgress = false


    private var activeProvider: any VehicleProviding {
        preferences.activeBrand == .volvo ? volvoAPI : polestarAPI
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        preferences.applyAppearance()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceDidChange),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        preferences.migrateLegacyPassword()
        pruneDatabaseIfDue()
        statusController = StatusItemController(
            onRefresh: { [weak self] in self?.refreshCoordinator.refreshNow() },
            onSettings: { [weak self] in self?.toggleSettingsInPopover() },
            onCheckForUpdates: { [weak self] in self?.checkForUpdates() },
            onRemoteCommand: { [weak self] command in self?.performRemoteCommand(command) },
             database: vehicleDatabase,
             reverseGeocoder: reverseGeocoder, imageCache: imageCache,
             preferences: preferences
        )
        statusController.onSelectCar = { [weak self] vin in self?.selectVehicle(vin: vin) }
        statusController.onOpenUpdate = { [weak self] in
            NSWorkspace.shared.open(UpdateChecker.releasePage(for: self?.statusController.updateVersion))
        }
        statusController.onSettingsChanged = { [weak self] change in self?.settingsChanged(change) }
        statusController.onSignOut = { [weak self] in self?.signOut() }
        statusController.onTestConnection = { [weak self] brand in
            guard let self else { return (false, L10n.text("Hisingen is no longer running.")) }
            return await self.testConnection(for: brand)
        }
        notifier.onPermissionChanged = { [weak self] permission in
            self?.statusController.updateNotificationPermission(permission)
        }
        notifier.onQuickAction = { [weak self] action, vin in
            guard let self else { return }
            let targetBrand = self.resolvedBrand(for: vin)
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
            self?.applyWarningBadge(count: count)
        }
        statusController.updateNotificationPermission(notifier.permission)
        refreshCoordinator = RefreshCoordinator(api: activeProvider, stateStore: stateStore,
                                                imageCache: imageCache, preferences: preferences)
        commandCoordinator = CommandCoordinator(
            context: self, preferences: preferences,
            database: vehicleDatabase, authorizer: remoteAuthorizer)
        connectCoordinator()
        let initialAuthenticated = preferences.hasResumableSession(for: preferences.activeBrand)
        let initialVIN = preferences.vin(for: preferences.activeBrand)
        let initialNickname = preferences.vehicleNickname(for: initialVIN)
        let initialCar = initialVIN.isEmpty ? nil : CarSummary(vin: initialVIN, title: initialNickname.isEmpty ? preferences.activeBrand.displayName : initialNickname)
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
        preloadFleetSnapshots()
        startGarageRefreshLoop()
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

    private func preloadFleetSnapshots() {
        for brand in VehicleBrand.allCases {
            let vin = preferences.vin(for: brand)
            if !vin.isEmpty, statusController.cachedSnapshots[vin] == nil,
               let snapshot = stateStore.snapshot(for: vin) {
                statusController.cachedSnapshots[vin] = snapshot
            }
        }
    }

    private func cacheDormantBrandSnapshot() {
        preloadFleetSnapshots()
    }

    func resolvedBrand(for vin: String) -> VehicleBrand {
        let upper = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let snapshot = statusController?.cachedSnapshots[upper] {
            return snapshot.model.brand
        }
        if let snapshot = stateStore.snapshot(for: upper) {
            return snapshot.model.brand
        }
        if !preferences.vin(for: .volvo).isEmpty && upper == preferences.vin(for: .volvo).uppercased() {
            return .volvo
        }
        if !preferences.vin(for: .polestar).isEmpty && upper == preferences.vin(for: .polestar).uppercased() {
            return .polestar
        }
        if upper.hasPrefix("YV") {
            return .volvo
        }
        if upper.hasPrefix("YS") || upper.hasPrefix("LP") {
            return .polestar
        }
        return preferences.activeBrand
    }

    func selectVehicle(vin: String) {
        let trimmedVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmedVIN.isEmpty else { return }
        let targetBrand = resolvedBrand(for: trimmedVIN)
        if preferences.activeBrand == targetBrand {
            preferences.setVin(trimmedVIN, for: targetBrand)
            refreshCoordinator.selectCar(vin: trimmedVIN)
        } else {
            preferences.setVin(trimmedVIN, for: targetBrand)
            switchActiveBrand(to: targetBrand, targetVin: trimmedVIN)
            resumeStoredSession(targetVin: trimmedVIN)
        }
    }

    private func resumeStoredSession(targetVin: String? = nil) {
        let vinToUse = targetVin ?? (preferences.vin.isEmpty ? nil : preferences.vin)
        switch preferences.activeBrand {
        case .polestar:
            guard !preferences.email.isEmpty else { return }
            let (sessionToken, password) = sessionManager.polestarCredentials()
            guard sessionToken != nil || password != nil else { return }
            refreshCoordinator.start(
                email: preferences.email, password: password, sessionToken: sessionToken,
                preferredVIN: vinToUse
            )
        case .volvo:
            guard let credentials = sessionManager.volvoCredentials(preferences: preferences) else { return }
            Task { [weak self] in
                guard let self else { return }
                await volvoAPI.configure(clientID: credentials.clientID,
                                          clientSecret: credentials.clientSecret,
                                          vccApiKey: credentials.apiKey)

                guard preferences.activeBrand == .volvo else { return }
                refreshCoordinator.start(
                    email: "", password: nil, sessionToken: credentials.sessionToken,
                    preferredVIN: vinToUse
                )
            }
        }
    }

    private func switchActiveBrand(to brand: VehicleBrand, targetVin: String? = nil, force: Bool = false) {
        if !force && preferences.activeBrand == brand && (targetVin == nil || targetVin == preferences.vin(for: brand)) { return }
        refreshCoordinator?.stop()
        preferences.activeBrand = brand
        if let targetVin, !targetVin.isEmpty {
            preferences.setVin(targetVin, for: brand)
        }
        preferences.syncAppThemeStorageKey()
        let hasSession = preferences.hasResumableSession(for: brand)
        sessionValid = hasSession
        let vin = preferences.vin(for: brand)
        let nick = preferences.vehicleNickname(for: vin)
        latest = vin.isEmpty ? nil : (statusController.cachedSnapshots[vin] ?? stateStore.snapshot(for: vin))
        lastError = nil
        statusController.cars = vin.isEmpty ? [] : [CarSummary(vin: vin, title: nick.isEmpty ? brand.displayName : nick)]
        statusController.activeVin = vin.isEmpty ? nil : vin
        refreshCoordinator = RefreshCoordinator(api: activeProvider, stateStore: stateStore,
                                                imageCache: imageCache, preferences: preferences)
        connectCoordinator()
        render()
        cacheDormantBrandSnapshot()
    }

    /// Banner tap: surface the app focused on the tapped vehicle, switching brand when
    /// the VIN belongs to the dormant account.
    private func openVehicleFromNotification(vin: String) {
        guard !vin.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        selectVehicle(vin: vin)
        statusController.openPopover()
    }

    private var lastWarningVehicleCount = 0

    private func applyWarningBadge(count: Int) {
        lastWarningVehicleCount = count
        applyWarningBadge()
    }

    /// Dock-tile badge with the number of vehicles reporting warnings/alarm; inert for
    /// menu-bar-only users because the dock icon is hidden there anyway.
    private func applyWarningBadge() {
        guard preferences.features.contains(.notifications), preferences.showWarningBadge else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        NSApp.dockTile.badgeLabel = lastWarningVehicleCount > 0 ? "\(lastWarningVehicleCount)" : nil
    }

    private func beginVolvoSignIn(clientID: String, clientSecret: String, vccApiKey: String, nickname: String) {        var trimmedClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
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
           trimmedClientID == preferences.volvoClientID, clientSecret.isEmpty, vccApiKey.isEmpty {
            switchActiveBrand(to: .volvo, force: true)
            Task { [weak self] in
                guard let self else { return }
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                     preferences.setVehicleNickname(trimmedNickname, for: vin)
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
                 try await volvoAPI.completeSignIn(callbackURL: callbackURL, preferredVIN: nil, features: preferences.features)
                 preferences.volvoClientID = trimmedClientID
                try Keychain.saveVolvoClientSecret(effectiveSecret)
                try Keychain.saveVolvoApiKey(effectiveApiKey)
                if !trimmedNickname.isEmpty, let vin = await volvoAPI.resolvedVIN(preferred: nil) {
                     preferences.setVehicleNickname(trimmedNickname, for: vin)
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
                logger.error("Volvo sign-in failed: \(String(describing: error), privacy: .public)")
                showRemoteResult(
                    title: L10n.text("Volvo sign-in failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription, success: false
                )
            }
        }
    }

    /// Authorizes the Polestar command client (remote commands) through a real browser window
    /// instead of Hisingen scripting the login form itself — see `PolestarAPI.beginCommandAuthorization()`/
    /// `completeCommandAuthorization(callbackURL:)` and `PolestarCommandSignInPresenter`. This is
    /// a separate, explicit step from the base Polestar sign-in; remote commands stay unavailable
    /// until the user completes it (and again whenever the resulting session eventually expires).
    private func beginPolestarCommandAuthorization() {
        guard preferences.activeBrand == .polestar, preferences.hasResumableSession(for: .polestar) else {
            showRemoteResult(
                title: L10n.text("Sign in to Polestar first"),
                message: L10n.text("Connect your Polestar account before authorizing remote commands."),
                success: false
            )
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let authorizeURL = try await polestarAPI.beginCommandAuthorization()
                let callbackURL = try await polestarCommandSignInPresenter.signIn(authorizeURL: authorizeURL)
                try await polestarAPI.completeCommandAuthorization(callbackURL: callbackURL)
                // Persistent banner through the Notifier pipeline — the transient
                // `showRemoteResult` variant self-cleans after 5 s, which reads as
                // "did it actually go through?" for a step this easy to miss.
                notifier.notifyCommandNotice(
                    title: L10n.text("Remote commands authorized"),
                    body: L10n.text("Polestar remote commands are now available."),
                    subtitle: L10n.text("Polestar")
                )
            } catch {
                let mapped = error as? LocalizedError
                logger.error("Polestar command authorization failed: \(String(describing: error), privacy: .public)")
                showRemoteResult(
                    title: L10n.text("Authorization failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription, success: false
                )
            }
        }
    }

    /// Authorizes the Polestar web client (vehicle discovery & telemetry) through an in-app
    /// `WKWebView` window when headless PingFederate login is rejected with an interactive
    /// challenge (such as 2FA, CAPTCHA, or Terms of Service update).
    private func beginPolestarWebSignIn() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let (authorizeURL, redirectURI) = try await polestarAPI.beginWebAuthorization()
                let callbackURL = try await polestarWebSignInPresenter.signIn(
                    authorizeURL: authorizeURL,
                    redirectURI: redirectURI
                )
                let vin = preferences.vin(for: .polestar)
                try await polestarAPI.completeWebAuthorization(
                    callbackURL: callbackURL,
                    preferredVIN: vin.isEmpty ? nil : vin,
                    features: preferences.features
                )
                switchActiveBrand(to: .polestar, force: true)
                resumeStoredSession()
                statusController.dismissSettings()
                showRemoteResult(
                    title: L10n.text("Polestar sign-in successful"),
                    message: L10n.text("Successfully connected to your Polestar account! Fetching telemetry…"),
                    success: true
                )
            } catch {
                let mapped = error as? LocalizedError
                logger.error("Polestar interactive web sign-in failed: \(String(describing: error), privacy: .public)")
                showRemoteResult(
                    title: L10n.text("Sign-in failed"),
                    message: mapped?.errorDescription ?? error.localizedDescription,
                    success: false
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        commandCoordinator.cancelPendingWork()
        garageRefreshTask?.cancel()
        refreshCoordinator.stop()

        // The diagnostic store persists on a debounce; bridge one final flush onto a
        // semaphore so records from the last few seconds survive a normal quit. Bounded
        // wait: a hung write must not delay termination.
        let flushed = DispatchSemaphore(value: 0)
        Task {
            await APIDiagnosticLogStore.shared.flushPendingWrites()
            flushed.signal()
        }
        _ = flushed.wait(timeout: .now() + 2)
    }

    private func signOut() {
        commandCoordinator.cancelPendingWork()
        SpotlightIndexer.removeAll()
        refreshCoordinator.signOut()
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
        if sessionValid { refreshCoordinator.refreshIfStale() }
    }

    private func connectCoordinator() {
        refreshCoordinator.onLoading = { [weak self] in self?.statusController.showLoading() }
        // Keep the visible "active car" marker synced from the coordinator's selection —
        // it changes optimistically when a switch begins and again when one resolves,
        // not only on session-level events.
        refreshCoordinator.onSelectionChanged = { [weak self] vin in
            self?.statusController.activeVin = vin
        }
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
        // The garage scan belongs to session establishment only. It previously hung off
        // `onCars`, which vehicle switches also fired — so every switch scheduled a full
        // scan ~8 s later and the doubled request volume tripped provider rate limits
        // right after switching.
        refreshCoordinator.onSessionEstablished = { [weak self] in
            self?.scheduleGarageScan(after: 8)
        }
        refreshCoordinator.onState = { [weak self] state in
            self?.miniPanel.update(state: state)
            self?.notifyChargingAnomalyIfNeeded(for: state)
            guard let self else { return }
            notifier.vehicleStateDidUpdate(state)
            latest = state
            lastError = nil
            statusController.cachedSnapshots[state.vin] = state
            render()
        }
        // A switch attempt during a rate-limit pause otherwise vanishes without a trace
        // when the popover is closed: the menu closes, nothing changes on screen, and the
        // only record was an in-panel error banner nobody saw. Post a notification for
        // exactly that case; when the panel IS open, the banner suffices.
        refreshCoordinator.onSwitchPaused = { [weak self] in
            guard let self, !statusController.isPopoverVisible else { return }
            notifier.notifyCommandNotice(
                title: L10n.text("Vehicle Switch Paused"),
                body: L10n.text("The vehicle service asked Hisingen to slow down. Switching vehicles will resume automatically."))
        }
        refreshCoordinator.onError = { [weak self] error in
            guard let self else { return }
            lastError = error.localizedDescription
            if error.requiresAuthentication && preferences.features.contains(.notifications) {
                sessionValid = false
                notifier.authenticationRequired()
            }
            render()
        }
        refreshCoordinator.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            let hasStored = preferences.hasResumableSession(for: preferences.activeBrand)
            sessionValid = diagnostics.sessionValid || hasStored
            lastDiagnostics = diagnostics
            Task { await LatestDiagnosticsStore.shared.update(diagnostics) }
            if (diagnostics.sessionValid || hasStored) && preferences.features.contains(.notifications) {
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
        let isAuth = sessionValid || preferences.hasResumableSession(for: preferences.activeBrand)
        statusController.remoteCommandInProgress = commandCoordinator.isInProgress
        statusController.render(data: latest, error: lastError, authenticated: isAuth, diagnostics: lastDiagnostics)
    }

    private func startGarageRefreshLoop() {
        garageRefreshTask?.cancel()
        garageRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                guard let self else { return }
                await self.refreshGarageVehicles()
                do { try await Task.sleep(for: .seconds(5 * 60)) } catch { return }
            }
        }
    }

    private func scheduleGarageScan(after seconds: TimeInterval) {
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            await self?.refreshGarageVehicles()
        }
    }

    /// Runs `VehicleDatabase.pruneAgedHistory()` automatically, at most once every 7 days —
    /// previously the only way to bound `charging_sessions`/`battery_health_history`/
    /// `remote_commands_log` growth was the user manually clicking "Prune Old Samples" in
    /// Settings, which doesn't even touch those three tables (see `pruneHistoricalSamples`).
    /// Cheap enough to run synchronously on launch: these are low-row-count tables and the
    /// existing "Prune Old Samples" Settings action already runs its own prune this same way.
    private func pruneDatabaseIfDue() {
        let key = "last_automatic_history_prune"
        let interval: TimeInterval = 7 * 86400
        if let last = UserDefaults.standard.object(forKey: key) as? Date,
           Date().timeIntervalSince(last) < interval {
            return
        }
        vehicleDatabase.pruneAgedHistory()
        UserDefaults.standard.set(Date(), forKey: key)
    }

    /// Performs a real, cheap, read-only connectivity check for `brand` by re-running the same
    /// session-restore path already used at launch and by the background garage scan (never a
    /// fabricated result). Returns the elapsed time on success, or a human-readable failure
    /// reason — including "no stored session", which is reported without making any network call.
    private func testConnection(for brand: VehicleBrand) async -> (success: Bool, message: String) {
        guard preferences.hasResumableSession(for: brand) else {
            return (false, L10n.text("No active session found. Please sign in."))
        }
        let start = Date()
        do {
            let providerCars: [CarSummary]
            switch brand {
            case .polestar:
                providerCars = try await sessionManager.restorePolestarSession(api: polestarAPI, preferences: preferences)
            case .volvo:
                providerCars = try await sessionManager.restoreVolvoSession(api: volvoAPI, preferences: preferences)
            }
            guard !providerCars.isEmpty else {
                return (false, L10n.text("Signed in, but no vehicles were returned."))
            }
            let elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
            return (true, L10n.format("Connection active & verified (%d ms)", elapsedMs))
        } catch {
            let mapped = VehicleServiceError.map(error, provider: brand)
            logger.error("Connection test for \(brand.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return (false, mapped.errorDescription ?? error.localizedDescription)
        }
    }

    private func refreshGarageVehicles() async {
        guard !garageScanInProgress, !commandCoordinator.isInProgress else { return }
        // Never run inside a coordinator operation or a provider rate-limit pause: the
        // scan roughly doubles per-account request volume, which both extends the 429
        // backoff window and starves the interactive paths (refresh, vehicle switching).
        guard !refreshCoordinator.isBusy, !refreshCoordinator.isRateLimited else { return }
        garageScanInProgress = true
        defer { garageScanInProgress = false }

        let originalBrand = preferences.activeBrand
        for brand in VehicleBrand.allCases where preferences.hasResumableSession(for: brand) {
            guard !Task.isCancelled else { return }
            do {
                let provider: any VehicleProviding
                switch brand {
                case .polestar:
                    provider = polestarAPI
                    // The dormant brand's provider is not kept warm, so re-establish its
                    // session before scanning its vehicles.
                    if brand != originalBrand {
                        _ = try await sessionManager.restorePolestarSession(api: polestarAPI, preferences: preferences)
                    }
                case .volvo:
                    provider = volvoAPI
                    if brand != originalBrand {
                        _ = try await sessionManager.restoreVolvoSession(api: volvoAPI, preferences: preferences)
                    }
                }

                let selectedVIN = preferences.vin(for: brand)
                let providerCars = await provider.cars
                for car in providerCars {
                    guard !Task.isCancelled, preferences.activeBrand == originalBrand,
                          !commandCoordinator.isInProgress, !refreshCoordinator.isBusy else { return }
                    // If the user switched vehicles mid-scan, stand down at once: the
                    // coordinator owns provider selection from that moment.
                    if preferences.vin(for: brand) != selectedVIN { return }
                    if brand == originalBrand && car.vin == selectedVIN { continue }
                    try await provider.selectCar(vin: car.vin, features: preferences.features)
                    let state = try await provider.fetchVehicleState(vin: car.vin, features: preferences.features)
                    guard preferences.activeBrand == originalBrand,
                          preferences.vin(for: brand) == selectedVIN,
                          !commandCoordinator.isInProgress else { return }
                    stateStore.save(state)
                    statusController.cachedSnapshots[state.vin] = state
                    notifier.vehicleStateDidUpdate(state)
                }
                // No re-selection of the previously selected car at the end: telemetry and
                // commands address vehicles explicitly by VIN, so the shared selection
                // pointer carries no behavioral weight anymore — and re-selecting cost a
                // full Polestar discovery round trip on every single scan.
            } catch {
                logger.debug("Background garage refresh for \(brand.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        guard preferences.activeBrand == originalBrand else { return }
        render()
    }

    private func toggleSettingsInPopover() {
        statusController.showSettings()
    }

    /// One-shot anomaly notice per completed session. Location lives on the persisted DB
    /// session (domain sessions don't carry it), so detection runs here against the store.
    private func notifyChargingAnomalyIfNeeded(for state: VehicleState) {
        guard preferences.features.contains(.notifications),
              let last = vehicleDatabase.recentChargingSessions(for: state.vin, limit: 1).first,
              last.locationName?.isEmpty == false,
              let ended = last.endedAt,
              Date().timeIntervalSince(ended) < 600 else { return }
        let key = "anomaly_\(last.id)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let priors = vehicleDatabase.priorSessionPeaks(
            vin: state.vin, locationName: last.locationName ?? "",
            excludingSessionID: last.id)
        guard HistoryInsights.sessionPeakAnomaly(currentPeakKw: last.peakPowerKw,
                                                 priorPeaksKwAtSameLocation: priors) else { return }
        UserDefaults.standard.set(true, forKey: key)
        notifier.notifyChargingAnomaly(locationName: last.locationName ?? "", vin: state.vin)
    }

    private func performRemoteCommand(_ command: RemoteCommand) {
        commandCoordinator.perform(command)
    }

    private func showRemoteResult(title: String, message: String, success: Bool, subtitle: String? = nil) {
        // Use UserNotifications so command results follow the system notification settings.
        // Success is also visible via the optimistic state update (slider/button flips).
        let identifier = "remote-command-\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let subtitle { content.subtitle = subtitle }
        if !success { content.sound = .default }

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)

        // Successes self-clean after 5 seconds; failures persist until dismissed — a
        // failure vanishing before it was read reads as "command worked".
        guard success else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
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
            let switchedFromAnotherBrand = preferences.activeBrand != .polestar
            switchActiveBrand(to: .polestar)
            applyLaunchAtLogin(userInitiated: true)
            notifier.featureSelectionDidChange()
            updateNotificationAuthorizationIfNeeded()
            updateCheckConfiguration()
            // Deliberately reads the raw stored password rather than
            // `sessionManager.polestarCredentials()` — that helper suppresses the password
            // whenever a token exists, but here a freshly saved password must take priority
            // over any stale token so the coordinator actually exercises it.
            let password = ((try? Keychain.readPassword()) ?? nil).flatMap { $0.isEmpty ? nil : $0 }
            if switchedFromAnotherBrand, password == nil {
                resumeStoredSession()
            } else {
                refreshCoordinator.credentialsChanged(
                    email: preferences.email,
                    password: password,
                    preferredVIN: preferences.vin.isEmpty ? nil : preferences.vin
                )
            }
        case .volvoSignIn(let clientID, let clientSecret, let vccApiKey, let nickname):
            beginVolvoSignIn(clientID: clientID, clientSecret: clientSecret, vccApiKey: vccApiKey, nickname: nickname)
        case .polestarCommandAuthorization:
            beginPolestarCommandAuthorization()
        case .polestarWebSignIn:
            beginPolestarWebSignIn()
        case .switchToBrand(let brand):
            switch brand {
            case .polestar:
                switchActiveBrand(to: .polestar)
                resumeStoredSession()
                statusController.dismissSettings()
            case .volvo:
                if preferences.hasResumableSession(for: .volvo) {
                    switchActiveBrand(to: .volvo)
                    resumeStoredSession()
                    statusController.dismissSettings()
                } else {
                    beginVolvoSignIn(clientID: preferences.volvoClientID, clientSecret: "", vccApiKey: "", nickname: "")
                }
            }
        case .selectVehicle(let vin):
            selectVehicle(vin: vin)
            statusController.dismissSettings()
        case .closeSettings:
            statusController.dismissSettings()
        case .features:
            notifier.featureSelectionDidChange()
            updateNotificationAuthorizationIfNeeded()
            updateCheckConfiguration()
            refreshCoordinator.reloadVehicleMetadata()
            applyWarningBadge()
        case .notifications:
            updateNotificationAuthorizationIfNeeded()
            applyWarningBadge()
        case .presentation:
            preferences.applyAppearance()
            refreshCoordinator.reloadVehicleMetadata()
        case .launchAtLogin:
            applyLaunchAtLogin(userInitiated: true)
        }
        render()
    }

    @objc private func systemAppearanceDidChange() {
        guard preferences.appearanceMode == .system else { return }
        render()
        statusController?.refreshPopoverIfNeeded()
    }

    private func updateNotificationAuthorizationIfNeeded() {
        if preferences.features.contains(.notifications)
            && (preferences.notifyChargingStarted || preferences.notifyChargingComplete
                || preferences.notifyChargingProblem || preferences.notifyLowBattery
                || preferences.notifySoftwareUpdates || preferences.notifyVehicleWarnings
                || preferences.notifyRainWithWindowsOpen || preferences.notifyEveningUnlocked
                || preferences.notifyOpeningsLeftOpen || preferences.notifyServiceDue
                || preferences.notifyStaleTelemetry || preferences.notifySlowCharging
                || preferences.notifyPlugInReminder || preferences.notifyChargerConnection
                || preferences.notifyClimateChanges) {
            notifier.requestAuthorizationFromSettings()
        }
    }

    private func updateCheckConfiguration() {
        if preferences.features.contains(.updateChecks) {
            checkForUpdatesIfEnabled()
        } else {
            statusController.updateVersion = nil
        }
    }

    private func checkForUpdates() {
        guard preferences.features.contains(.updateChecks) else { return }
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
                    NSWorkspace.shared.open(UpdateChecker.releasePage(for: version))
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
        guard preferences.features.contains(.updateChecks) else { return }
        updateChecker.checkIfDue { [weak self] version in
            guard let self, self.preferences.features.contains(.updateChecks) else { return }
            statusController.updateVersion = version
            render()
        }
    }

    private func applyLaunchAtLogin(userInitiated: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            if preferences.launchAtLogin {
                switch service.status {
                case .notRegistered:
                    try service.register()
                case .requiresApproval:
                    if userInitiated { SMAppService.openSystemSettingsLoginItems() }
                case .enabled:
                    break
                case .notFound:
                    preferences.launchAtLogin = false
                @unknown default:
                    preferences.launchAtLogin = false
                }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
        } catch {
            preferences.launchAtLogin = service.status == .enabled || service.status == .requiresApproval
            logger.error("Launch-at-login update failed: \(String(describing: error), privacy: .public)")
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
        if url.scheme?.lowercased() == "polestar-explore" {
            polestarCommandSignInPresenter.handleCallbackURL(url)
            return
        }
        guard url.scheme?.lowercased() == "hisingen" else { return }

        if url.host == "oauth" || url.path.contains("callback") || url.query?.contains("code=") == true {
            volvoSignInPresenter.handleCallbackURL(url)
            return
        }

        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let command = host.isEmpty ? path : (path.isEmpty ? host : "\(host)/\(path)")
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems

        if let targetVin = queryItems?.first(where: { $0.name == "vin" })?.value, !targetVin.isEmpty {
            selectVehicle(vin: targetVin)
        }

        switch command {
        case "select-car", "switch-car", "switch-vehicle":
            if let vin = queryItems?.first(where: { $0.name == "vin" })?.value, !vin.isEmpty {
                selectVehicle(vin: vin)
            } else if let indexStr = queryItems?.first(where: { $0.name == "index" })?.value, let index = Int(indexStr) {
                statusController.selectVehicleByIndex(index)
            }

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
            if preferences.activeBrand == .volvo {
                let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                let temp = queryItems?.first(where: { $0.name == "temp" || $0.name == "temperature" })?
                    .value.flatMap { Float($0) } ?? Float(preferences.remoteClimateTemperature)
                performRemoteCommand(.startClimate(temperatureCelsius: temp, frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off, rearRightSeat: .off, steeringWheel: .off))
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "climate/stop", "climatization/stop":
            if preferences.activeBrand == .volvo {
                performRemoteCommand(.stopClimate)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "lock":
            if preferences.activeBrand == .volvo {
                performRemoteCommand(.lock)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "unlock":
            if preferences.activeBrand == .volvo {
                performRemoteCommand(.unlock)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "flash", "flash-lights":
            if preferences.activeBrand == .volvo {
                performRemoteCommand(.flashLights)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "honk-flash", "honk":
            if preferences.activeBrand == .volvo {
                performRemoteCommand(.honkAndFlash)
            } else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Polestar restricts remote write commands to paired mobile devices.")
                )
            }

        case "charge-target":
            // Polestar-only: Volvo's official API exposes no charging writes.
            guard preferences.activeBrand == .polestar else {
                notifier.notifyCommandNotice(
                    title: L10n.text("Command Restricted"),
                    body: L10n.text("Volvo's official API does not support changing charge settings.")
                )
                return
            }
            let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems
            let percent = queryItems?.first(where: { $0.name == "percent" || $0.name == "target" })?
                .value.flatMap { Int($0) } ?? 80
            performRemoteCommand(.setChargeTarget(percent))

        default:
            volvoSignInPresenter.handleCallbackURL(url)
        }
    }
}

// MARK: - CommandExecutionContext

extension AppDelegate: CommandExecutionContext {
    var vehicleState: VehicleState? { latest }
    var sessionIsValid: Bool { sessionValid }

    func currentProvider() -> any VehicleProviding { activeProvider }
    func applyOptimisticState(_ state: VehicleState) {
        latest = state
        render()
    }
    func commandInProgressDidChange() {
        render()
    }
    func presentResult(title: String, message: String, success: Bool) {
        let subtitle = latest.map { state -> String in
            let nick = preferences.vehicleNickname(for: state.vin)
            return nick.isEmpty ? state.model.brand.displayName : nick
        }
        showRemoteResult(title: title, message: message, success: success, subtitle: subtitle)
    }
    func refreshNowAfterCommand() {
        refreshCoordinator.refreshNow()
    }
}
