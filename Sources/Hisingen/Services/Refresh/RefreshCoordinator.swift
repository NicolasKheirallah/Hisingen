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

enum RefreshPolicy {
    /// Floor for polls while the vehicle reports itself unavailable (asleep, power saving,
    /// in service). Deep-sleeping cars answer every poll with the same stale snapshot, so
    /// hammering the backend buys nothing; 15 minutes still recovers promptly on wake.
    static let vehicleAsleepInterval: TimeInterval = 900

    static func regularInterval(isCharging: Bool, isClimateActive: Bool = false) -> TimeInterval {
        (isCharging || isClimateActive) ? 60 : 300
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

@MainActor
final class RefreshCoordinator {
    enum Trigger { case timer, manual, wake, networkRestored, vehicleChanged }

    private let api: any VehicleProviding
    private let stateStore: VehicleStateStore
    private let imageCache: CarImageCache
    private let preferences: PreferencesStore
    private let clearPasswordAfterSession: () -> Void
    /// Re-reads stored session credentials. After a successful session the coordinator
    /// deliberately drops its in-memory copies (and deletes the password); when the access
    /// token later expires mid-run, `beginSession` must recover the refresh token from here
    /// instead of declaring `.noStoredSession` forever — which previously wedged refreshes
    /// in a permanent authentication-failure loop until app restart.
    private let readStoredSessionToken: () -> String?
    private let readStoredPassword: () -> String?
    /// Computes the delay before the next attempt. Injectable so tests can collapse the
    /// production exponential backoff (which legitimately stretches to minutes) to zero.
    private let retryDelay: (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval
    /// Delay between automatic retries of a raced vehicle selection. Injectable for tests.
    private let selectionRetryDelay: TimeInterval
    private let logger = AppLog.logger("refresh")
    /// Interval instrumentation for Instruments' os_signpost tool — free refresh-latency
    /// timelines without touching the unified log.
    private static let signposter = OSSignposter(subsystem: AppLog.subsystem, category: "refresh")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var streamTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureCount = 0
    private var rateLimitedUntil: Date?
    private var lastManualRefresh: Date?
    private var sleeping = false
    private var networkAvailable = true
    private var liveStreamConnected = false
    private var liveStreamRetryAt: Date?
    private var sessionReady = false
    private var pendingEmail = ""
    private var pendingPassword: String?
    private var pendingSessionToken: String?
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

    /// Fired once per successful session establishment — not on vehicle switches. The shell
    /// uses it to schedule the background garage scan: hooking that to `onCars` instead made
    /// every switch trigger a full scan ~8 s later (two extra discoveries plus a complete
    /// telemetry fan-out), tripping provider rate limits right after switching.
    var onSessionEstablished: (() -> Void)?
    /// A vehicle switch was requested but is paused by an active provider rate limit.
    /// Separate from `onError` because refreshes hit the same error on their normal
    /// schedule — only this one means the user just tapped a switch and got nothing.
    var onSwitchPaused: (() -> Void)?
    var onState: ((VehicleState) -> Void)?
    var onCars: (([CarSummary], String) -> Void)?
    /// Fired whenever the active-vehicle selection changes or resolves — optimistically when
    /// a switch begins and again once the provider-side swap completed. The shell syncs its
    /// visible "active car" marker from here; without it the marker stayed on the launch
    /// vehicle forever (only `beginSession` fired `onCars`), which let two disagreeing
    /// idempotence guards veto every further switch.
    var onSelectionChanged: ((String) -> Void)?
    var onError: ((VehicleServiceError) -> Void)?
    var onLoading: (() -> Void)?
    var onDiagnostics: ((DiagnosticsSnapshot) -> Void)?
    var onSignedOut: (() -> Void)?
    var onCleared: (() -> Void)?

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
         clearPasswordAfterSession: (() -> Void)? = nil,
         readStoredSessionToken: (() -> String?)? = nil,
         readStoredPassword: (() -> String?)? = nil,
         retryDelay: @escaping (_ failureCount: Int, _ retryAfter: TimeInterval?, _ requiresNewSession: Bool) -> TimeInterval = RefreshPolicy.retryDelay,
         selectionRetryDelay: TimeInterval = 2) {
        self.api = api
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.preferences = preferences
        let brand = api.brand
        self.clearPasswordAfterSession = clearPasswordAfterSession ?? {
            if brand == .polestar { try? Keychain.deletePassword() }
        }
        self.readStoredSessionToken = readStoredSessionToken ?? {
            brand == .volvo
                ? ((try? Keychain.readVolvoSessionToken()) ?? nil)
                : ((try? Keychain.readSessionToken()) ?? nil)
        }
        self.readStoredPassword = readStoredPassword ?? {
            brand == .volvo ? nil : ((try? Keychain.readPassword()) ?? nil)
        }
        self.retryDelay = retryDelay
        self.selectionRetryDelay = selectionRetryDelay
        guard observesEnvironment else { return }
        installSystemObservers()
        monitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            let coordinator = self
            Task { @MainActor in coordinator?.networkDidChange(available) }
        }
        monitor.start(queue: monitorQueue)
    }

    func start(email: String, password: String?, sessionToken: String?, preferredVIN: String?) {
        pendingEmail = email
        pendingPassword = password?.isEmpty == false ? password : nil
        pendingSessionToken = sessionToken?.isEmpty == false ? sessionToken : nil
        if let preferredVIN, let cached = stateStore.snapshot(for: preferredVIN) {
            latest = cached
            onState?(cached)
        }
        beginSession(preferredVIN: preferredVIN)
    }

    func credentialsChanged(email: String, password: String?, preferredVIN: String?) {
        let oldAccount = pendingEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newAccount = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountChanged = !oldAccount.isEmpty && oldAccount != newAccount
        cancelCurrentWork()
        requestedSelectionVIN = nil
        selectionRetryCount = 0
        failureCount = 0
        rateLimitedUntil = nil
        sessionReady = false
        pendingEmail = email
        pendingPassword = password?.isEmpty == false ? password : nil
        pendingSessionToken = nil
        if accountChanged {
            for car in cars {
                stateStore.clear(vin: car.vin)
            }
            if cars.isEmpty, !preferences.vin.isEmpty {
                stateStore.clear(vin: preferences.vin)
            }
            latest = nil
            cars = []
            lastError = nil
            onCleared?()
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
        onLoading?()
        task = Task {
            do {
                try await api.selectCar(vin: vin, features: preferences.features)
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
                switch latest.availability {
                case .available: return true
                case .unavailable: return false
                case .unknown: return nil
                }
            }()
        )
        if Date().timeIntervalSince(latest.fetchedAt) >= interval { refreshNow() }
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
            onSwitchPaused?()
            onError?(.rateLimited(retryAfter: rateLimitedUntil?.timeIntervalSinceNow))
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
        if vin == preferences.vin, requestedSelectionVIN == nil, latest?.vin == vin { return }
        beginSelection(vin: vin)
    }

    private func beginSelection(vin: String) {
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        streamTask?.cancel()
        streamTask = nil
        liveStreamConnected = false
        timer?.invalidate()
        preferences.vin = vin
        requestedSelectionVIN = vin
        latest = stateStore.snapshot(for: vin)
        if let latest { onState?(latest) } else { onLoading?() }
        onSelectionChanged?(vin)
        publishDiagnostics()
        runSelection(vin: vin)
    }

    private func runSelection(vin: String) {
        let requestGeneration = generation
        task = Task {
            do {
                try await api.selectCar(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                requestedSelectionVIN = nil
                selectionRetryCount = 0
                cars = await api.cars
                onSelectionChanged?(vin)
                // Deliberately NOT firing `onCars` here: it is a session-level event, and
                // its shell-side handler schedules the garage scan — which after a switch
                // meant two extra provider discoveries plus a full telemetry fan-out for
                // the other car ~8 s later, tripping rate limits right when the user
                // started interacting with the freshly selected vehicle.
                refresh(trigger: .vehicleChanged)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = ServiceErrorPolicy.decision(error, provider: api.brand).error
                // Polestar models a concurrently flipped shared selection (e.g. the garage
                // scan restoring the car it had captured at scan start) as `.notConfigured`.
                // `handle` treats that error as permanent — invalidating the refresh loop
                // and parking signed-in users on "Open Settings to sign in." until relaunch
                // — so retry the selection briefly before declaring failure.
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

    /// Signs out. Deliberate order: local data is wiped *first*, before the remote revoke
    /// round-trip, because privacy-on-failure beats session-persistence-on-failure — if the
    /// revoke request fails, the user still loses nothing by having local history cleared,
    /// whereas the reverse ordering would leave telemetry on disk after a failed sign-out.
    /// The only signal when revocation fails is `.secureStorage` in `lastError`.
    func signOut() {
        cancelCurrentWork()
        let requestGeneration = generation
        sessionReady = false
        latest = nil
        let carsToClear = cars.map(\.vin)
        cars = []
        lastError = nil
        pendingEmail = ""
        pendingPassword = nil
        pendingSessionToken = nil
        requestedSelectionVIN = nil
        selectionRetryCount = 0
        rateLimitedUntil = nil
        if api.brand == .polestar {
            preferences.email = ""
        }
        let currentVin = preferences.vin
        preferences.setVin("", for: api.brand)
        if carsToClear.isEmpty {
            if !currentVin.isEmpty {
                stateStore.clear(vin: currentVin)
            } else {
                stateStore.clear()
            }
        } else {
            for vin in carsToClear {
                stateStore.clear(vin: vin)
            }
        }
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
            self.onSignedOut?()
            if let lastError { self.onError?(lastError) }
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
        onLoading?()
        let requestGeneration = generation
        let started = Date()
        refreshAttempts += 1
        task = Task {
            do {
                do {
                    // Prefer the in-memory copy, then recover from the Keychain. Recovery is
                    // what keeps routine access-token expiry from becoming a permanent
                    // failure loop: after a successful session the pendings above are nil by
                    // design, but the refresh token still lives in the Keychain.
                    var sessionToken = pendingSessionToken ?? readStoredSessionToken()
                    if sessionToken?.isEmpty == true { sessionToken = nil }
                    if let sessionToken {
                        try await api.restoreSession(
                            token: sessionToken,
                            preferredVIN: preferredVIN,
                            features: preferences.features
                        )
                    } else {
                        throw VehicleServiceError.authenticationRequired(provider: api.brand, reason: .noStoredSession)
                    }
                } catch {
                    guard ServiceErrorPolicy.decision(error, provider: api.brand).error.requiresAuthentication else { throw error }

                    var password = pendingPassword ?? readStoredPassword()
                    if password?.isEmpty == true { password = nil }
                    guard let password, !pendingEmail.isEmpty else { throw error }
                    try await api.authenticate(
                        email: pendingEmail,
                        password: password,
                        preferredVIN: preferredVIN,
                        features: preferences.features
                    )
                }
                guard requestGeneration == generation, !Task.isCancelled else { return }
                guard let vin = await api.resolvedVIN(preferred: preferredVIN) else {
                    throw VehicleServiceError.notConfigured
                }
                preferences.vin = vin
                // The session just re-resolved the selection; any in-flight switch attempt
                // is superseded and its retry budget resets.
                requestedSelectionVIN = nil
                selectionRetryCount = 0
                onSelectionChanged?(vin)
                cars = await api.cars
                onCars?(cars, vin)
                onSessionEstablished?()
                sessionReady = true
                pendingSessionToken = nil


                if pendingPassword != nil { clearPasswordAfterSession() }
                pendingPassword = nil
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
        if trigger == .manual { onLoading?() }
        timer?.invalidate()
        nextRefresh = nil
        let requestGeneration = generation
        let started = Date()
        refreshAttempts += 1
        task = Task {
            // Signpost spans the network round trip so Instruments shows per-refresh
            // latency without any log volume.
            let intervalState = Self.signposter.beginInterval("fetchVehicleState")
            do {
                let state = try await api.fetchVehicleState(vin: vin, features: preferences.features)
                Self.signposter.endInterval("fetchVehicleState", intervalState)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(state, latency: Date().timeIntervalSince(started))
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

    private func apply(_ state: VehicleState, latency: TimeInterval) {
        let previous = latest
        var state = state.mergingLastKnown(
            from: previous, features: preferences.features, imageCache: imageCache
        )
        // A fresh, provider-backed snapshot supersedes any optimistic command patch; the
        // "waiting for the vehicle" marker must not survive into it (and is deliberately not
        // carried across by `mergingLastKnown`).
        state.pendingCommand = nil
        if preferences.storeChargingHistory,
           let session = ChargingSession.completed(
               previous: previous,
               current: state,
               pricePerKwh: preferences.electricityPricePerKwh,
               usableCapacityKwh: preferences.vehicleSpecificationOverride(for: state.vin)?.usableBatteryCapacityKwh
           ) {
            state.chargingSessions.append(session)
            if state.chargingSessions.count > 20 {
                state.chargingSessions.removeFirst(state.chargingSessions.count - 20)
            }
        }
        latest = state
        lastError = nil
        lastLatency = latency
        failureCount = 0
        refreshSuccesses += 1
        rateLimitedUntil = nil
        stateStore.save(state)
        SpotlightIndexer.indexVehicle(state, nickname: preferences.vehicleNickname(for: state.vin))
        onState?(state)
        startLiveStreamingIfNeeded(vin: state.vin)
        schedule(after: RefreshPolicy.interval(
            isCharging: state.isCharging,
            isClimateActive: state.isClimateActive,
            isVehicleAvailable: {
                switch state.availability {
                case .available: return true
                case .unavailable: return false
                case .unknown: return nil
                }
            }()
        ), retrySession: false)
        publishDiagnostics()
    }

    private func handle(_ error: VehicleServiceError, retrySession: Bool) {
        lastError = error
        failureCount += 1
        refreshFailures += 1
        // `String(describing:)` keeps enum payloads and NSError codes that
        // `localizedDescription` flattens away.
        logger.error("Refresh failed (attempt \(self.failureCount, privacy: .public) consecutive): \(String(describing: error), privacy: .public)")
        onError?(error)
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
        let delay = interval + jitter
        nextRefresh = Date().addingTimeInterval(delay)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if retrySession || !self.sessionReady {
                    self.beginSession(preferredVIN: preferences.vin.nilIfEmpty, deferIfBusy: true)
                } else {
                    self.refresh(trigger: .timer)
                }
            }
        }
    }

    private func networkDidChange(_ available: Bool) {
        let restored = available && !networkAvailable
        networkAvailable = available
        if !available {
            cancelCurrentWork()
        } else if restored && !sleeping {
            if sessionReady { refresh(trigger: .networkRestored) }
            else { beginSession(preferredVIN: preferences.vin.nilIfEmpty) }
        }
        publishDiagnostics()
    }

    private func installSystemObservers() {
        observerTokens.append(addMainActorObserver(for: NSWorkspace.willSleepNotification) { coordinator in
            coordinator.sleeping = true
            coordinator.cancelCurrentWork()
        })
        observerTokens.append(addMainActorObserver(for: NSWorkspace.didWakeNotification) { coordinator in
            coordinator.sleeping = false
            if coordinator.sessionReady { coordinator.refresh(trigger: .wake) }
            else { coordinator.beginSession(preferredVIN: coordinator.preferences.vin.nilIfEmpty) }
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

    private func cancelCurrentWork() {
        generation &+= 1
        task?.cancel()
        task = nil
        streamTask?.cancel()
        streamTask = nil
        liveStreamConnected = false
        liveStreamRetryAt = nil
        timer?.invalidate()
        timer = nil
        nextRefresh = nil
    }

    private func publishDiagnostics() {
        onDiagnostics?(DiagnosticsSnapshot(
            lastSuccess: latest?.fetchedAt,
            lastError: lastError?.localizedDescription,
            latency: lastLatency,
            nextRefresh: nextRefresh,
            sessionValid: sessionReady,
            networkAvailable: networkAvailable,
            refreshInProgress: task != nil,
            unavailableFeatures: latest?.unavailableFeatures ?? [],
            servingCachedSnapshot: latest?.isCachedSnapshot ?? false,
            liveStreamConnected: liveStreamConnected,
            liveStreamRetryAt: liveStreamRetryAt,
            refreshAttempts: refreshAttempts,
            refreshSuccesses: refreshSuccesses,
            refreshFailures: refreshFailures,
            vehicleSwitchPending: requestedSelectionVIN != nil
        ))
    }

    private func startLiveStreamingIfNeeded(vin: String) {
        guard preferences.features.contains(.realTimeUpdates), streamTask == nil,
              let streaming = api as? any VehicleLiveStreaming else { return }
        let requestGeneration = generation
        streamTask = Task { [weak self] in
            var failure = 0
            // Streamed frames can arrive several times a minute; persisting every frame used
            // to write the full snapshot blob (plus telemetry rows) per message. UI updates
            // stay immediate; disk writes coalesce.
            var lastPersistAt = Date.distantPast
            while !Task.isCancelled {
                guard let self, requestGeneration == self.generation,
                      self.latest?.vin == vin else { return }
                do {
                    let stream = try await streaming.liveVehicleUpdates(vin: vin)
                    self.liveStreamConnected = true
                    self.liveStreamRetryAt = nil
                    self.publishDiagnostics()
                    failure = 0
                    for try await update in stream {
                        try Task.checkCancellation()
                        guard requestGeneration == self.generation,
                              var current = self.latest, current.vin == vin else { return }
                        current.applyLiveUpdate(update)
                        self.latest = current
                        let now = Date()
                        if now.timeIntervalSince(lastPersistAt) >= 10 {
                            lastPersistAt = now
                            self.stateStore.save(current)
                        }
                        self.onState?(current)
                    }
                    throw VehicleServiceError.temporarilyUnavailable(
                        provider: self.api.brand, service: "live vehicle stream"
                    )
                } catch is CancellationError {
                    return
                } catch {
                    self.liveStreamConnected = false
                    failure += 1
                    let delay = min(5 * pow(2, Double(min(failure - 1, 4))), 60)
                    self.liveStreamRetryAt = Date().addingTimeInterval(delay)
                    self.logger.warning("Live stream dropped; retrying in \(Int(delay), privacy: .public)s: \(String(describing: error), privacy: .public)")
                    self.publishDiagnostics()
                    do { try await Task.sleep(for: .seconds(delay)) }
                    catch { return }
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
