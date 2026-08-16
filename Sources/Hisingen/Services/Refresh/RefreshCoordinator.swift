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
    private let clearPasswordAfterSession: () -> Void
    private let logger = Logger(subsystem: "io.kheirallah.hisingen", category: "refresh")
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "io.kheirallah.hisingen.network")

    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var failureCount = 0
    private var rateLimitedUntil: Date?
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
         clearPasswordAfterSession: @escaping () -> Void = { try? Keychain.deletePassword() }) {
        self.api = api
        self.stateStore = stateStore
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
        guard sessionReady else {
            beginSession(preferredVIN: Preferences.vin.nilIfEmpty)
            return
        }
        refresh(trigger: .manual)
    }

    func reloadVehicleMetadata() {
        guard rateLimitedUntil.map({ $0 <= Date() }) ?? true else { return }
        guard sessionReady, task == nil, !Preferences.vin.isEmpty else {
            refreshNow()
            return
        }
        let vin = Preferences.vin
        let requestGeneration = generation
        onLoading?()
        task = Task {
            do {
                try await api.selectCar(vin: vin, features: Preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                refresh(trigger: .manual)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                handle(VehicleServiceError.map(error, provider: api.brand), retrySession: false)
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
        guard vin != Preferences.vin else { return }
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        timer?.invalidate()
        Preferences.vin = vin
        latest = stateStore.snapshot(for: vin)
        if let latest { onState?(latest) } else { onLoading?() }
        let requestGeneration = generation
        task = Task {
            do {
                try await api.selectCar(vin: vin, features: Preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                refresh(trigger: .vehicleChanged)
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                handle(VehicleServiceError.map(error, provider: api.brand), retrySession: false)
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
        sessionReady = false
        latest = nil
        cars = []
        lastError = nil
        pendingEmail = ""
        pendingPassword = nil
        pendingSessionToken = nil
        rateLimitedUntil = nil
        Preferences.email = ""
        Preferences.vin = ""
        stateStore.clear()
        Task {
            do {
                try await api.signOut()
            } catch {
                self.lastError = .secureStorage
            }
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
                            features: Preferences.features
                        )
                    } else {
                        throw VehicleServiceError.authenticationRequired(provider: api.brand, reason: .noStoredSession)
                    }
                } catch {
                    guard VehicleServiceError.map(error, provider: api.brand).requiresAuthentication else { throw error }


                    guard let password = pendingPassword, !pendingEmail.isEmpty else { throw error }
                    try await api.authenticate(
                        email: pendingEmail,
                        password: password,
                        preferredVIN: preferredVIN,
                        features: Preferences.features
                    )
                }
                guard requestGeneration == generation, !Task.isCancelled else { return }
                guard let vin = await api.resolvedVIN(preferred: preferredVIN) else {
                    throw VehicleServiceError.notConfigured
                }
                Preferences.vin = vin
                cars = await api.cars
                onCars?(cars, vin)
                sessionReady = true
                pendingSessionToken = nil


                if pendingPassword != nil { clearPasswordAfterSession() }
                pendingPassword = nil
                let state = try await api.fetchVehicleState(vin: vin, features: Preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(state, latency: Date().timeIntervalSince(started))
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = VehicleServiceError.map(error, provider: api.brand)
                if mapped.requiresAuthentication { sessionReady = false }
                handle(mapped, retrySession: !sessionReady)
            }
        }
        publishDiagnostics()
    }

    private func refresh(trigger: Trigger) {
        guard task == nil, !sleeping, networkAvailable, sessionReady else { return }
        let vin = Preferences.vin
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
                let state = try await api.fetchVehicleState(vin: vin, features: Preferences.features)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                apply(state, latency: Date().timeIntervalSince(started))
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                task = nil
                let mapped = VehicleServiceError.map(error, provider: api.brand)
                if mapped.requiresAuthentication { sessionReady = false }
                handle(mapped, retrySession: false)
            }
        }
        publishDiagnostics()
    }

    private func apply(_ state: VehicleState, latency: TimeInterval) {
        let previous = latest
        var state = state.mergingLastKnown(from: previous, features: Preferences.features)
        if Preferences.storeChargingHistory,
           let session = ChargingSession.completed(
               previous: previous,
               current: state,
               pricePerKwh: Preferences.electricityPricePerKwh
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
                    self.beginSession(preferredVIN: Preferences.vin.nilIfEmpty)
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
            else { beginSession(preferredVIN: Preferences.vin.nilIfEmpty) }
        }
        publishDiagnostics()
    }

    private func installSystemObservers() {
        let center = NSWorkspace.shared.notificationCenter
        observerTokens.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleeping = true
                self?.cancelCurrentWork()
            }
        })
        observerTokens.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                if self.sessionReady { self.refresh(trigger: .wake) }
                else { self.beginSession(preferredVIN: Preferences.vin.nilIfEmpty) }
            }
        })
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


