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
    private let logger = AppLog.logger("refresh")
    /// Interval instrumentation for Instruments' os_signpost tool — free refresh-latency
    /// timelines without touching the unified log.
    private static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "refresh")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var streamTaskID: UUID?
    private var commandWatchdogTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureCount = 0
    private var rateLimitedUntil: Date?
    private var lastManualRefresh: Date?
    private var sleeping = false
    private var networkAvailable = true
    private var liveStreamConnected = false
    private var liveStreamRetryAt: Date?
    private var liveStreamMetrics = LiveStreamMetrics()
    private var liveStreamPurpose: VehicleLiveStreamPurpose?
    private var commandStreamPurpose: VehicleLiveStreamPurpose?
    private var commandStreamUntil: Date?
    private var pendingCommandConfirmation: PendingCommandSummary?
    private var commandConfirmationSuspendedAt: Date?
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
    var isRateLimited: Bool { rateLimitedUntil.map({ $0 > Date() }) ?? false }

    init(api: any VehicleProviding, stateStore: VehicleStateStore,
         observesEnvironment: Bool = true,
         imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore,
         sessionManager: SessionManager = SessionManager(),
         retryDelay: @escaping (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval = RefreshPolicy.retryDelay,
         selectionRetryDelay: TimeInterval = 2,
         liveStreamPolicy: LiveStreamPolicy = LiveStreamPolicy(),
         liveStreamJitter: @escaping () -> Double = { Double.random(in: 0...1) },
         commandConfirmationWindow: TimeInterval = PendingCommandSummary.maximumConfirmationDuration,
         commandConfirmationInitialPollDelay: TimeInterval = 2,
         commandConfirmationPollInterval: TimeInterval = 5) {
        self.api = api
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.preferences = preferences
        self.sessionManager = sessionManager
        self.retryDelay = retryDelay
        self.selectionRetryDelay = selectionRetryDelay
        self.liveStreamPolicy = liveStreamPolicy
        self.liveStreamJitter = liveStreamJitter
        self.commandConfirmationWindow = commandConfirmationWindow
        self.commandConfirmationInitialPollDelay = commandConfirmationInitialPollDelay
        self.commandConfirmationPollInterval = commandConfirmationPollInterval
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
        if let preferredVIN, let cached = stateStore.snapshot(for: preferredVIN) {
            latest = cached
            onEvent?(.state(cached))
        }
        beginSession(preferredVIN: preferredVIN)
    }

    func credentialsChanged(preferredVIN: String?) {
        let oldAccount = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newAccount = preferences.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountChanged = !oldAccount.isEmpty && oldAccount != newAccount
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
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            nextRefresh = rateLimitedUntil
            publishDiagnostics()
            return
        }
        // Debounce: skip manual refresh if one started less than 2 seconds ago — rapid
        // clicks on the refresh button (or ⌘R spam) would otherwise stack requests.
        if let lastManualRefresh, Date().timeIntervalSince(lastManualRefresh) < 2, task != nil {
            return
        }
        lastManualRefresh = Date()
        guard sessionReady else {
            beginSession(preferredVIN: preferences.vin.nilIfEmpty)
            return
        }
        refresh(trigger: .manual)
    }

    func beginCommandConfirmation(_ pending: PendingCommandSummary) {
        if pendingCommandConfirmation != nil, let vin = latest?.identity.vin {
            finishCommandConfirmation(vin: vin)
        }
        pendingCommandConfirmation = pending
        commandConfirmationSuspendedAt = nil
        commandStreamUntil = Date().addingTimeInterval(commandConfirmationWindow)
        guard pending.supportsTelemetryConfirmation else {
            commandStreamPurpose = nil
            if let vin = latest?.identity.vin {
                scheduleConfirmationWatchdog(vin: vin)
            }
            schedule(after: commandConfirmationInitialPollDelay, retrySession: false)
            publishDiagnostics()
            return
        }
        let purpose: VehicleLiveStreamPurpose?
        switch pending.command {
        case .startChargingOverride:
            purpose = .charging
        case .setChargeTarget, .setAmpLimit:
            purpose = nil
        case .lock, .unlock,
             .openTailgate, .closeTailgate, .openWindows, .closeWindows:
            purpose = .exteriorConfirmation
        default:
            purpose = nil
        }
        if let purpose, preferences.features.contains(.realTimeUpdates),
           let vin = latest?.identity.vin {
            commandStreamPurpose = purpose
            if liveStreamPurpose != purpose {
                stopLiveStreaming()
            }
            startLiveStreamingIfNeeded(vin: vin)
            scheduleConfirmationWatchdog(vin: vin)
        } else if let vin = latest?.identity.vin {
            commandStreamPurpose = nil
            scheduleConfirmationWatchdog(vin: vin)
        }
        schedule(after: min(commandConfirmationInitialPollDelay, commandConfirmationPollInterval),
                 retrySession: false)
        publishDiagnostics()
    }

    /// The confirmation window must actually end. A held-open exterior stream only
    /// re-evaluates its purpose on the next frame or reconnect — on a quiet car that could
    /// leave a battery/exterior connection running for the whole idle timeout after its
    /// reason expired. The watchdog closes it the moment the window lapses.
    private func scheduleConfirmationWatchdog(vin: String) {
        commandWatchdogTask?.cancel()
        guard let until = commandStreamUntil else { return }
        let requestGeneration = generation
        commandWatchdogTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.05, until.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled, requestGeneration == self.generation else { return }
            self.enforceCommandWindowExpiry(vin: vin)
        }
    }

    private func enforceCommandWindowExpiry(vin: String) {
        commandWatchdogTask = nil
        guard let until = commandStreamUntil, until <= Date() else { return }
        let expiredPurpose = commandStreamPurpose
        if var timedOut = pendingCommandConfirmation, timedOut.status.isAwaiting {
            timedOut.status = .timedOut(at: until)
            if var displayState = latest {
                displayState.commandState.pending = timedOut
                onEvent?(.state(displayState))
            }
        }
        commandStreamUntil = nil
        commandStreamPurpose = nil
        pendingCommandConfirmation = nil
        commandConfirmationSuspendedAt = nil
        guard latest?.identity.vin == vin else { return }
        guard let expiredPurpose, liveStreamPurpose == expiredPurpose else {
            scheduleFallbackPoll(for: latest)
            publishDiagnostics()
            return
        }
        stopLiveStreaming()
        if desiredLiveStreamPurpose(for: latest) != nil {
            startLiveStreamingIfNeeded(vin: vin)
        } else {
            scheduleFallbackPoll(for: latest)
        }
        publishDiagnostics()
    }

    func reloadVehicleMetadata() {
        if !preferences.features.contains(.realTimeUpdates) {
            streamTask?.cancel()
            streamTask = nil
            liveStreamConnected = false
            liveStreamRetryAt = nil
        }
        guard rateLimitedUntil.map({ $0 <= Date() }) ?? true else { return }
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
        if Date().timeIntervalSince(latest.freshness.fetchedAt) >= interval { refreshNow() }
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
        guard rateLimitedUntil.map({ $0 <= Date() }) ?? true else {
            // A silent drop reads as a frozen app; surface why switching is paused instead.
            // Multi-vehicle accounts double the request volume and hit this window far
            // more often than the single-car case.
            onEvent?(.switchPaused(.rateLimited(
                retryAfter: rateLimitedUntil?.timeIntervalSinceNow
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
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        commandStreamPurpose = nil
        commandStreamUntil = nil
        pendingCommandConfirmation = nil
        commandConfirmationSuspendedAt = nil
        streamTask?.cancel()
        streamTask = nil
        streamTaskID = nil
        liveStreamConnected = false
        timer?.invalidate()
        preferences.vin = vin
        requestedSelectionVIN = vin
        latest = stateStore.snapshot(for: vin)
        if let latest { onEvent?(.state(latest)) } else { onEvent?(.loading) }
        onEvent?(.selectionChanged(vin))
        publishDiagnostics()
        runSelection(vin: vin)
    }

    private func runSelection(vin: String) {
        let requestGeneration = generation
        let started = Date()
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
                apply(state, latency: Date().timeIntervalSince(started))
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
        let started = Date()
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
                    apply(state, latency: Date().timeIntervalSince(started))
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
        timer?.invalidate()
        nextRefresh = nil
        let confirmationFeatures = confirmationFeatures(for: trigger)
        let features = confirmationFeatures ?? preferences.features
        let requestGeneration = generation
        let started = Date()
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
                    latency: Date().timeIntervalSince(started),
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
              let confirmationFeatures = pendingCommandConfirmation?.confirmationFeatures else {
            return nil
        }
        return confirmationFeatures
    }

    private func apply(
        _ state: VehicleState,
        latency: TimeInterval,
        refreshedFeatures: Set<AppFeature>? = nil
    ) {
        let previous = latest
        var state = state.mergingLastKnown(
            from: previous,
            features: preferences.features,
            refreshedFeatures: refreshedFeatures,
            imageCache: imageCache
        )
        // Command receipts are reconciled separately by the session controller against
        // timestamped readings, rather than being persisted as vehicle telemetry.
        state.commandState.pending = nil
        // SQLite is the single source of truth for completed charging history. Clear legacy
        // snapshot-carried sessions so the UI cannot alternate between two divergent stores.
        state.energy.sessions = []
        latest = state
        lastFullRefreshAt = state.freshness.fetchedAt
        lastError = nil
        lastLatency = latency
        failureCount = 0
        refreshSuccesses += 1
        rateLimitedUntil = nil
        stateStore.save(state)
        SpotlightIndexer.indexVehicle(state, nickname: preferences.vehicleNickname(for: state.identity.vin))
        let confirmation = reconcileCommandConfirmation(in: state)
        onEvent?(.state(confirmation.state))
        if confirmation.confirmed {
            finishCommandConfirmation(vin: state.identity.vin)
        }
        if desiredLiveStreamPurpose(for: state) == nil {
            stopLiveStreaming()
        } else {
            startLiveStreamingIfNeeded(vin: state.identity.vin)
        }
        let pollingInterval = pollingInterval(for: state)
        schedule(after: pollingInterval, retrySession: false)
        publishDiagnostics()
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
            timer?.invalidate()
            nextRefresh = nil
            publishDiagnostics()
            return
        }
        let retryAfter: TimeInterval?
        if case .rateLimited(let value) = error { retryAfter = value } else { retryAfter = nil }
        let needsSession = retrySession || error.requiresNewSession
        let delay = retryDelay(failureCount, retryAfter, needsSession)
        if case .rateLimited = error {
            rateLimitedUntil = Date().addingTimeInterval(delay)
            logger.warning("Rate limited; pausing refreshes until \(self.rateLimitedUntil.map { "\($0)" } ?? "?", privacy: .public)")
        }
        schedule(after: delay, retrySession: needsSession)
        publishDiagnostics()
    }

    private func schedule(after interval: TimeInterval, retrySession: Bool) {
        timer?.invalidate()
        guard !sleeping, networkAvailable else { nextRefresh = nil; return }
        let maxJitter = min(15, max(1, interval * 0.1))
        let jitter = Double.random(in: 0...maxJitter)
        let requestedDeadline = Date().addingTimeInterval(interval + jitter)
        let deadline = max(requestedDeadline, rateLimitedUntil ?? .distantPast)
        let delay = max(0, deadline.timeIntervalSinceNow)
        nextRefresh = deadline
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if retrySession || !self.sessionReady {
                    self.beginSession(preferredVIN: preferences.vin.nilIfEmpty, deferIfBusy: true)
                } else {
                    if self.streamTask != nil && !self.liveStreamConnected {
                        self.liveStreamMetrics.fallbackPolls += 1
                    }
                    self.refresh(trigger: .timer)
                }
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
        let preserveConfirmation = preservingCommandConfirmation
            && pendingCommandConfirmation != nil
        if preserveConfirmation, commandConfirmationSuspendedAt == nil {
            commandConfirmationSuspendedAt = Date()
        }
        generation &+= 1
        task?.cancel()
        task = nil
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        if !preserveConfirmation {
            commandStreamPurpose = nil
            commandStreamUntil = nil
            pendingCommandConfirmation = nil
            commandConfirmationSuspendedAt = nil
        }
        streamTask?.cancel()
        streamTask = nil
        streamTaskID = nil
        liveStreamPurpose = nil
        liveStreamConnected = false
        liveStreamRetryAt = nil
        liveStreamMetrics.activeTransportStreams = 0
        liveStreamMetrics.connectedAt = nil
        timer?.invalidate()
        timer = nil
        nextRefresh = nil
    }

    private func resumeCommandConfirmationIfNeeded() {
        guard let suspendedAt = commandConfirmationSuspendedAt else { return }
        commandConfirmationSuspendedAt = nil
        guard pendingCommandConfirmation != nil, let until = commandStreamUntil else { return }
        commandStreamUntil = until.addingTimeInterval(max(0, Date().timeIntervalSince(suspendedAt)))
        if let vin = latest?.identity.vin {
            scheduleConfirmationWatchdog(vin: vin)
        }
    }

    private func publishDiagnostics() {
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
            liveStreamConnected: liveStreamConnected,
            liveStreamRetryAt: liveStreamRetryAt,
            lastLiveFrameAt: liveStreamMetrics.lastFrameAt,
            liveStreamMetrics: liveStreamMetrics,
            refreshAttempts: refreshAttempts,
            refreshSuccesses: refreshSuccesses,
            refreshFailures: refreshFailures,
            vehicleSwitchPending: requestedSelectionVIN != nil
        )))
    }

    private func startLiveStreamingIfNeeded(vin: String) {
        guard preferences.features.contains(.realTimeUpdates), streamTask == nil,
              let streaming = api as? any VehicleLiveStreaming,
              let state = latest,
              let purpose = desiredLiveStreamPurpose(for: state) else { return }
        let requestGeneration = generation
        liveStreamPurpose = purpose
        let taskID = UUID()
        streamTaskID = taskID
        streamTask = Task { [weak self] in
            defer {
                if let self, self.streamTaskID == taskID {
                    self.streamTask = nil
                    self.streamTaskID = nil
                    self.liveStreamPurpose = nil
                    self.liveStreamConnected = false
                    self.liveStreamRetryAt = nil
                    self.liveStreamMetrics.activeTransportStreams = 0
                    self.liveStreamMetrics.connectedAt = nil
                    self.scheduleFallbackPoll(for: self.latest)
                    self.publishDiagnostics()
                    if let vin = self.latest?.identity.vin {
                        self.startLiveStreamingIfNeeded(vin: vin)
                    }
                }
            }
            var failure = 0
            var authorizationRecoveryUsed = false
            // Streamed frames can arrive several times a minute; persisting every frame used
            // to write the full snapshot blob (plus telemetry rows) per message. UI updates
            // stay immediate; disk writes coalesce.
            var lastPersistAt = Date.distantPast
            while !Task.isCancelled {
                guard let self, requestGeneration == self.generation,
                      self.latest?.identity.vin == vin,
                      self.desiredLiveStreamPurpose(for: self.latest) == purpose else { return }
                let streamStartedAt = Date()
                var connectedAt: Date?
                do {
                    self.liveStreamMetrics.connectionAttempts += 1
                    let stream = try await streaming.liveVehicleUpdates(vin: vin, purpose: purpose)
                    for try await update in stream {
                        try Task.checkCancellation()
                        guard requestGeneration == self.generation,
                              var current = self.latest, current.identity.vin == vin else { return }
                        if case .connected(let activeTransportStreams) = update {
                            let now = Date()
                            connectedAt = now
                            self.liveStreamConnected = true
                            self.liveStreamRetryAt = nil
                            self.liveStreamMetrics.successfulConnections += 1
                            self.liveStreamMetrics.activeTransportStreams = activeTransportStreams
                            self.liveStreamMetrics.connectedAt = now
                            self.liveStreamMetrics.circuitOpenUntil = nil
                            if self.isCommandConfirmationPending {
                                self.scheduleCommandConfirmationPoll()
                            } else {
                                self.schedule(after: self.liveStreamPolicy.integrityPollInterval,
                                              retrySession: false)
                            }
                            self.publishDiagnostics()
                            continue
                        }
                        current.applyLiveUpdate(update)
                        self.latest = current
                        let now = Date()
                        self.liveStreamMetrics.messagesReceived += 1
                        self.liveStreamMetrics.lastFrameAt = now
                        self.liveStreamMetrics.lastDisconnectedAt = nil
                        if now.timeIntervalSince(lastPersistAt) >= 10 {
                            lastPersistAt = now
                            self.stateStore.save(current)
                        }
                        let confirmation = self.reconcileCommandConfirmation(in: current)
                        self.onEvent?(.state(confirmation.state))
                        if confirmation.confirmed {
                            self.finishCommandConfirmation(vin: vin)
                            return
                        }
                    }
                    throw VehicleServiceError.temporarilyUnavailable(
                        provider: self.api.brand, service: "live vehicle stream"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    let now = Date()
                    self.liveStreamConnected = false
                    self.liveStreamMetrics.activeTransportStreams = 0
                    self.liveStreamMetrics.connectedAt = nil
                    self.liveStreamMetrics.disconnects += 1
                    self.liveStreamMetrics.lastDisconnectedAt = now
                    let duration = now.timeIntervalSince(connectedAt ?? streamStartedAt)
                    self.liveStreamMetrics.lastConnectionDuration = max(0, duration)
                    let mapped = ServiceErrorPolicy.decision(error, provider: self.api.brand).error
                    self.liveStreamMetrics.lastDisconnectReason =
                        DiagnosticRedaction.redact(String(describing: mapped))
                    if duration >= self.liveStreamPolicy.stabilityInterval {
                        failure = 0
                        authorizationRecoveryUsed = false
                    }
                    failure += 1
                    let action = self.liveStreamPolicy.action(
                        for: mapped, consecutiveFailures: failure,
                        authorizationRecoveryUsed: authorizationRecoveryUsed,
                        now: now, jitterUnit: self.liveStreamJitter()
                    )
                    let delay: TimeInterval
                    switch action {
                    case .retry(let retryDelay):
                        delay = retryDelay
                    case .refreshAuthorization(let retryDelay):
                        authorizationRecoveryUsed = true
                        do {
                            try await streaming.refreshLiveStreamAuthorization()
                            self.liveStreamMetrics.authorizationRefreshes += 1
                        } catch {
                            self.logger.warning("Live stream token recovery failed: \(String(describing: error), privacy: .public)")
                        }
                        delay = retryDelay
                    case .openCircuit(let until):
                        self.liveStreamMetrics.circuitOpenUntil = until
                        delay = max(0, until.timeIntervalSince(now))
                    }
                    self.liveStreamRetryAt = now.addingTimeInterval(delay)
                    self.scheduleFallbackPoll(for: self.latest)
                    self.logger.warning("Live stream dropped; retrying in \(Int(delay), privacy: .public)s: \(String(describing: mapped), privacy: .public)")
                    self.publishDiagnostics()
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                    if case .openCircuit = action {
                        failure = 0
                        authorizationRecoveryUsed = false
                        self.liveStreamMetrics.circuitOpenUntil = nil
                    }
                }
            }
        }
    }

    private func desiredLiveStreamPurpose(for state: VehicleState?) -> VehicleLiveStreamPurpose? {
        guard let state else { return nil }
        if let until = commandStreamUntil {
            if until > Date() {
                if let commandStreamPurpose {
                    return commandStreamPurpose
                }
            } else {
                commandStreamUntil = nil
                commandStreamPurpose = nil
                pendingCommandConfirmation = nil
                commandConfirmationSuspendedAt = nil
            }
        }
        return liveStreamPolicy.shouldStream(state) ? .charging : nil
    }

    private func scheduleFallbackPoll(for state: VehicleState?) {
        guard let state else { return }
        if isCommandConfirmationPending {
            scheduleCommandConfirmationPoll()
            return
        }
        schedule(after: pollingInterval(for: state), retrySession: false)
    }

    private var isCommandConfirmationPending: Bool {
        pendingCommandConfirmation?.supportsTelemetryConfirmation == true
            && commandStreamUntil.map { $0 > Date() } == true
    }

    private func scheduleCommandConfirmationPoll() {
        if timer?.isValid == true, nextRefresh != nil { return }
        schedule(after: commandConfirmationPollInterval, retrySession: false)
    }

    private func pollingInterval(for state: VehicleState) -> TimeInterval {
        if isCommandConfirmationPending {
            return commandConfirmationPollInterval
        }
        if liveStreamConnected { return liveStreamPolicy.integrityPollInterval }
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
        guard let pending = pendingCommandConfirmation else { return (state, false) }
        let updated = pending.updatingConfirmation(from: state)
        var displayState = state
        displayState.commandState.pending = updated
        pendingCommandConfirmation = updated
        return (displayState, updated.status.isConfirmed)
    }

    private func finishCommandConfirmation(vin: String) {
        let confirmationPurpose = commandStreamPurpose
        pendingCommandConfirmation = nil
        commandStreamPurpose = nil
        commandStreamUntil = nil
        commandConfirmationSuspendedAt = nil
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        guard latest?.identity.vin == vin,
              let confirmationPurpose, liveStreamPurpose == confirmationPurpose else { return }
        let nextPurpose = desiredLiveStreamPurpose(for: latest)
        guard nextPurpose != confirmationPurpose else { return }
        stopLiveStreaming()
        if nextPurpose != nil {
            startLiveStreamingIfNeeded(vin: vin)
        }
    }

    private func stopLiveStreaming() {
        commandWatchdogTask?.cancel()
        commandWatchdogTask = nil
        streamTask?.cancel()
        streamTask = nil
        streamTaskID = nil
        liveStreamPurpose = nil
        liveStreamConnected = false
        liveStreamRetryAt = nil
        liveStreamMetrics.activeTransportStreams = 0
        liveStreamMetrics.connectedAt = nil
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
