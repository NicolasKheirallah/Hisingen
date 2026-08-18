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
}

enum RefreshPolicy {
    static func regularInterval(isCharging: Bool, isClimateActive: Bool = false) -> TimeInterval {
        (isCharging || isClimateActive) ? 60 : 300
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
    private let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "refresh")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureCount = 0
    private var rateLimitedUntil: Date?
    private var lastManualRefresh: Date?
    private var sleeping = false
    private var networkAvailable = true
    private var sessionReady = false
    private var pendingEmail = ""
    private var pendingPassword: String?
    private var pendingSessionToken: String?
    private var observerTokens: [NSObjectProtocol] = []

    private(set) var latest: VehicleState?
    private(set) var cars: [CarSummary] = []
    private(set) var lastError: VehicleServiceError?
    private(set) var nextRefresh: Date?
    private(set) var lastLatency: TimeInterval?

    var onState: ((VehicleState) -> Void)?
    var onCars: (([CarSummary], String) -> Void)?
    var onError: ((VehicleServiceError) -> Void)?
    var onLoading: (() -> Void)?
    var onDiagnostics: ((DiagnosticsSnapshot) -> Void)?
    var onSignedOut: (() -> Void)?
    var onCleared: (() -> Void)?

    init(api: any VehicleProviding, stateStore: VehicleStateStore,
         observesEnvironment: Bool = true,
         imageCache: CarImageCache = CarImageCache(),
         preferences: PreferencesStore,
         clearPasswordAfterSession: @escaping () -> Void = { try? Keychain.deletePassword() }) {
        self.api = api
        self.stateStore = stateStore
        self.imageCache = imageCache
        self.preferences = preferences
        self.clearPasswordAfterSession = clearPasswordAfterSession
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
        failureCount = 0
        rateLimitedUntil = nil
        sessionReady = false
        pendingEmail = email
        pendingPassword = password?.isEmpty == false ? password : nil
        pendingSessionToken = nil
        if accountChanged {
            stateStore.clear()
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
        let interval = RefreshPolicy.regularInterval(isCharging: latest.isCharging, isClimateActive: latest.isClimateActive)
        if Date().timeIntervalSince(latest.fetchedAt) >= interval { refreshNow() }
    }

    func selectCar(vin: String) {
        guard rateLimitedUntil.map({ $0 <= Date() }) ?? true else { return }
        guard vin != preferences.vin else { return }
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        timer?.invalidate()
        preferences.vin = vin
        latest = stateStore.snapshot(for: vin)
        if let latest { onState?(latest) } else { onLoading?() }
        let requestGeneration = generation
        task = Task {
            do {
                try await api.selectCar(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                refresh(trigger: .vehicleChanged)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                handle(ServiceErrorPolicy.decision(error, provider: api.brand).error, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    func stop() {
        cancelCurrentWork()
        monitor.cancel()
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observerTokens.forEach(workspaceCenter.removeObserver)
        observerTokens.removeAll()
    }

    func signOut() {
        cancelCurrentWork()
        let requestGeneration = generation
        sessionReady = false
        latest = nil
        cars = []
        lastError = nil
        pendingEmail = ""
        pendingPassword = nil
        pendingSessionToken = nil
        rateLimitedUntil = nil
        preferences.email = ""
        preferences.vin = ""
        stateStore.clear()
        task = Task {
            do {
                try await api.signOut()
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                self.lastError = .secureStorage
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            task = nil
            self.onSignedOut?()
            if let lastError { self.onError?(lastError) }
            self.publishDiagnostics()
        }
    }

    private func beginSession(preferredVIN: String?) {
        guard task == nil, !sleeping else { return }
        guard networkAvailable else {
            handle(.network(URLError(.notConnectedToInternet)), retrySession: true)
            return
        }
        onLoading?()
        let requestGeneration = generation
        let started = Date()
        task = Task {
            do {
                do {
                    if let pendingSessionToken {
                        try await api.restoreSession(
                            token: pendingSessionToken,
                            preferredVIN: preferredVIN,
                            features: preferences.features
                        )
                    } else {
                        throw VehicleServiceError.authenticationRequired(provider: api.brand, reason: .noStoredSession)
                    }
                } catch {
                    guard ServiceErrorPolicy.decision(error, provider: api.brand).error.requiresAuthentication else { throw error }


                    guard let password = pendingPassword, !pendingEmail.isEmpty else { throw error }
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
                cars = await api.cars
                onCars?(cars, vin)
                sessionReady = true
                pendingSessionToken = nil


                if pendingPassword != nil { clearPasswordAfterSession() }
                pendingPassword = nil
                let state = try await api.fetchVehicleState(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(state, latency: Date().timeIntervalSince(started))
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
        task = Task {
            do {
                let state = try await api.fetchVehicleState(vin: vin, features: preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(state, latency: Date().timeIntervalSince(started))
            } catch {
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
        if preferences.storeChargingHistory,
           let session = ChargingSession.completed(
               previous: previous,
               current: state,
               pricePerKwh: preferences.electricityPricePerKwh
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
        rateLimitedUntil = nil
        stateStore.save(state)
        onState?(state)
        schedule(after: RefreshPolicy.regularInterval(isCharging: state.isCharging, isClimateActive: state.isClimateActive), retrySession: false)
        publishDiagnostics()
    }

    private func handle(_ error: VehicleServiceError, retrySession: Bool) {
        lastError = error
        failureCount += 1
        logger.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
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
        let delay = RefreshPolicy.retryDelay(
            failureCount: failureCount, retryAfter: retryAfter, requiresNewSession: needsSession
        )
        if case .rateLimited = error { rateLimitedUntil = Date().addingTimeInterval(delay) }
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
                    self.beginSession(preferredVIN: preferences.vin.nilIfEmpty)
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
            servingCachedSnapshot: latest?.isCachedSnapshot ?? false
        ))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
