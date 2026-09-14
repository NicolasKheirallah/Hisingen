import AppKit
import Foundation
import Network
import OSLog

struct DiagnosticsSnapshot: Sendable {
    let lastSuccess: Date?
    let lastError: String?
    let latency: TimeInterval?
    let nextRefresh: Date?
    let sessionValid: Bool
    let networkAvailable: Bool
    let refreshInProgress: Bool

    /// Features the last fetch could not retrieve, and whether the displayed state came off
    /// disk rather than the network. Surfaced so a degraded dashboard can be explained in the
    /// app instead of only in the unified log.
    var unavailableFeatures: [AppFeature] = []
    var servingCachedSnapshot: Bool = false
    var liveStreamConnected: Bool = false
    var liveStreamRetryAt: Date? = nil
    var lastLiveFrameAt: Date? = nil
    var liveStreamMetrics = LiveStreamMetrics()

    /// Since-launch counters. Distinguishing "never refreshed" from "stopped
    /// refreshing" is the first fork in most refresh investigations.
    var refreshAttempts: Int = 0
    var refreshSuccesses: Int = 0
    var refreshFailures: Int = 0

    var commandConfirmationIdentifier: String? = nil
    var commandConfirmationStatus: CommandConfirmationStatus? = nil
    var commandConfirmationDeadline: Date? = nil
    var commandConfirmationFeatures: [AppFeature] = []
    var commandConfirmationSuspended: Bool = false
    var commandReceiptVisible: Bool = false
    var commandReceiptCount: Int = 0
    var awaitingCommandReceiptCount: Int = 0

    /// A vehicle selection has been requested but not yet confirmed (in flight, or waiting
    /// for an automatic retry after a raced provider-side flip). During this window
    /// `refreshInProgress` is often false — without this flag a support bundle cannot tell
    /// a pending switch apart from an idle app, which is precisely where same-brand
    /// multi-vehicle failures live.
    var vehicleSwitchPending: Bool = false
}

/// Process-wide handoff of the newest refresh diagnostics. The diagnostic-bundle
/// exporter reads this so exports contain the exact state the troubleshooting runbook
/// asks about first (`lastSuccess`, `rateLimitedUntil`, …) without threading the
/// coordinator through every view.
actor LatestDiagnosticsStore {
    static let shared = LatestDiagnosticsStore()
    private(set) var latest: DiagnosticsSnapshot?

    func update(_ snapshot: DiagnosticsSnapshot) {
        latest = snapshot
    }

    func current() -> DiagnosticsSnapshot? {
        latest
    }
}

/// Since-launch tally of the background garage scan. `DiagnosticsSnapshot.refreshAttempts`
/// only counts the active-brand `RefreshCoordinator`, so a support bundle otherwise showed
/// "7 refreshes" while the five-minute garage loop had quietly made hundreds of requests
/// against the dormant brand.
struct GarageScanDiagnostics: Sendable {
    var passesStarted: Int = 0
    var passesCompleted: Int = 0
    var lastPassCompletedAt: Date?
    var lastPassDurationSeconds: TimeInterval?
    var lastPassVehiclesScanned: Int = 0
    var vehiclesScannedTotal: Int = 0
    var brands: [VehicleBrand: GarageBrandDiagnostics] = [:]
    var lastPassWasPartial: Bool = false
}

struct GarageBrandDiagnostics: Sendable {
    var attempts: Int = 0
    var successes: Int = 0
    var failures: Int = 0
    var lastSuccess: Date?
    var lastError: String?
}

actor GarageScanDiagnosticsStore {
    static let shared = GarageScanDiagnosticsStore()
    private(set) var stats = GarageScanDiagnostics()

    func recordPassStart() {
        stats.passesStarted += 1
        stats.lastPassWasPartial = false
    }

    func recordBrandSuccess(_ brand: VehicleBrand) {
        stats.brands[brand, default: GarageBrandDiagnostics()].attempts += 1
        stats.brands[brand, default: GarageBrandDiagnostics()].successes += 1
        stats.brands[brand, default: GarageBrandDiagnostics()].lastSuccess = Date()
        stats.brands[brand, default: GarageBrandDiagnostics()].lastError = nil
    }

    func recordBrandFailure(_ brand: VehicleBrand, error: Error) {
        stats.brands[brand, default: GarageBrandDiagnostics()].attempts += 1
        stats.brands[brand, default: GarageBrandDiagnostics()].failures += 1
        stats.brands[brand, default: GarageBrandDiagnostics()].lastError =
            DiagnosticRedaction.redact(String(describing: error))
        stats.lastPassWasPartial = true
    }

    func recordPassComplete(vehiclesScanned: Int, duration: TimeInterval) {
        stats.passesCompleted += 1
        stats.lastPassCompletedAt = Date()
        stats.lastPassDurationSeconds = duration
        stats.lastPassVehiclesScanned = vehiclesScanned
        stats.vehiclesScannedTotal += vehiclesScanned
    }

    func recordPassAborted(vehiclesScanned: Int) {
        stats.lastPassWasPartial = true
        // Captured snapshots remain real work even when a user action interrupts the rest of
        // the pass. Count them once here; completed passes account for theirs above.
        stats.vehiclesScannedTotal += vehiclesScanned
    }

    func current() -> GarageScanDiagnostics { stats }
}

enum RefreshPolicy {
    /// Floor for polls while the vehicle reports itself unavailable (asleep, power saving,
    /// in service). Deep-sleeping cars answer every poll with the same stale snapshot, so
    /// hammering the backend buys nothing; 15 minutes still recovers promptly on wake.
    static let vehicleAsleepInterval: TimeInterval = 1_800

    static func regularInterval(isCharging: Bool, isClimateActive: Bool = false) -> TimeInterval {
        (isCharging || isClimateActive) ? 120 : 600
    }

    /// Effective interval combines the activity-based cadence with vehicle availability:
    /// an asleep vehicle stretches toward `vehicleAsleepInterval`, never shortening the
    /// charging cadence below its normal value.
    static func interval(isCharging: Bool, isClimateActive: Bool,
                         isVehicleAvailable: Bool?) -> TimeInterval {
        let base = regularInterval(isCharging: isCharging, isClimateActive: isClimateActive)
        guard isVehicleAvailable == false else { return base }
        return max(base, vehicleAsleepInterval)
    }

    static func retryDelay(failureCount: Int, retryAfter: TimeInterval?,
                           requiresNewSession: Bool = false) -> TimeInterval {
        if let retryAfter { return min(max(retryAfter, 30), 3_600) }
        let base = min(30 * pow(2, Double(min(max(failureCount - 1, 0), 5))), 900)
        // Re-establishing a session hits the identity provider rather than the telemetry API,
        // so back off harder and allow a longer ceiling before trying again.
        return requiresNewSession ? min(max(base, 60) * 2, 1_800) : base
    }
}

/// The complete outward lifecycle of a refresh session. A single typed channel keeps related
/// transitions atomic (notably session establishment and a rate-limited vehicle switch) and
/// prevents consumers from constructing inconsistent combinations of callback handlers.
enum RefreshCoordinatorEvent {
    case loading
    case state(VehicleState)
    case sessionEstablished(cars: [CarSummary], selectedVIN: String)
    case selectionChanged(String)
    case switchPaused(VehicleServiceError)
    case failed(VehicleServiceError)
    case diagnostics(DiagnosticsSnapshot)
    case vehiclesCleared
}

@MainActor
final class RefreshCoordinator {
    enum Trigger { case timer, manual, wake, networkRestored }

    private let api: any VehicleProviding
    private let stateStore: VehicleStateStore
    private let imageCache: CarImageCache
    private let preferences: PreferencesStore
    private let sessionManager: SessionManager
    /// Computes the delay before the next attempt. Injectable so tests can collapse the
    /// production exponential backoff (which legitimately stretches to minutes) to zero.
    private let retryDelay: (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval
    /// Delay between automatic retries of a raced vehicle selection. Injectable for tests.
    private let selectionRetryDelay: TimeInterval
    /// Maximum time to seek fresh telemetry after a command. Injectable so tests can
    /// collapse the production safety cap.
    private let commandConfirmationWindow: TimeInterval
    private let commandConfirmationInitialPollDelay: TimeInterval
    private let commandConfirmationPollInterval: TimeInterval
    private let liveStreamPolicy: LiveStreamPolicy
    private let liveStreamJitter: () -> Double
    private let now: () -> Date
    private let logger = AppLog.logger("refresh")
    /// Interval instrumentation for Instruments' os_signpost tool — free refresh-latency
    /// timelines without touching the unified log.
    private static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "refresh")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    /// Task.sleep-based one-shot scheduler for retries, confirmation polls, and the next
    /// scheduled refresh. Task ticks are immune to run-loop modes — a status-item menu no
    /// longer defers them — and cancel structurally (shared `AsyncTimerLoop`, RT-08).
    private let scheduler = AsyncTimerLoop()
    private var task: Task<Void, Never>?
    private var commandWatchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureCount = 0
    private var rateLimitedUntil: Date?
    private var lastManualRefresh: Date?
    private var sleeping = false
    private var networkAvailable = true
    /// Connection lifecycle for `.realTimeUpdates`: reconnects, circuit breaker, metrics.
    /// `nil` until a first stream starts, replaced on every restart.
    private var streamEngine: LiveStreamEngine?
    private let receiptLedger: CommandConfirmationLedger
    private var lastFullRefreshAt: Date?
    private var sessionReady = false
    private var accountEmail = ""
    private var sessionIntent: SessionManager.Intent = .resume
    /// The selection this coordinator last started and has not yet resolved. Set when a
    /// switch begins, cleared only when it completes (or the session re-resolves the VIN).
    /// Because `preferences.vin` is written optimistically at switch start, this marker is
    /// what distinguishes "already settled on car X" from "car X failed mid-switch and the
    /// user is retrying" — without it a failed switch was unrecoverable.
    private var requestedSelectionVIN: String?
    /// Automatic retries consumed for the current selection attempt. A raced provider-side
    /// selection flip surfaces as `.notConfigured`, which is otherwise terminal; bounded
    /// retries recover it without letting a genuinely broken state loop forever.
    private var selectionRetryCount = 0
    private var observerTokens: [NSObjectProtocol] = []

    // Since-launch counters, published through DiagnosticsSnapshot so a support bundle
    // can distinguish "never refreshed" from "stopped refreshing".
    private(set) var refreshAttempts = 0
    private(set) var refreshSuccesses = 0
    private(set) var refreshFailures = 0

    /// Last provider-authored state. This is the only state allowed into persistence,
    /// history, telemetry confirmation, and notification evidence.
    private var latestAuthoritative: VehicleState?
    /// UI projection of `latestAuthoritative`, optionally carrying a short-lived optimistic
    /// command overlay while an observable command is awaiting confirmation.
    private(set) var latest: VehicleState?
    private(set) var cars: [CarSummary] = []
    private(set) var lastError: VehicleServiceError?
    private(set) var nextRefresh: Date?
    private(set) var lastLatency: TimeInterval?

    var onEvent: ((RefreshCoordinatorEvent) -> Void)?

    /// True while a network operation owned by this coordinator is in flight. The background
    /// garage scan checks this so it never competes with (or flips shared provider state
    /// underneath) an interactive refresh or vehicle switch.
    var isBusy: Bool { task != nil }
    /// True inside a provider rate-limit pause. The garage scan also checks this: hammering
    /// through the window extends the backoff and starves the interactive paths.
    var isRateLimited: Bool { rateLimitedUntil.map({ $0 > now() }) ?? false }

    init(api: any VehicleProviding, stateStore: VehicleStateStore,
         observesEnvironment: Bool = true,
         imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore,
         sessionManager: SessionManager = SessionManager(),
         retryDelay: @escaping (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval = RefreshPolicy.retryDelay,
         selectionRetryDelay: TimeInterval = 2,
         liveStreamPolicy: LiveStreamPolicy = LiveStreamPolicy(),
         liveStreamJitter: @escaping () -> Double = { Double.random(in: 0...1) },
         now: @escaping () -> Date = Date.init,
         commandConfirmationWindow: TimeInterval = CommandReceipt.maximumConfirmationDuration,
         commandConfirmationInitialPollDelay: TimeInterval = 2,
         commandConfirmationPollInterval: TimeInterval = 3) {
        self.api = api
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.preferences = preferences
        self.sessionManager = sessionManager
        self.retryDelay = retryDelay
        self.selectionRetryDelay = selectionRetryDelay
        self.liveStreamPolicy = liveStreamPolicy
        self.liveStreamJitter = liveStreamJitter
        self.now = now
        self.commandConfirmationWindow = commandConfirmationWindow
        self.commandConfirmationInitialPollDelay = commandConfirmationInitialPollDelay
        self.commandConfirmationPollInterval = commandConfirmationPollInterval
        self.receiptLedger = CommandConfirmationLedger(store: stateStore, now: now, confirmationWindow: commandConfirmationWindow)
        guard observesEnvironment else { return }
        installSystemObservers()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let coordinator = self
            Task { @MainActor in coordinator?.networkDidChange(available) }
        }
        monitor.start(queue: monitorQueue)
    }

    func start(preferredVIN: String?) {
        accountEmail = preferences.email
        if let preferredVIN {
            if receiptLedger.restore(forVIN: preferredVIN) {
                scheduleConfirmationWatchdog(vin: preferredVIN)
            }
            if var cached = stateStore.snapshot(for: preferredVIN) {
                cached.commandState.optimisticLockUntil = nil
                latestAuthoritative = cached
                cached.commandState.receipts = receiptLedger.visibleReceipts
                latest = cached
                onEvent?(.state(cached))
            }
        }
        beginSession(preferredVIN: preferredVIN)
    }

    func credentialsChanged(preferredVIN: String?) {
        let oldAccount = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newAccount = preferences.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountChanged = !oldAccount.isEmpty && oldAccount != newAccount
        if let vin = latest?.identity.vin {
            stateStore.clearCommandReceipts(for: vin)
        }
        cancelCurrentWork()
        requestedSelectionVIN = nil
        selectionRetryCount = 0
        failureCount = 0
        rateLimitedUntil = nil
        sessionReady = false
        accountEmail = preferences.email
        sessionIntent = .credentialsChanged
        if accountChanged {
            let eraseHistory = preferences.eraseHistoryOnSignOut
            for car in cars {
                stateStore.clear(vin: car.vin, eraseHistory: eraseHistory)
            }
            if cars.isEmpty, !preferences.vin.isEmpty {
                stateStore.clear(vin: preferences.vin, eraseHistory: eraseHistory)
            }
            latest = nil
            latestAuthoritative = nil
            cars = []
            lastError = nil
            onEvent?(.vehiclesCleared)
        }
        let requestGeneration = generation
        task = Task {
            await api.resetSession()
            guard requestGeneration == generation, !Task.isCancelled else { return }
            task = nil
            self.beginSession(preferredVIN: preferredVIN)
        }
        publishDiagnostics()
    }

    func refreshNow() {
        if let rateLimitedUntil, rateLimitedUntil > now() {
            nextRefresh = rateLimitedUntil
            publishDiagnostics()
            return
        }
        // Debounce: skip manual refresh if one started less than 2 seconds ago — rapid
        // clicks on the refresh button (or ⌘R spam) would otherwise stack requests.
        if let lastManualRefresh, now().timeIntervalSince(lastManualRefresh) < 2, task != nil {
            return
        }
        lastManualRefresh = now()
        guard sessionReady else {
            beginSession(preferredVIN: preferences.vin.nilIfEmpty)
            return
        }
        refresh(trigger: .manual)
    }

    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState? = nil
    ) {
        if var optimisticState,
           optimisticState.identity.vin == latest?.identity.vin {
            optimisticState.commandState.receipts = []
            latest = optimisticState
        }
        receiptLedger.begin(receipt)
        receiptLedger.persist(vin: latest?.identity.vin)
        logger.info(
            "Command confirmation started for \(receipt.commandIdentifier, privacy: .public); telemetry observable: \(receipt.supportsTelemetryConfirmation, privacy: .public)"
        )
        publishCommandReceipts()
        if receipt.status.isAwaiting, let vin = latest?.identity.vin {
            refreshCommandConfirmationInfrastructure(vin: vin)
        }
        guard receipt.status.isAwaiting else {
            publishDiagnostics()
            return
        }
        schedule(after: min(commandConfirmationInitialPollDelay, commandConfirmationPollInterval),
                 retrySession: false, addsJitter: false)
        publishDiagnostics()
    }

    func dismissCommandReceipt(id: UUID) {
        guard receiptLedger.dismiss(id: id, vin: latest?.identity.vin) else { return }
        if var displayState = latest {
            displayState.commandState.receipts = receiptLedger.visibleReceipts
            onEvent?(.state(displayState))
        }
        publishDiagnostics()
    }

    func dismissCommandReceipt(issuedAt: Date) {
        guard let record = receiptLedger.records.first(where: { $0.receipt.issuedAt == issuedAt }) else { return }
        dismissCommandReceipt(id: record.receipt.id)
    }

    /// The confirmation window must actually end. A held-open exterior stream only
    /// re-evaluates its purpose on the next frame or reconnect — on a quiet car that could
    /// leave a battery/exterior connection running for the whole idle timeout after its
    /// reason expired. The watchdog closes it the moment the window lapses.
    private func scheduleConfirmationWatchdog(vin: String) {
        commandWatchdogTask?.cancel()
        guard let until = receiptLedger.nextDeadline else { return }
        let requestGeneration = generation
        let delay = max(0.05, until.timeIntervalSince(now()))
        commandWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard let self, !Task.isCancelled, requestGeneration == self.generation else { return }
            self.enforceCommandWindowExpiry(vin: vin)
        }
    }

    private func enforceCommandWindowExpiry(vin: String) {
        commandWatchdogTask = nil
        guard receiptLedger.nextDeadline.map({ $0 <= now() }) == true else { return }
        if receiptLedger.timeOutExpired() {
            receiptLedger.clearSuspension()
            receiptLedger.persist(vin: latest?.identity.vin)
            publishCommandReceipts()
        }
        guard latest?.identity.vin == vin else { return }
        refreshCommandConfirmationInfrastructure(vin: vin)
        scheduleFallbackPoll(for: latest)
        publishDiagnostics()
    }

    func reloadVehicleMetadata() {
        if !preferences.features.contains(.realTimeUpdates) {
            streamEngine?.stop()
        }
        guard rateLimitedUntil.map({ $0 <= now() }) ?? true else { return }
        guard sessionReady, task == nil, !preferences.vin.isEmpty else {
            refreshNow()
            return
        }
        let vin = preferences.vin
        let requestGeneration = generation
        onEvent?(.loading)
        task = Task {
            do {
                try await api.reloadVehicleMetadata(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                refresh(trigger: .manual)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                handle(ServiceErrorPolicy.decision(error, provider: api.brand).error, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    func refreshIfStale() {
        guard let latest else { refreshNow(); return }
        let interval = RefreshPolicy.interval(
            isCharging: latest.isCharging,
            isClimateActive: latest.isClimateActive,
            isVehicleAvailable: {
                switch latest.identity.availability {
                case .available: return true
                case .unavailable: return false
                case .unknown: return nil
                }
            }()
        )
        if now().timeIntervalSince(latest.freshness.fetchedAt) >= interval { refreshNow() }
    }

    /// Switches the active vehicle. Idempotence is decided HERE and nowhere else.
    ///
    /// A switch is skipped only when it is a genuine no-op: the car is already selected,
    /// its state is live, and no earlier attempt is unresolved. Everything else runs —
    /// including a repeat click for a car whose previous switch failed, which is the only
    /// way the user can recover. The old pair of independent guards (the UI compared its
    /// stale `activeVin` copy while this method compared `preferences.vin`) disagreed after
    /// any same-brand switch: clicking the previously-active car was vetoed by the UI guard,
    /// re-clicking the new car was vetoed here, and the switcher locked up entirely until
    /// relaunch — invisible with one car, fatal with two on the same account.
    func selectCar(vin: String) {
        guard rateLimitedUntil.map({ $0 <= now() }) ?? true else {
            // A silent drop reads as a frozen app; surface why switching is paused instead.
            // Multi-vehicle accounts double the request volume and hit this window far
            // more often than the single-car case.
            onEvent?(.switchPaused(.rateLimited(
                retryAfter: rateLimitedUntil.map { $0.timeIntervalSince(now()) }
            )))
            return
        }
        // Already switching to exactly this car: let that attempt finish rather than
        // restarting it (a double-click must not cancel its own in-flight work).
        if vin == requestedSelectionVIN, task != nil { return }
        // Every user-initiated attempt starts with a full automatic-retry budget; only the
        // automatic retries themselves consume it. Tying the reset to "VIN changed" instead
        // meant a re-click of a car whose earlier switch had failed inherited an exhausted
        // budget and surfaced transient failures as terminal immediately.
        selectionRetryCount = 0
        // Fully settled on this car: nothing to do.
        if vin == preferences.vin, requestedSelectionVIN == nil, latest?.identity.vin == vin { return }
        beginSelection(vin: vin)
    }

    private func beginSelection(vin: String) {
        receiptLedger.persist(vin: latest?.identity.vin)
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        receiptLedger.clear()
        streamEngine?.stop()
        scheduler.cancel()
        preferences.vin = vin
        requestedSelectionVIN = vin
        if receiptLedger.restore(forVIN: vin) {
            scheduleConfirmationWatchdog(vin: vin)
        }
        latestAuthoritative = stateStore.snapshot(for: vin)
        latestAuthoritative?.commandState.optimisticLockUntil = nil
        latest = latestAuthoritative
        latest?.commandState.receipts = receiptLedger.visibleReceipts
        if let latest { onEvent?(.state(latest)) } else { onEvent?(.loading) }
        onEvent?(.selectionChanged(vin))
        publishDiagnostics()
        runSelection(vin: vin)
    }

    private func runSelection(vin: String) {
        // Single-flight invariant: a selection retry firing inside its 2 s window can race a
        // manual/wake/network-restored refresh that legitimately holds `task`. Reschedule
        // instead of clobbering the slot — overwriting it ran two fetches concurrently and
        // let `isBusy` report idle while work was still in flight (network operations are
        // timeout-bounded, so the retry cannot spin forever).
        guard task == nil else {
            scheduleSelectionRetry(vin: vin, after: selectionRetryDelay)
            return
        }
        let requestGeneration = generation
        let started = now()
        refreshAttempts += 1
        task = Task {
            do {
                let state = try await api.fetchVehicleState(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                let providerCars = await api.cars
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                requestedSelectionVIN = nil
                selectionRetryCount = 0
                cars = providerCars
                onEvent?(.selectionChanged(vin))
                // Selection does not establish a session or schedule a garage scan.
                apply(state, latency: max(0, now().timeIntervalSince(started)))
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = ServiceErrorPolicy.decision(error, provider: api.brand).error
                // Discovery may briefly omit a requested VIN. Bound retries before treating
                // that preparation failure as terminal.
                if case .notConfigured = mapped, selectionRetryCount < 2 {
                    selectionRetryCount += 1
                    scheduleSelectionRetry(vin: vin, after: selectionRetryDelay)
                    return
                }
                handle(mapped, retrySession: false)
            }
        }
    }

    private func scheduleSelectionRetry(vin: String, after seconds: TimeInterval) {
        let requestGeneration = generation
        Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard requestGeneration == self.generation else { return }
            self.publishDiagnostics()
            self.runSelection(vin: vin)
        }
    }

    func stop() {
        cancelCurrentWork()
        monitor.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.forEach(workspaceCenter.removeObserver)
        observerTokens.removeAll()
    }

    /// Signs out. Deliberate order: local state is cleared *first*, before the remote revoke
    /// round-trip, because privacy-on-failure beats session-persistence-on-failure. The
    /// cached snapshot (which holds location and owner name) is always dropped; durable
    /// history is kept unless the user has opted into "erase history on sign out" in
    /// Settings → Privacy & Data, so a re-signed local build or a stray sign-out does not
    /// discard months of charging and trip data. The only signal when revocation fails is
    /// `.secureStorage` in `lastError`.
    func signOut() {
        cancelCurrentWork()
        let requestGeneration = generation
        sessionReady = false
        latest = nil
        let carsToClear = cars.map(\.vin)
        cars = []
        lastError = nil
        accountEmail = ""
        sessionIntent = .resume
        requestedSelectionVIN = nil
        selectionRetryCount = 0
        rateLimitedUntil = nil
        if api.brand == .polestar {
            preferences.email = ""
        }
        let currentVin = preferences.vin
        preferences.setVin("", for: api.brand)
        let eraseHistory = preferences.eraseHistoryOnSignOut
        if carsToClear.isEmpty {
            if !currentVin.isEmpty {
                stateStore.clear(vin: currentVin, eraseHistory: eraseHistory)
            } else {
                stateStore.clear(eraseHistory: eraseHistory)
            }
        } else {
            for vin in carsToClear {
                stateStore.clear(vin: vin, eraseHistory: eraseHistory)
            }
        }
        onEvent?(.vehiclesCleared)
        publishDiagnostics()
        task = Task {
            do {
                try await api.signOut()
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                logger.error("Remote session revocation failed: \(String(describing: error), privacy: .public)")
                self.lastError = .secureStorage
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            task = nil
            if let lastError { self.onEvent?(.failed(lastError)) }
            self.publishDiagnostics()
        }
    }

    private func beginSession(preferredVIN: String?, deferIfBusy: Bool = false) {
        guard !sleeping else { return }
        if task != nil {
            // Direct triggers (launch, wake, network restore, manual refresh) can safely
            // stand down here: the in-flight operation owns subsequent scheduling and will
            // rearm itself. A one-shot retry TIMER cannot — if it bailed silently nothing
            // would ever reschedule, parking the app on a stale cache until a manual poke.
            // Re-arm briefly instead; each tick is cheap and stops as soon as the queue
            // clears (network operations are timeout-bounded).
            guard deferIfBusy else { return }
            schedule(after: 5, retrySession: true)
            return
        }
        guard networkAvailable else {
            handle(.network(URLError(.notConnectedToInternet)), retrySession: true)
            return
        }
        onEvent?(.loading)
        let requestGeneration = generation
        let started = now()
        refreshAttempts += 1
        task = Task {
            do {
                try await sessionManager.restore(api: api, preferences: preferences,
                                                 preferredVIN: preferredVIN, intent: sessionIntent)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                guard let vin = await api.resolvedVIN(preferred: preferredVIN) else {
                    throw VehicleServiceError.notConfigured
                }
                preferences.vin = vin
                if preferredVIN != vin {
                    if let preferredVIN {
                        stateStore.clearCommandReceipts(for: preferredVIN)
                    }
                    commandWatchdogTask?.cancel()
                    commandWatchdogTask = nil
                    receiptLedger.clear()
                }
                if receiptLedger.isEmpty {
                    if receiptLedger.restore(forVIN: vin) {
                        scheduleConfirmationWatchdog(vin: vin)
                    }
                }
                // The session just re-resolved the selection; any in-flight switch attempt
                // is superseded and its retry budget resets.
                requestedSelectionVIN = nil
                selectionRetryCount = 0
                cars = await api.cars
                onEvent?(.sessionEstablished(cars: cars, selectedVIN: vin))
                sessionReady = true
                sessionIntent = .resume
                let intervalState = Self.signposter.beginInterval("fetchVehicleState")
                do {
                    let state = try await api.fetchVehicleState(vin: vin, features: preferences.features)
                    Self.signposter.endInterval("fetchVehicleState", intervalState)
                    guard requestGeneration == generation, !Task.isCancelled else { return }
                    task = nil
                    apply(state, latency: max(0, now().timeIntervalSince(started)))
                } catch {
                    Self.signposter.endInterval("fetchVehicleState", intervalState)
                    throw error
                }
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = ServiceErrorPolicy.decision(error, provider: api.brand).error
                if mapped.requiresAuthentication { sessionReady = false }
                handle(mapped, retrySession: !sessionReady)
            }
        }
        publishDiagnostics()
    }

    private func refresh(trigger: Trigger) {
        guard task == nil, !sleeping, networkAvailable, sessionReady else { return }
        let vin = preferences.vin
        guard !vin.isEmpty else {
            handle(.notConfigured, retrySession: false)
            return
        }
        if trigger == .manual { onEvent?(.loading) }
        scheduler.cancel()
        nextRefresh = nil
        let confirmationFeatures = confirmationFeatures(for: trigger)
        let features = confirmationFeatures ?? preferences.features
        let requestGeneration = generation
        let started = now()
        refreshAttempts += 1
        task = Task {
            // Signpost spans the network round trip so Instruments shows per-refresh
            // latency without any log volume.
            let intervalState = Self.signposter.beginInterval("fetchVehicleState")
            do {
                let state = try await api.fetchVehicleState(vin: vin, features: features)
                Self.signposter.endInterval("fetchVehicleState", intervalState)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(
                    state,
                    latency: max(0, now().timeIntervalSince(started)),
                    refreshedFeatures: confirmationFeatures?.enabled
                )
            } catch {
                Self.signposter.endInterval("fetchVehicleState", intervalState)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = ServiceErrorPolicy.decision(error, provider: api.brand).error
                if mapped.requiresAuthentication { sessionReady = false }
                handle(mapped, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    private func confirmationFeatures(for trigger: Trigger) -> FeatureSelection? {
        guard case .timer = trigger,
              receiptLedger.isConfirmationPending else {
            return nil
        }
        let enabled = Set(receiptLedger.activeRecords.compactMap { $0.receipt.confirmationFeatures }
            .flatMap(\.enabled))
        return enabled.isEmpty ? nil : FeatureSelection(enabled: enabled)
    }

    private func apply(
        _ state: VehicleState,
        latency: TimeInterval,
        refreshedFeatures: Set<AppFeature>? = nil
    ) {
        let previous = latest
        var authoritative = state.mergingLastKnown(
            from: latestAuthoritative,
            features: preferences.features,
            refreshedFeatures: refreshedFeatures,
            imageCache: imageCache
        )
        // Command receipts and optimistic locks are coordinator-owned presentation state,
        // never provider telemetry or durable history.
        authoritative.commandState.receipts = []
        authoritative.commandState.optimisticLockUntil = nil
        // SQLite is the single source of truth for completed charging history. Clear legacy
        // snapshot-carried sessions so the UI cannot alternate between two divergent stores.
        authoritative.energy.sessions = []
        latestAuthoritative = authoritative
        lastFullRefreshAt = authoritative.freshness.fetchedAt
        lastError = nil
        lastLatency = latency
        failureCount = 0
        refreshSuccesses += 1
        rateLimitedUntil = nil
        stateStore.save(authoritative)
        SpotlightIndexer.indexVehicle(authoritative, nickname: preferences.vehicleNickname(for: authoritative.identity.vin))
        let confirmation = reconcileCommandConfirmation(in: authoritative)
        let displayed = commandPresentation(
            authoritative: authoritative,
            previous: previous,
            refreshedFeatures: refreshedFeatures
        )
        latest = displayed
        onEvent?(.state(displayed))
        if confirmation.confirmed {
            refreshCommandConfirmationInfrastructure(vin: authoritative.identity.vin)
        }
        if desiredLiveStreamPurpose(for: displayed) == nil {
            stopLiveStreaming()
        } else {
            startLiveStreamingIfNeeded(vin: authoritative.identity.vin)
        }
        let interval = pollingInterval(for: displayed)
        schedule(after: interval, retrySession: false, addsJitter: !receiptLedger.isConfirmationPending)
        publishDiagnostics()
    }

    private func commandPresentation(
        authoritative: VehicleState,
        previous: VehicleState?,
        refreshedFeatures: Set<AppFeature>? = nil
    ) -> VehicleState {
        var displayed = authoritative
        if receiptLedger.isConfirmationPending,
           var optimistic = previous,
           optimistic.identity.vin == authoritative.identity.vin {
            // The optimistic overlay owns these display fields while its command awaits
            // telemetry; every other field accepts the authoritative read.
            let preserved = Set(receiptLedger.activeRecords.compactMap { $0.receipt.command?.descriptor.displayField })
            if !preserved.contains(.climateStatus) { optimistic.climateStatus = authoritative.climateStatus }
            if !preserved.contains(.airQuality) { optimistic.airQuality = authoritative.airQuality }
            if !preserved.contains(.exterior) {
                optimistic.exteriorStatus = authoritative.exteriorStatus
            }
            if !preserved.contains(.chargeTarget) {
                optimistic.energy.targetPercentage = authoritative.energy.targetPercentage
            }
            if !preserved.contains(.chargingCurrentLimit) {
                optimistic.energy.currentLimitAmps = authoritative.energy.currentLimitAmps
            }
            if !preserved.contains(.chargingState) {
                optimistic.energy.chargingState = authoritative.energy.chargingState
            }
            displayed = authoritative.mergingLastKnown(
                from: optimistic,
                features: preferences.features,
                refreshedFeatures: refreshedFeatures,
                imageCache: imageCache
            )
        }
        displayed.commandState.receipts = receiptLedger.visibleReceipts
        return displayed
    }

    private func handle(_ error: VehicleServiceError, retrySession: Bool) {
        lastError = error
        failureCount += 1
        refreshFailures += 1
        // `String(describing:)` keeps enum payloads and NSError codes that
        // `localizedDescription` flattens away.
        logger.error("Refresh failed (attempt \(self.failureCount, privacy: .public) consecutive): \(String(describing: error), privacy: .public)")
        onEvent?(.failed(error))
        guard error.allowsAutomaticRetry else {
            scheduler.cancel()
            nextRefresh = nil
            publishDiagnostics()
            return
        }
        let retryAfter: TimeInterval?
        if case .rateLimited(let value) = error { retryAfter = value } else { retryAfter = nil }
        let needsSession = retrySession || error.requiresNewSession
        let delay = retryDelay(failureCount, retryAfter, needsSession)
        if case .rateLimited = error {
            rateLimitedUntil = now().addingTimeInterval(delay)
            logger.warning("Rate limited; pausing refreshes until \(self.rateLimitedUntil.map { "\($0)" } ?? "?", privacy: .public)")
        }
        schedule(after: delay, retrySession: needsSession)
        publishDiagnostics()
    }

    private func schedule(after interval: TimeInterval, retrySession: Bool, addsJitter: Bool = true) {
        scheduler.cancel()
        guard !sleeping, networkAvailable else { nextRefresh = nil; return }
        let maxJitter = min(15, max(1, interval * 0.1))
        let jitter = addsJitter ? Double.random(in: 0...maxJitter) : 0
        let requestedDeadline = now().addingTimeInterval(interval + jitter)
        let deadline = max(requestedDeadline, rateLimitedUntil ?? .distantPast)
        let delay = max(0, deadline.timeIntervalSince(now()))
        nextRefresh = deadline
        scheduler.scheduleOnce(after: delay) { [weak self] in
            guard let self else { return }
            if retrySession || !self.sessionReady {
                self.beginSession(preferredVIN: preferences.vin.nilIfEmpty, deferIfBusy: true)
            } else {
                self.streamEngine?.noteFallbackPoll()
                self.refresh(trigger: .timer)
            }
        }
    }

    func networkDidChange(_ available: Bool) {
        let restored = available && !networkAvailable
        networkAvailable = available
        if !available {
            cancelCurrentWork(preservingCommandConfirmation: true)
        } else if restored && !sleeping {
            resumeCommandConfirmationIfNeeded()
            if sessionReady { refresh(trigger: .networkRestored) }
            else { beginSession(preferredVIN: preferences.vin.nilIfEmpty) }
        }
        publishDiagnostics()
    }

    func systemWillSleep() {
        sleeping = true
        cancelCurrentWork(preservingCommandConfirmation: true)
    }

    func systemDidWake() {
        sleeping = false
        guard networkAvailable else {
            publishDiagnostics()
            return
        }
        resumeCommandConfirmationIfNeeded()
        if sessionReady { refresh(trigger: .wake) }
        else { beginSession(preferredVIN: preferences.vin.nilIfEmpty) }
    }

    private func installSystemObservers() {
        observerTokens.append(addMainActorObserver(for: NSWorkspace.willSleepNotification) { coordinator in
            coordinator.systemWillSleep()
        })
        observerTokens.append(addMainActorObserver(for: NSWorkspace.didWakeNotification) { coordinator in
            coordinator.systemDidWake()
        })
    }

    /// `MainActor.assumeIsolated` is a runtime assertion, not a compiler-checked guarantee: it
    /// traps if the notification is ever delivered off the main thread. What makes it sound is
    /// `queue: .main` on the registration — so the two must never drift apart. Binding them
    /// together here means the delivery queue cannot be changed independently of the
    /// assumption that depends on it. The body stays synchronous deliberately: `willSleep`
    /// must cancel in-flight work *before* the machine suspends, which an async hop onto the
    /// main actor could miss.
    private func addMainActorObserver(
        for name: Notification.Name,
        handler: @escaping @MainActor @Sendable (RefreshCoordinator) -> Void
    ) -> any NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }

    private func cancelCurrentWork(preservingCommandConfirmation: Bool = false) {
        let preserveReceipt = preservingCommandConfirmation && !receiptLedger.isEmpty
        if preserveReceipt {
            receiptLedger.suspend()
        }
        generation &+= 1
        task?.cancel()
        task = nil
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        if !preserveReceipt {
            receiptLedger.clear()
        }
        streamEngine?.stop()
        scheduler.cancel()
        nextRefresh = nil
    }

    private func resumeCommandConfirmationIfNeeded() {
        guard receiptLedger.suspensionStartedAt != nil else { return }
        guard receiptLedger.resume() else { return }
        receiptLedger.persist(vin: latest?.identity.vin)
        if let vin = latest?.identity.vin {
            refreshCommandConfirmationInfrastructure(vin: vin)
        }
    }

    private func publishDiagnostics() {
        let diagnosticRecord = receiptLedger.activeRecords.last ?? receiptLedger.records.last
        onEvent?(.diagnostics(DiagnosticsSnapshot(
            lastSuccess: lastFullRefreshAt,
            lastError: lastError?.localizedDescription,
            latency: lastLatency,
            nextRefresh: nextRefresh,
            sessionValid: sessionReady,
            networkAvailable: networkAvailable,
            refreshInProgress: task != nil,
            unavailableFeatures: latest?.freshness.unavailableFeatures ?? [],
            servingCachedSnapshot: latest?.freshness.isCached ?? false,
            liveStreamConnected: streamEngine?.isConnected ?? false,
            liveStreamRetryAt: streamEngine?.retryAt,
            lastLiveFrameAt: streamEngine?.metrics.lastFrameAt,
            liveStreamMetrics: streamEngine?.metrics ?? LiveStreamMetrics(),
            refreshAttempts: refreshAttempts,
            refreshSuccesses: refreshSuccesses,
            refreshFailures: refreshFailures,
            commandConfirmationIdentifier: diagnosticRecord?.receipt.commandIdentifier,
            commandConfirmationStatus: diagnosticRecord?.receipt.status,
            commandConfirmationDeadline: diagnosticRecord?.confirmationDeadline,
            commandConfirmationFeatures: diagnosticRecord?.receipt.confirmationFeatures?.enabled
                .sorted { $0.rawValue < $1.rawValue } ?? [],
            commandConfirmationSuspended: receiptLedger.suspensionStartedAt != nil,
            commandReceiptVisible: !receiptLedger.visibleReceipts.isEmpty,
            commandReceiptCount: receiptLedger.visibleReceipts.count,
            awaitingCommandReceiptCount: receiptLedger.activeRecords.count,
            vehicleSwitchPending: requestedSelectionVIN != nil
        )))
    }

    private func startLiveStreamingIfNeeded(vin: String) {
        guard preferences.features.contains(.realTimeUpdates),
              streamEngine?.isRunning != true,
              let streaming = api as? any VehicleLiveStreaming,
              let state = latest,
              let purpose = desiredLiveStreamPurpose(for: state) else { return }
        let requestGeneration = generation
        // Persists at most every 10 s across the frames of this stream run.
        var lastPersistAt = Date.distantPast
        let engine = LiveStreamEngine(
            streaming: streaming,
            providerBrand: api.brand,
            policy: liveStreamPolicy,
            jitter: liveStreamJitter,
            now: now,
            context: .init(
                isDesired: { [weak self] desiredPurpose, desiredVIN in
                    guard let self, requestGeneration == self.generation,
                          self.latest?.identity.vin == desiredVIN,
                          self.desiredLiveStreamPurpose(for: self.latest) == desiredPurpose else { return false }
                    return true
                },
                onConnected: { [weak self] in
                    guard let self else { return }
                    if receiptLedger.isConfirmationPending {
                        scheduleCommandConfirmationPoll()
                    } else {
                        schedule(after: liveStreamPolicy.integrityPollInterval, retrySession: false)
                    }
                    publishDiagnostics()
                },
                onFrame: { [weak self] update in
                    guard let self, requestGeneration == self.generation,
                          var current = self.latestAuthoritative,
                          current.identity.vin == vin else { return false }
                    current.applyLiveUpdate(update)
                    current.commandState.receipts = []
                    current.commandState.optimisticLockUntil = nil
                    latestAuthoritative = current
                    let frameTime = now()
                    if frameTime.timeIntervalSince(lastPersistAt) >= 10 {
                        lastPersistAt = frameTime
                        stateStore.save(current)
                    }
                    let previous = latest
                    let confirmation = reconcileCommandConfirmation(in: current)
                    let displayed = commandPresentation(
                        authoritative: current,
                        previous: previous
                    )
                    latest = displayed
                    onEvent?(.state(displayed))
                    if confirmation.confirmed {
                        refreshCommandConfirmationInfrastructure(vin: vin)
                    }
                    return true
                },
                onDisconnected: { [weak self] in
                    guard let self else { return }
                    scheduleFallbackPoll(for: latest)
                    publishDiagnostics()
                },
                onIdle: { [weak self] in
                    guard let self else { return }
                    scheduleFallbackPoll(for: latest)
                    publishDiagnostics()
                    if let vin = latest?.identity.vin {
                        startLiveStreamingIfNeeded(vin: vin)
                    }
                }
            )
        )
        streamEngine = engine
        engine.setPurpose(purpose, vin: vin)
    }


    private func desiredLiveStreamPurpose(for state: VehicleState?) -> VehicleLiveStreamPurpose? {
        guard let state else { return nil }
        if let commandPurpose = receiptLedger.activeRecords.reversed().compactMap({
            confirmationStreamPurpose(for: $0.receipt)
        }).first {
            return commandPurpose
        }
        return liveStreamPolicy.shouldStream(state) ? .charging : nil
    }

    private func scheduleFallbackPoll(for state: VehicleState?) {
        guard let state else { return }
        if receiptLedger.isConfirmationPending {
            scheduleCommandConfirmationPoll()
            return
        }
        schedule(after: pollingInterval(for: state), retrySession: false)
    }

    private func scheduleCommandConfirmationPoll() {
        if scheduler.isArmed, nextRefresh != nil { return }
        schedule(after: commandConfirmationPollInterval, retrySession: false, addsJitter: false)
    }

    private func pollingInterval(for state: VehicleState) -> TimeInterval {
        if receiptLedger.isConfirmationPending {
            return commandConfirmationPollInterval
        }
        if streamEngine?.isConnected == true { return liveStreamPolicy.integrityPollInterval }
        return RefreshPolicy.interval(
            isCharging: state.isCharging,
            isClimateActive: state.isClimateActive,
            isVehicleAvailable: {
                if case .unavailable = state.identity.availability { return false }
                if case .available = state.identity.availability { return true }
                return nil
            }()
        )
    }

    private func reconcileCommandConfirmation(
        in state: VehicleState
    ) -> (state: VehicleState, confirmed: Bool) {
        guard !receiptLedger.isEmpty else { return (state, false) }
        let confirmedReceipts = receiptLedger.reconcile(against: state, vin: latest?.identity.vin)
        var displayState = state
        displayState.commandState.receipts = receiptLedger.visibleReceipts
        return (displayState, !confirmedReceipts.isEmpty)
    }

    private func refreshCommandConfirmationInfrastructure(vin: String) {
        guard latest?.identity.vin == vin else { return }
        if receiptLedger.timeOutExpired() {
            receiptLedger.persist(vin: latest?.identity.vin)
            publishCommandReceipts()
        }
        let desiredPurpose = desiredLiveStreamPurpose(for: latest)
        if streamEngine?.purpose != desiredPurpose {
            stopLiveStreaming()
            if desiredPurpose != nil { startLiveStreamingIfNeeded(vin: vin) }
        }
        scheduleConfirmationWatchdog(vin: vin)
    }

    private func publishCommandReceipts() {
        guard var displayState = latest else { return }
        displayState.commandState.receipts = receiptLedger.visibleReceipts
        onEvent?(.state(displayState))
    }

    private func confirmationStreamPurpose(for receipt: CommandReceipt) -> VehicleLiveStreamPurpose? {
        guard preferences.features.contains(.realTimeUpdates) else { return nil }
        switch receipt.command {
        case .startChargingOverride:
            return .charging
        case .lock, .unlock,
             .openTailgate, .closeTailgate, .openWindows, .closeWindows:
            return .exteriorConfirmation
        default:
            return nil
        }
    }

    private func stopLiveStreaming() {
        streamEngine?.stop()
    }
}
