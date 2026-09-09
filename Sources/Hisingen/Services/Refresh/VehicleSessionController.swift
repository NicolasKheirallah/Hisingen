import Foundation

/// What the session controller needs from the app shell. The controller owns the
/// `RefreshCoordinator` lifecycle, the active brand / vehicle selection, and the
/// session-derived display state (`latest`, `lastError`, `sessionValid`, `lastDiagnostics`);
/// the shell owns the status item, notifier, and mini-panel that a refresh has to poke.
@MainActor
protocol VehicleSessionControllerContext: AnyObject {
    /// Re-render everything from the controller's current state.
    func sessionStateDidChange()

    func showLoading()
    func setActiveVIN(_ vin: String?)

    /// A fresh telemetry snapshot arrived: mini-panel, anomaly check, notifier, snapshot cache.
    func didReceiveVehicleState(_ state: VehicleState)
    func authenticationRequired()
    func authenticationSucceeded()
    func vehicleSwitchDidPause()
    /// Reconcile settings after brand adoption and before restarting the session.
    func sessionCredentialsDidChange()
    /// A session was (re)established — schedule the background garage scan.
    func sessionDidEstablish()
}

/// Owns everything about "which account/vehicle are we showing and is its session live":
/// the `RefreshCoordinator` and all of its callback wiring, brand switching, stored-session
/// resume, vehicle selection, brand resolution, and the display state those produce.
///
/// Extracted from `AppDelegate`, which recreated the `RefreshCoordinator` on every brand
/// switch, re-ran ~85 lines of closure wiring each time, and held the session state machine
/// inline alongside the composition root, URL routing, and everything else.
@MainActor
final class VehicleSessionController {
    private let preferences: PreferencesStore
    private let stateStore: VehicleStateStore
    private let imageCache: CarImageCache
    private let sessionManager: SessionManager
    private let fleetStore: FleetStore
    private let observesEnvironment: Bool
    private let polestarAPI: any VehicleProviding
    private let volvoAPI: any VehicleProviding
    private weak var context: (any VehicleSessionControllerContext)?

    private var refreshCoordinator: RefreshCoordinator

    /// Session-derived display state. The shell reads these back when it renders.
    private(set) var latest: VehicleState?
    private(set) var lastError: String?
    private(set) var sessionValid = false
    private(set) var lastDiagnostics: DiagnosticsSnapshot?

    private var activeProvider: any VehicleProviding {
        preferences.activeBrand == .volvo ? volvoAPI : polestarAPI
    }

    /// True while an interactive refresh or vehicle switch owns the provider — the background
    /// garage scan checks this so it never competes with the foreground path.
    var isRefreshBusy: Bool { refreshCoordinator.isBusy }
    /// True inside a provider rate-limit pause.
    var isRefreshRateLimited: Bool { refreshCoordinator.isRateLimited }

    init(context: any VehicleSessionControllerContext,
         preferences: PreferencesStore,
         stateStore: VehicleStateStore,
         imageCache: CarImageCache,
         sessionManager: SessionManager,
         polestarAPI: any VehicleProviding,
         volvoAPI: any VehicleProviding, fleetStore: FleetStore,
         observesEnvironment: Bool = true) {
        self.context = context
        self.preferences = preferences
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.sessionManager = sessionManager
        self.fleetStore = fleetStore
        self.observesEnvironment = observesEnvironment
        self.polestarAPI = polestarAPI
        self.volvoAPI = volvoAPI
        let provider: any VehicleProviding = preferences.activeBrand == .volvo ? volvoAPI : polestarAPI
        self.refreshCoordinator = RefreshCoordinator(
            api: provider, stateStore: stateStore, observesEnvironment: observesEnvironment,
            imageCache: imageCache, preferences: preferences, sessionManager: sessionManager)
        connectCoordinator()
    }

    // MARK: - Launch

    /// Seeds the display from persisted state (no network) and renders once, so the status
    /// item shows the last known vehicle immediately at launch.
    func primeDisplayState() {
        let authenticated = preferences.hasResumableSession(for: preferences.activeBrand)
        let vin = preferences.vin(for: preferences.activeBrand)
        let nickname = preferences.vehicleNickname(for: vin)
        if !vin.isEmpty {
            setFleet(
                [CarSummary(vin: vin, title: nickname.isEmpty ? preferences.activeBrand.displayName : nickname)],
                activeVIN: vin)
        }
        sessionValid = authenticated
        latest = vin.isEmpty ? nil : fleetStore.snapshot(for: vin)
        context?.sessionStateDidChange()
    }

    /// Kicks off stored-session restoration.
    func resume() {
        resumeStoredSession()
    }

    // MARK: - Passthroughs

    func refreshNow() { refreshCoordinator.refreshNow() }
    func refreshIfStale() { refreshCoordinator.refreshIfStale() }
    func reloadVehicleMetadata() { refreshCoordinator.reloadVehicleMetadata() }
    func signOut() { refreshCoordinator.signOut() }
    func stop() { refreshCoordinator.stop() }

    func currentProvider() -> any VehicleProviding { activeProvider }

    /// Display-only post-command patch from `CommandCoordinator`; never persisted here.
    func applyOptimisticState(_ state: VehicleState) {
        latest = state
        context?.sessionStateDidChange()
    }

    // MARK: - Brand & vehicle selection

    func resolvedBrand(for vin: String) -> VehicleBrand {
        let upper = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if let snapshot = fleetStore.snapshot(for: upper) {
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

    /// Settings "switch to <brand>": adopt the brand and resume its stored session.
    func switchToBrandAndResume(_ brand: VehicleBrand) {
        switchActiveBrand(to: brand)
        resumeStoredSession()
    }

    /// After an interactive sign-in: force past the idempotence guard, then resume.
    func adoptBrandAfterSignIn(_ brand: VehicleBrand) {
        switchActiveBrand(to: brand, force: true)
        resumeStoredSession()
    }

    /// Adopts the account, reconciles app settings, then restarts with the new credentials.
    func credentialsDidChange(for brand: VehicleBrand) {
        switchActiveBrand(to: brand)
        context?.sessionCredentialsDidChange()
        refreshCoordinator.credentialsChanged(
            preferredVIN: preferences.vin.isEmpty ? nil : preferences.vin)
    }

    private func resumeStoredSession(targetVin: String? = nil) {
        refreshCoordinator.start(
            preferredVIN: targetVin ?? (preferences.vin.isEmpty ? nil : preferences.vin))
    }

    private func switchActiveBrand(to brand: VehicleBrand, targetVin: String? = nil, force: Bool = false) {
        if !force && preferences.activeBrand == brand && (targetVin == nil || targetVin == preferences.vin(for: brand)) { return }
        refreshCoordinator.stop()
        preferences.activeBrand = brand
        if let targetVin, !targetVin.isEmpty {
            preferences.setVin(targetVin, for: brand)
        }
        preferences.syncAppThemeStorageKey()
        sessionValid = preferences.hasResumableSession(for: brand)
        let vin = preferences.vin(for: brand)
        let nick = preferences.vehicleNickname(for: vin)
        latest = vin.isEmpty ? nil : fleetStore.snapshot(for: vin)
        lastError = nil
        setFleet(
            vin.isEmpty ? [] : [CarSummary(vin: vin, title: nick.isEmpty ? brand.displayName : nick)],
            activeVIN: vin.isEmpty ? nil : vin)
        refreshCoordinator = RefreshCoordinator(
            api: activeProvider, stateStore: stateStore, observesEnvironment: observesEnvironment,
            imageCache: imageCache, preferences: preferences, sessionManager: sessionManager)
        connectCoordinator()
        context?.sessionStateDidChange()
    }

    private func setFleet(_ cars: [CarSummary], activeVIN: String?) {
        fleetStore.updateCars(cars)
        context?.setActiveVIN(activeVIN)
    }

    // MARK: - RefreshCoordinator wiring

    private func connectCoordinator() {
        refreshCoordinator.onLoading = { [weak self] in self?.context?.showLoading() }
        // Keep the visible "active car" marker synced from the coordinator's selection — it
        // changes optimistically when a switch begins and again when one resolves, not only
        // on session-level events.
        refreshCoordinator.onSelectionChanged = { [weak self] vin in
            self?.context?.setActiveVIN(vin)
        }
        refreshCoordinator.onCars = { [weak self] cars, vin in
            guard let self else { return }
            self.setFleet(cars, activeVIN: vin)
        }
        // The garage scan belongs to session establishment only. It previously hung off
        // `onCars`, which vehicle switches also fired — so every switch scheduled a full scan
        // ~8 s later and the doubled request volume tripped provider rate limits right after
        // switching.
        refreshCoordinator.onSessionEstablished = { [weak self] in
            self?.context?.sessionDidEstablish()
        }
        refreshCoordinator.onState = { [weak self] state in
            guard let self else { return }
            var state = state
            if self.latest?.vin == state.vin, let pending = self.latest?.pendingCommand {
                state.pendingCommand = pending.updatingConfirmation(from: state)
            }
            self.context?.didReceiveVehicleState(state)
            self.latest = state
            self.lastError = nil
            self.context?.sessionStateDidChange()
        }
        // A switch attempt during a rate-limit pause otherwise vanishes without a trace when
        // the popover is closed: the menu closes, nothing changes on screen, and the only
        // record was an in-panel error banner nobody saw.
        refreshCoordinator.onSwitchPaused = { [weak self] in
            self?.context?.vehicleSwitchDidPause()
        }
        refreshCoordinator.onError = { [weak self] error in
            guard let self else { return }
            self.lastError = error.localizedDescription
            if error.requiresAuthentication && self.preferences.features.contains(.notifications) {
                self.sessionValid = false
                self.context?.authenticationRequired()
            }
            self.context?.sessionStateDidChange()
        }
        refreshCoordinator.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            let hasStored = self.preferences.hasResumableSession(for: self.preferences.activeBrand)
            self.sessionValid = diagnostics.sessionValid || hasStored
            self.lastDiagnostics = diagnostics
            Task { await LatestDiagnosticsStore.shared.update(diagnostics) }
            if (diagnostics.sessionValid || hasStored) && self.preferences.features.contains(.notifications) {
                self.context?.authenticationSucceeded()
            }
            self.context?.sessionStateDidChange()
        }
        let clearVehicles: () -> Void = { [weak self] in
            guard let self else { return }
            self.fleetStore.forget(brand: self.preferences.activeBrand)
            self.latest = nil
            self.lastError = nil
            self.sessionValid = false
            self.setFleet([], activeVIN: nil)
            self.context?.sessionStateDidChange()
        }
        refreshCoordinator.onSignedOut = clearVehicles
        refreshCoordinator.onCleared = clearVehicles
    }
}
