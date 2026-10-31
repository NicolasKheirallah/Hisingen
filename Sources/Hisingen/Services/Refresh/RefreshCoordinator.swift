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
    /// The stream is parked because its session needs the user's sign-in, not because it is
    /// waiting out a backoff. Distinguishing the two is what stops a support bundle from
    /// reading a dead session as a slow reconnect.
    var liveStreamNeedsAuthorization: Bool = false
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
    /// `refreshInProgress` is often false – without this flag a support bundle cannot tell
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
    /// Sequence of the snapshot in `latest`. Publishes hop onto this actor in separate tasks,
    /// so a snapshot from an earlier publish can arrive after a newer one.
    private var latestSequence: UInt64 = 0

    func update(_ snapshot: DiagnosticsSnapshot, sequence: UInt64) {
        guard sequence > latestSequence else { return }
        latestSequence = sequence
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
    /// hammering the backend buys nothing; 30 minutes still recovers promptly on wake.
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
    enum Trigger {
        case timer, manual, wake, networkRestored

        /// A scheduled tick is the only trigger that narrows its fetch to the telemetry a
        /// pending command still needs.
        var isScheduledTick: Bool {
            if case .timer = self { return true }
            return false
        }

        var intent: RefreshIntent {
            switch self {
            case .timer: return .scheduled
            case .manual: return .manual
            case .wake: return .wake
            case .networkRestored: return .networkRestored
            }
        }
    }

    let api: any VehicleProviding
    let stateStore: VehicleStateStore
    let imageCache: CarImageCache
    let preferences: PreferencesStore
    let sessionManager: SessionManager
    /// Computes the delay before the next attempt. Injectable so tests can collapse the
    /// production exponential backoff (which legitimately stretches to minutes) to zero.
    let retryDelay: (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval
    /// Delay between automatic retries of a raced vehicle selection. Injectable for tests.
    let selectionRetryDelay: TimeInterval
    let liveStreamPolicy: LiveStreamPolicy
    let liveStreamJitter: () -> Double
    let now: () -> Date
    let logger = AppLog.logger("refresh")
    /// Interval instrumentation for Instruments' os_signpost tool – free refresh-latency
    /// timelines without touching the unified log.
    static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "refresh")
    let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    /// The one scheduler for retries, confirmation polls and the next scheduled refresh. Task
    /// ticks are immune to run-loop modes – a status-item menu no longer defers them – and cancel
    /// structurally (shared `AsyncTimerLoop`, RT-08). It holds the injected wait, so every delay
    /// in this class, including the ones that run their own task, is one seam a test can drive
    /// instead of sleeping through.
    let scheduler: AsyncTimerLoop
    /// The live-streaming view of the selected adapter, handed in by the composition through the
    /// registry: this class no longer asks whether its adapter happens to conform.
    let streaming: (any VehicleLiveStreaming)?
    var task: Task<Void, Never>?
    var generation: UInt64 = 0
    /// Orders diagnostics publishes for `LatestDiagnosticsStore`, which may receive them late.
    var diagnosticsSequence: UInt64 = 0
    var failureCount = 0
    var rateLimitedUntil: Date?
    var lastManualRefresh: Date?
    var sleeping = false
    var networkAvailable = true
    /// Connection lifecycle for `.realTimeUpdates`: reconnects, circuit breaker, metrics.
    /// `nil` until a first stream starts, replaced on every restart.
    var streamEngine: LiveStreamEngine?
    /// True once the stream's token recovery has failed for good: the consumer session needs
    /// the user, so the stream stays parked while scheduled polling covers telemetry. Cleared
    /// only by a credential change, which is the one event that can heal it.
    var streamNeedsAuthorization = false
    /// Owns the whole Command receipt lifecycle: records, deadlines, watchdog, the display
    /// fields an awaiting command still owns, and which transport could prove it.
    let confirmations: CommandReceiptLedger
    var lastFullRefreshAt: Date?
    var sessionReady = false
    var accountEmail = ""
    /// Guards the detached email resolution fired by `start`, so a second start cannot
    /// double-read the Keychain.
    var accountEmailResolutionStarted = false
    var sessionIntent: SessionManager.Intent = .resume
    /// The selection this coordinator last started and has not yet resolved. Set when a
    /// switch begins, cleared only when it completes (or the session re-resolves the VIN).
    /// Because `preferences.vin` is written optimistically at switch start, this marker is
    /// what distinguishes "already settled on car X" from "car X failed mid-switch and the
    /// user is retrying" – without it a failed switch was unrecoverable.
    var requestedSelectionVIN: String?
    /// Callers awaiting a selection's outcome, keyed by VIN. Woken by the selection task's
    /// own completion, by a superseding selection, or by `cancelCurrentWork` – never polled.
    var selectionWaiters: [String: [CheckedContinuation<Bool, Never>]] = [:]
    /// Automatic retries consumed for the current selection attempt. A raced provider-side
    /// selection flip surfaces as `.notConfigured`, which is otherwise terminal; bounded
    /// retries recover it without letting a genuinely broken state loop forever.
    var selectionRetryCount = 0
    var observerTokens: [NSObjectProtocol] = []

    // Since-launch counters, published through DiagnosticsSnapshot so a support bundle
    // can distinguish "never refreshed" from "stopped refreshing".
    var refreshAttempts = 0
    var refreshSuccesses = 0
    var refreshFailures = 0

    /// Last provider-authored state. This is the only state allowed into persistence,
    /// history, telemetry confirmation, and notification evidence.
    var latestAuthoritative: VehicleState?
    /// UI projection of `latestAuthoritative`, optionally carrying a short-lived optimistic
    /// command overlay while an observable command is awaiting confirmation.
    var latest: VehicleState?
    var cars: [CarSummary] = []
    var lastError: VehicleServiceError?
    var nextRefresh: Date?
    var lastLatency: TimeInterval?

    var onEvent: ((RefreshCoordinatorEvent) -> Void)?

    /// True while a network operation owned by this coordinator is in flight. The background
    /// garage scan checks this so it never competes with (or flips shared provider state
    /// underneath) an interactive refresh or vehicle switch.
    var isBusy: Bool { task != nil }
    /// True inside a provider rate-limit pause. The garage scan also checks this: hammering
    /// through the window extends the backoff and starves the interactive paths.
    var isRateLimited: Bool { rateLimitedUntil.map({ $0 > now() }) ?? false }

    /// The facts `RefreshGate` decides from.
    private var admissionSituation: RefreshGate.Situation {
        RefreshGate.Situation(
            isAsleep: sleeping,
            isOnline: networkAvailable,
            hasSession: sessionReady,
            isWorking: task != nil,
            rateLimitedUntil: rateLimitedUntil,
            selectedVIN: preferences.vin,
            now: now()
        )
    }

    func admit(_ intent: RefreshIntent) -> RefreshAdmission {
        RefreshGate.admit(intent, in: admissionSituation)
    }

    init(api: any VehicleProviding, stateStore: VehicleStateStore,
         observesEnvironment: Bool = true,
         imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore,
         sessionManager: SessionManager = SessionManager(),
         retryDelay: @escaping (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval = RefreshPolicy.retryDelay,
         selectionRetryDelay: TimeInterval = 2,
         liveStreamPolicy: LiveStreamPolicy = LiveStreamPolicy(),
         liveStreamJitter: @escaping () -> Double = { Double.random(in: 0...1) },
         scheduler: AsyncTimerLoop = AsyncTimerLoop(),
         streaming: (any VehicleLiveStreaming)? = nil,
         now: @escaping () -> Date = Date.init,
         receiptLedger: CommandReceiptLedger? = nil,
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
        self.scheduler = scheduler
        self.streaming = streaming
        self.now = now
        // A test can hand in a ledger it already holds; otherwise the confirmation timing lives
        // with the confirmation behaviour rather than as three loose knobs here.
        self.confirmations = receiptLedger ?? CommandReceiptLedger(
            store: stateStore, now: now,
            confirmationWindow: commandConfirmationWindow,
            initialPollDelay: commandConfirmationInitialPollDelay,
            pollInterval: commandConfirmationPollInterval)
        guard observesEnvironment else { return }
        installSystemObservers()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let coordinator = self
            Task { @MainActor in coordinator?.networkDidChange(available) }
        }
        monitor.start(queue: monitorQueue)
    }
}
