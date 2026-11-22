import Foundation

/// What a sign-out will actually remove. A connected account with another car on it keeps its
/// session and only hides the car being signed out; the account itself is revoked only when no
/// connected car remains on it.
enum VehicleSignOutPlan: Equatable {
    case disconnectVehicle(vin: String, nextVIN: String)
    case signOutAccount(fallback: SignOutFallback?)
}

struct SignOutFallback: Equatable {
    let brand: VehicleBrand
    /// `nil` when the account is connected but no vehicle has been discovered for it yet.
    let vin: String?
}

enum VehicleSignOutOutcome: Equatable {
    case vehicleDisconnected(vin: String)
    /// The account was signed out and another brand carries the session. `signedOutVINs` is
    /// every VIN whose Spotlight entry belonged to the removed account; empty when discovery
    /// never reported one.
    case switchedToBrand(VehicleBrand, vin: String?, signedOutVINs: [String])
    case signedOut
}

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
    /// A sign-out fell back to another vehicle, so a revocation failure has no error surface
    /// left on the old brand. The shell should say so without blaming the current vehicle.
    func signOutRevocationFailed(brand: VehicleBrand)
    func vehicleSwitchDidPause()
    /// Reconcile settings after brand adoption and before restarting the session.
    func sessionCredentialsDidChange()
    /// A session was (re)established – schedule the background garage scan.
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
    private let providers: ProviderRegistry
    private weak var context: (any VehicleSessionControllerContext)?

    private var refreshCoordinator: RefreshCoordinator

    /// Polestar connection mode the current `RefreshCoordinator` was built against. A mode
    /// flip reaches `credentialsDidChange` with the brand unchanged, so without this snapshot
    /// the coordinator would keep polling the previous adapter until relaunch. Seeded from the
    /// injected store in init rather than the global default so isolated test suites stay
    /// isolated.
    private var currentPolestarMode: PreferencesStore.PolestarConnectionMode

    /// Session-derived display state. The shell reads these back when it renders.
    private(set) var latest: VehicleState?
    private(set) var lastError: String?
    private(set) var sessionValid = false
    private(set) var signInRequired = true
    private(set) var lastDiagnostics: DiagnosticsSnapshot?

    private var activeProvider: any VehicleProviding {
        providers.provider(for: preferences.activeBrand)
    }

    /// True while an interactive refresh or vehicle switch owns the provider – the background
    /// garage scan checks this so it never competes with the foreground path.
    var isRefreshBusy: Bool { refreshCoordinator.isBusy }
    /// True inside a provider rate-limit pause.
    var isRefreshRateLimited: Bool { refreshCoordinator.isRateLimited }

    init(context: any VehicleSessionControllerContext,
         preferences: PreferencesStore,
         stateStore: VehicleStateStore,
         imageCache: CarImageCache,
         sessionManager: SessionManager,
         providers: ProviderRegistry, fleetStore: FleetStore,
         observesEnvironment: Bool = true) {
        self.context = context
        self.preferences = preferences
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.sessionManager = sessionManager
        self.fleetStore = fleetStore
        self.observesEnvironment = observesEnvironment
        self.providers = providers
        self.currentPolestarMode = preferences.polestarConnectionMode
        let provider = providers.provider(for: preferences.activeBrand)
        self.refreshCoordinator = RefreshCoordinator(
            api: provider, stateStore: stateStore, observesEnvironment: observesEnvironment,
            imageCache: imageCache, preferences: preferences, sessionManager: sessionManager,
            streaming: providers.streaming(for: preferences.activeBrand))
        connectCoordinator()
    }

    // MARK: - Launch

    /// Seeds the display from persisted state (no network) and renders once, so the status
    /// item shows the last known vehicle immediately at launch.
    func primeDisplayState() {
        if preferences.isDemoMode {
            enterDemoMode()
            return
        }
        let brand = preferences.activeBrand
        signInRequired = initiallyRequiresSignIn(for: brand)
        let savedVIN = preferences.vin(for: brand)
        let vin = preferences.isVehicleDetached(savedVIN) ? "" : savedVIN
        let nickname = preferences.vehicleNickname(for: vin)
        if !vin.isEmpty {
            setFleet(
                [CarSummary(vin: vin, title: nickname.isEmpty ? preferences.activeBrand.displayName : nickname)],
                activeVIN: vin)
        }
        latest = vin.isEmpty ? nil : fleetStore.snapshot(for: vin)
        context?.sessionStateDidChange()
    }

    /// Kicks off stored-session restoration.
    func resume() {
        if preferences.isDemoMode {
            enterDemoMode()
            return
        }
        resumeStoredSession()
    }

    /// Serves the local sample vehicle and never starts the provider. The shell reads `latest`
    /// exactly as it does a real snapshot, so every tab renders populated data with no network.
    func enterDemoMode() {
        refreshCoordinator.stop()
        let state = DemoMode.state()
        latest = state
        sessionValid = true
        signInRequired = false
        lastError = nil
        setFleet([DemoMode.carSummary], activeVIN: DemoMode.vin)
        context?.didReceiveVehicleState(state)
        context?.sessionStateDidChange()
    }

    // MARK: - Passthroughs

    func refreshNow() {
        if preferences.isDemoMode {
            enterDemoMode()
            return
        }
        refreshCoordinator.refreshNow()
    }
    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState?
    ) {
        refreshCoordinator.beginCommandConfirmation(receipt, optimisticState: optimisticState)
    }
    func dismissCommandReceipt(id: UUID) {
        refreshCoordinator.dismissCommandReceipt(id: id)
    }
    func refreshIfStale() {
        if preferences.isDemoMode { enterDemoMode(); return }
        refreshCoordinator.refreshIfStale()
    }

    func reloadVehicleMetadata() {
        if preferences.isDemoMode { enterDemoMode(); return }
        refreshCoordinator.reloadVehicleMetadata()
    }

    /// Signs out of the active vehicle, then keeps the reader on another registered vehicle
    /// when one can carry the session. See `signOutPlan()` for the decision.
    @discardableResult
    func signOut(forceAccount: Bool = false) -> VehicleSignOutOutcome {
        let plan = forceAccount
            ? .signOutAccount(fallback: fallbackCandidate(excluding: preferences.activeBrand))
            : signOutPlan()
        switch plan {
        case .disconnectVehicle(let vin, let nextVIN):
            disconnectVehicle(vin: vin, selecting: nextVIN)
            return .vehicleDisconnected(vin: vin)
        case .signOutAccount(let fallback):
            let signedOutBrand = preferences.activeBrand
            let signedOutVINs = signedOutVINs(for: signedOutBrand)
            if fallback != nil {
                // The fallback session owns the UI when the revoke answer arrives, so the old
                // coordinator's error channel is gone by generation; use the notice path.
                refreshCoordinator.onSignOutRevocationFailure = { [weak self] brand in
                    self?.context?.signOutRevocationFailed(brand: brand)
                }
            }
            refreshCoordinator.signOut()
            preferences.clearKnownVINs(for: signedOutBrand)
            preferences.clearDetachedVehicles(for: signedOutBrand)
            guard let fallback else { return .signedOut }
            switchActiveBrand(to: fallback.brand, targetVin: fallback.vin)
            resumeStoredSession(targetVin: fallback.vin)
            return .switchedToBrand(fallback.brand, vin: fallback.vin, signedOutVINs: signedOutVINs)
        }
    }

    /// The sign-out decision, split out so it can be tested without driving the UI or a network.
    ///
    /// 1. Another connected car on the active account: keep the account, hide the active car,
    ///    select the next one.
    /// 2. No sibling, but another brand has a resumable session: revoke the active account, then
    ///    switch to that brand and resume its stored vehicle.
    /// 3. Neither: revoke the account and let the shell show the login screen.
    func signOutPlan() -> VehicleSignOutPlan {
        let brand = preferences.activeBrand
        let activeVIN = currentSignOutVIN(for: brand)
        if !activeVIN.isEmpty {
            let siblings = registeredVehicleVINs(for: brand).filter { $0 != activeVIN }
            if let nextVIN = orderedVINs(siblings).first {
                return .disconnectVehicle(vin: activeVIN, nextVIN: nextVIN)
            }
        }
        return .signOutAccount(fallback: fallbackCandidate(excluding: brand))
    }

    /// Every vehicle the app knows for one brand, minus the ones already signed out of it.
    /// Direct provider discovery supplies same-account siblings before the garage scan has had a
    /// chance to retain them; the fleet store covers the dormant account and relaunches.
    func registeredVehicleVINs(for brand: VehicleBrand) -> [String] {
        var values = preferences.knownVINs(for: brand)
        values += fleetStore.knownVINs(for: brand)
        if brand == preferences.activeBrand {
            values += refreshCoordinator.cars.map(\.vin)
            if let latest, latest.model.brand == brand {
                values.append(latest.identity.vin)
            }
        }
        let detached = preferences.detachedVehicleVINs(for: brand)
        var seen = Set<String>()
        return values
            .map { $0.normalizedVIN }
            .filter { !$0.isEmpty && !detached.contains($0) && seen.insert($0).inserted }
    }

    /// Brings a vehicle signed out of this account back. The account session was never revoked,
    /// so this is a selection change, not a sign-in.
    func reconnectVehicle(vin: String) {
        let normalized = vin.normalizedVIN
        guard !normalized.isEmpty else { return }
        let brand = preferences.detachedVehicle(for: normalized)?.brand
        preferences.reconnectVehicle(vin: normalized)
        if let brand, preferences.activeBrand != brand {
            preferences.setVin(normalized, for: brand)
            switchActiveBrand(to: brand, targetVin: normalized)
            resumeStoredSession(targetVin: normalized)
        } else {
            selectVehicle(vin: normalized)
        }
    }

    func stop() { refreshCoordinator.stop() }

    func currentProvider() -> any VehicleProviding { activeProvider }

    // MARK: - Brand & vehicle selection

    func resolvedBrand(for vin: String) -> VehicleBrand {
        let upper = vin.normalizedVIN
        // The brand rule lives in `VehicleBrandResolver` because the command-line surface asks
        // the same question from a process with no shell; the snapshot this controller already
        // holds answers the dormant-account case for both of them.
        return VehicleBrandResolver.brand(
            for: upper,
            snapshotBrand: fleetStore.snapshot(for: upper)?.model.brand,
            preferences: preferences)
    }

    @discardableResult
    func selectVehicle(vin: String) -> Bool {
        let trimmedVIN = vin.normalizedVIN
        guard !trimmedVIN.isEmpty else { return false }
        if preferences.isDemoMode {
            guard trimmedVIN == DemoMode.vin else { return false }
            enterDemoMode()
            return true
        }
        // A signed-out vehicle has no active session in Hisingen. Deep links, Shortcuts and old
        // notifications must not silently re-add it; Bring Back in Settings is the explicit
        // path, and it goes through `reconnectVehicle`.
        guard !preferences.isVehicleDetached(trimmedVIN) else { return false }
        let targetBrand = resolvedBrand(for: trimmedVIN)
        if preferences.activeBrand == targetBrand {
            preferences.setVin(trimmedVIN, for: targetBrand)
            refreshCoordinator.selectCar(vin: trimmedVIN)
        } else {
            preferences.setVin(trimmedVIN, for: targetBrand)
            switchActiveBrand(to: targetBrand, targetVin: trimmedVIN)
            resumeStoredSession(targetVin: trimmedVIN)
        }
        return true
    }

    /// Resolves selection and first telemetry before a command is gated or sent. This makes
    /// VIN-targeted intents and deep links one awaited operation: the coordinator wakes the
    /// await itself when the selection task finishes, so there is no poll here.
    func prepareVehicle(vin: String, timeout: TimeInterval = 30) async -> Bool {
        let target = vin.normalizedVIN
        guard !target.isEmpty else { return sessionValid && latest != nil }
        if preferences.isDemoMode { return target == DemoMode.vin && latest != nil }
        if sessionValid, latest?.identity.vin.uppercased() == target,
           !refreshCoordinator.isBusy { return true }
        guard selectVehicle(vin: target) else { return false }
        // Read after `selectVehicle`: a brand switch rebuilds the coordinator, and the
        // rebuilt instance owns the selection that is now in flight.
        return await refreshCoordinator.selectionSettled(vin: target, timeout: timeout)
    }

    /// Settings "switch to <brand>": adopt the brand and resume its stored session.
    /// Settings selected another account for the active brand. The account store has already
    /// moved the credentials and preferences; this rebuilds the provider against the new
    /// session and resumes it.
    func accountDidSwitch(to brand: VehicleBrand) {
        if preferences.isDemoMode { enterDemoMode(); return }
        switchActiveBrand(to: brand, force: true)
        resumeStoredSession()
    }

    func switchToBrandAndResume(_ brand: VehicleBrand) {
        if preferences.isDemoMode { enterDemoMode(); return }
        switchActiveBrand(to: brand)
        resumeStoredSession()
    }

    /// After an interactive sign-in: force past the idempotence guard, then resume.
    func adoptBrandAfterSignIn(_ brand: VehicleBrand) {
        if preferences.isDemoMode { enterDemoMode(); return }
        // A successful sign-in registers the account from scratch; cars signed out of the
        // previous session on this brand come back with it.
        preferences.clearDetachedVehicles(for: brand)
        preferences.clearKnownVINs(for: brand)
        switchActiveBrand(to: brand, force: true)
        resumeStoredSession()
    }

    /// Adopts the account, reconciles app settings, then restarts with the new credentials.
    /// The forced brand switch is reserved for an actual brand or Polestar connection-mode
    /// change: it tears down and rebuilds the `RefreshCoordinator`, which must happen when the
    /// mode flip changes the backing adapter, but must not destroy the coordinator (and its
    /// remembered `accountEmail`) on ordinary same-brand credential updates.
    func credentialsDidChange(for brand: VehicleBrand) {
        if preferences.isDemoMode { enterDemoMode(); return }
        // Saving credentials is an explicit re-registration of the account, so vehicles signed
        // out of its previous session are visible again.
        preferences.clearDetachedVehicles(for: brand)
        preferences.clearKnownVINs(for: brand)
        let brandChanged = preferences.activeBrand != brand
        let modeChanged = (brand == .polestar && currentPolestarMode != preferences.polestarConnectionMode)
        if brandChanged || modeChanged {
            currentPolestarMode = preferences.polestarConnectionMode
            switchActiveBrand(to: brand, force: true)
        }
        context?.sessionCredentialsDidChange()
        refreshCoordinator.credentialsChanged(
            preferredVIN: preferences.vin.isEmpty ? nil : preferences.vin)
    }

    private func resumeStoredSession(targetVin: String? = nil) {
        let stored = preferences.vin.isEmpty ? nil : preferences.vin
        let preferred = targetVin ?? stored.flatMap {
            preferences.isVehicleDetached($0) ? nil : $0
        }
        refreshCoordinator.start(preferredVIN: preferred)
    }

    private func switchActiveBrand(to brand: VehicleBrand, targetVin: String? = nil, force: Bool = false) {
        if !force && preferences.activeBrand == brand && (targetVin == nil || targetVin == preferences.vin(for: brand)) { return }
        refreshCoordinator.stop()
        preferences.activeBrand = brand
        if let targetVin, !targetVin.isEmpty {
            preferences.setVin(targetVin, for: brand)
        }
        preferences.syncAppThemeStorageKey()
        sessionValid = false
        signInRequired = initiallyRequiresSignIn(for: brand)
        let vin = preferences.vin(for: brand)
        let nick = preferences.vehicleNickname(for: vin)
        latest = vin.isEmpty ? nil : fleetStore.snapshot(for: vin)
        lastError = nil
        setFleet(
            vin.isEmpty ? [] : [CarSummary(vin: vin, title: nick.isEmpty ? brand.displayName : nick)],
            activeVIN: vin.isEmpty ? nil : vin)
        refreshCoordinator = RefreshCoordinator(
            api: activeProvider, stateStore: stateStore, observesEnvironment: observesEnvironment,
            imageCache: imageCache, preferences: preferences, sessionManager: sessionManager,
            streaming: providers.streaming(for: brand))
        // The rebuilt coordinator resolved its adapter from the CURRENT mode; recording it
        // here (not only in credentialsDidChange) keeps the snapshot true whenever any path
        // switches brands, so the next credentialsDidChange cannot see a phantom mode flip
        // and tear the live coordinator down again.
        currentPolestarMode = preferences.polestarConnectionMode
        connectCoordinator()
        context?.sessionStateDidChange()
    }

    /// The VIN the reader is signing out: the stored selection, else the displayed car, else the
    /// provider's first known car. A detached VIN is never treated as the current one.
    private func currentSignOutVIN(for brand: VehicleBrand) -> String {
        let stored = preferences.vin(for: brand).normalizedVIN
        if !stored.isEmpty && !preferences.isVehicleDetached(stored) { return stored }
        if let latest, latest.model.brand == brand,
           !preferences.isVehicleDetached(latest.identity.vin) {
            return latest.identity.vin.normalizedVIN
        }
        return refreshCoordinator.cars
            .map { $0.vin.normalizedVIN }
            .first { !$0.isEmpty && !preferences.isVehicleDetached($0) } ?? ""
    }

    private func orderedVINs(_ vins: [String]) -> [String] {
        let order = preferences.garageVehicleOrder.map { $0.normalizedVIN }
        return vins.sorted {
            let left = order.firstIndex(of: $0) ?? Int.max
            let right = order.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
    }

    private func fallbackCandidate(excluding brand: VehicleBrand) -> SignOutFallback? {
        for other in VehicleBrand.allCases where other != brand {
            guard preferences.hasResumableSession(for: other) else { continue }
            let known = orderedVINs(registeredVehicleVINs(for: other))
            let selected = preferences.vin(for: other).normalizedVIN
            if let selectedVIN = known.first(where: { $0 == selected }) {
                return SignOutFallback(brand: other, vin: selectedVIN)
            }
            if let first = known.first {
                return SignOutFallback(brand: other, vin: first)
            }
            // A connected account with no known car can still discover one. A brand whose whole
            // known fleet is signed out must not bounce the reader into its login screen either;
            // it simply is not a fallback.
            if preferences.detachedVehicles(for: other).isEmpty {
                return SignOutFallback(brand: other, vin: nil)
            }
        }
        return nil
    }

    private func disconnectVehicle(vin: String, selecting nextVIN: String) {
        let brand = preferences.activeBrand
        // Read the label before `clear` drops the reader-authored nickname and theme.
        let title = preferences.privacyRedactionEnabled ? "" : displayTitle(for: vin, brand: brand)
        let erased = stateStore.detach(vin: vin, eraseHistory: preferences.eraseHistoryOnSignOut)
        preferences.detachVehicle(vin: vin, brand: brand, title: title)
        fleetStore.forget(vin: vin)
        refreshCoordinator.forgetCar(vin: vin)
        if erased {
            lastError = nil
        } else {
            handleFailure(.localDataErasure)
        }
        latest = fleetStore.snapshot(for: nextVIN)
        signInRequired = initiallyRequiresSignIn(for: brand)
        preferences.setVin(nextVIN, for: brand)
        context?.sessionStateDidChange()
        refreshCoordinator.selectCar(vin: nextVIN)
    }

    private func displayTitle(for vin: String, brand: VehicleBrand) -> String {
        let cached = fleetStore.snapshot(for: vin)
        let state = latest?.identity.vin.normalizedVIN == vin.normalizedVIN ? latest : cached
        return preferences.formattedVehicleTitle(
            vin: vin,
            modelName: state?.identity.modelName,
            modelYear: state?.identity.modelYear,
            registrationNo: state?.identity.registrationNo,
            fallbackBrand: brand
        )
    }

    private func signedOutVINs(for brand: VehicleBrand) -> [String] {
        var values = refreshCoordinator.cars.map(\.vin)
        values += preferences.knownVINs(for: brand)
        values.append(preferences.vin(for: brand))
        values += preferences.detachedVehicles(for: brand).map(\.vin)
        var seen = Set<String>()
        return values
            .map { $0.normalizedVIN }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private func initiallyRequiresSignIn(for brand: VehicleBrand) -> Bool {
        if preferences.hasExplicitSignOut(for: brand) { return true }
        // A saved vehicle can predate the Keychain presence flags. The provider still reads
        // the actual credential during restore.
        return preferences.vin(for: brand).isEmpty && !preferences.hasResumableSession(for: brand)
    }

    private func setFleet(_ cars: [CarSummary], activeVIN: String?) {
        let detached = preferences.detachedVehicleVINs(for: preferences.activeBrand)
        let visibleCars = cars.filter { !detached.contains($0.vin.normalizedVIN) }
        let visibleActiveVIN = activeVIN.flatMap {
            preferences.isVehicleDetached($0) ? nil : $0
        }
        fleetStore.updateCars(visibleCars)
        context?.setActiveVIN(visibleActiveVIN)
    }

    // MARK: - RefreshCoordinator wiring

    private func connectCoordinator() {
        refreshCoordinator.onEvent = { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: RefreshCoordinatorEvent) {
        switch event {
        case .loading:
            context?.showLoading()
        case .selectionChanged(let vin):
            context?.setActiveVIN(vin)
        case .sessionEstablished(let cars, let selectedVIN):
            lastError = nil
            setFleet(cars, activeVIN: selectedVIN)
            context?.sessionDidEstablish()
        case .state(let state):
            context?.didReceiveVehicleState(state)
            latest = state
            lastError = nil
            context?.sessionStateDidChange()
        case .switchPaused(let error):
            context?.vehicleSwitchDidPause()
            handleFailure(error)
        case .failed(let error):
            handleFailure(error)
        case .diagnostics(let diagnostics):
            handleDiagnostics(diagnostics)
        case .vehiclesCleared:
            fleetStore.forget(brand: preferences.activeBrand)
            latest = nil
            lastError = nil
            sessionValid = false
            signInRequired = true
            setFleet([], activeVIN: nil)
            context?.sessionStateDidChange()
        }
    }

    private func handleFailure(_ error: VehicleServiceError) {
        lastError = error.localizedDescription
        // An expired session is a signed-out state and a request for the user, not a
        // notification preference. The notifier gates its own delivery; the shell must still
        // hear about it whether notifications are on or off.
        if error.requiresAuthentication {
            sessionValid = false
            signInRequired = true
            context?.authenticationRequired()
        }
        context?.sessionStateDidChange()
    }

    private func handleDiagnostics(_ diagnostics: DiagnosticsSnapshot) {
        sessionValid = diagnostics.sessionValid
        if diagnostics.sessionValid { signInRequired = false }
        lastDiagnostics = diagnostics
        // A parked stream is still waiting for the user, even when the fallback poll keeps
        // succeeding: withdrawing the sign-in request here would hide the one thing the park
        // exists to say out loud.
        if diagnostics.sessionValid, !diagnostics.liveStreamNeedsAuthorization,
           preferences.features.contains(.notifications) {
            context?.authenticationSucceeded()
        }
        context?.sessionStateDidChange()
    }
}
