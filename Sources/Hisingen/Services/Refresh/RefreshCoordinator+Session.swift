import AppKit
import Foundation
import Network
import OSLog

extension RefreshCoordinator {
    func start(preferredVIN: String?) {
        resolveAccountEmailInTheBackground()
        if let preferredVIN {
            if confirmations.restore(forVIN: preferredVIN) {
                scheduleConfirmationWatchdog(vin: preferredVIN)
            }
            if var cached = stateStore.snapshot(for: preferredVIN) {
                cached.setOptimisticLock(nil)
                latestAuthoritative = cached
                cached.publish(confirmations.overlay)
                latest = cached
                onEvent?(.state(cached))
            }
        }
        beginSession(preferredVIN: preferredVIN)
    }

    /// Resolves the account email used for account-change detection without touching the
    /// Keychain on the main thread. The first read after an app update can pause on an ACL
    /// consent prompt that a background launch cannot answer; keeping that pause off the
    /// launch path lets the panel render while it waits. A consent failure stays silent
    /// here (best-effort detection): the classified `.keychainConsentRequired` surfaces
    /// through session restore instead.
    private func resolveAccountEmailInTheBackground() {
        guard !accountEmailResolutionStarted else { return }
        accountEmailResolutionStarted = true
        if let cached = preferences.cachedEmail {
            accountEmail = cached
            return
        }
        let keychain = preferences.keychain
        let startedGeneration = generation
        Task.detached(priority: .utility) { [weak self] in
            let resolved = (try? keychain.readEmail()) ?? ""
            guard !resolved.isEmpty else { return }
            await MainActor.run { [weak self] in
                guard let self, self.accountEmail.isEmpty,
                      startedGeneration == self.generation else { return }
                self.accountEmail = resolved
            }
        }
    }

    func credentialsChanged(preferredVIN: String?) {
        // Called from a user-initiated Settings path where an app is frontmost, so the
        // synchronous Keychain read here can surface an approval prompt if one is pending.
        let oldAccount = accountEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let newAccount = preferences.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let accountChanged = !oldAccount.isEmpty && oldAccount != newAccount
        let previousVIN = latest?.identity.vin
        if let vin = previousVIN {
            stateStore.clearCommandReceipts(for: vin)
        }
        cancelCurrentWork()
        requestedSelectionVIN = nil
        selectionRetryCount = 0
        failureCount = 0
        rateLimitedUntil = nil
        sessionReady = false
        // New credentials are the one event that can heal a parked stream: its token exchange
        // was refused, and only a sign-in produces a token the stream will accept.
        streamNeedsAuthorization = false
        accountEmail = preferences.email
        sessionIntent = .credentialsChanged
        // Explicit save means the user is actively configuring: lift any prior
        // suppression so the following beginSession is not blocked. The saver
        // should already have cleared it; this is a safety net for future callers
        // that forget.
        preferences.clearExplicitSignOut(for: api.brand)
        if accountChanged {
            let eraseHistory = preferences.eraseHistoryOnSignOut
            var eraseSucceeded = true
            for car in cars {
                eraseSucceeded = stateStore.clear(vin: car.vin, eraseHistory: eraseHistory) && eraseSucceeded
            }
            if cars.isEmpty, let vin = previousVIN, !vin.isEmpty {
                eraseSucceeded = stateStore.clear(vin: vin, eraseHistory: eraseHistory) && eraseSucceeded
            }
            latest = nil
            latestAuthoritative = nil
            cars = []
            lastError = nil
            onEvent?(.vehiclesCleared)
            if !eraseSucceeded {
                lastError = .localDataErasure
                onEvent?(.failed(.localDataErasure))
            }
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
    /// discard months of charging and trip data. A sign-out that finds no vehicle known at all
    /// still goes fleet-wide over what the vehicles reported, but not over what the reader
    /// authored: a nickname or a theme for a brand left alone is not a session artifact. The
    /// only signal when revocation fails is `.secureStorage` in `lastError`.
    func signOut() {
        cancelCurrentWork()
        let requestGeneration = generation
        sessionReady = false
        streamNeedsAuthorization = false
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
            // User overrides must go too, or the next launch re-resolves the same
            // developer-app client and re-discovers the server-side grant. Builtins
            // stay compiled in, but `hasResumableSession` plus the explicit
            // sign-out flag below keep them from auto-restoring.
            preferences.polestarDataPortalAccountID = ""
            preferences.polestarDataPortalClientID = ""
        } else {
            // Revert a custom Volvo app to the built-in one; the session token is
            // deleted by `api.signOut()` below, so this alone stops auto-restore.
            preferences.volvoClientID = ""
        }
        let currentVin = preferences.vin
        preferences.setVin("", for: api.brand)
        preferences.setExplicitSignOut(for: api.brand)
        preferences.invalidateSessionCache()
        KeychainStore.app.invalidateMemoryCache()
        let eraseHistory = preferences.eraseHistoryOnSignOut
        var eraseSucceeded = true
        if carsToClear.isEmpty {
            if !currentVin.isEmpty {
                eraseSucceeded = stateStore.clear(vin: currentVin, eraseHistory: eraseHistory)
            } else {
                // No vehicle is known at all, so this is the fleet-wide session clear – named
                // rather than reached by leaving the VIN out.
                eraseSucceeded = stateStore.clearAll(eraseHistory: eraseHistory)
            }
        } else {
            for vin in carsToClear {
                eraseSucceeded = stateStore.clear(vin: vin, eraseHistory: eraseHistory) && eraseSucceeded
            }
        }
        if !eraseSucceeded { lastError = .localDataErasure }
        onEvent?(.vehiclesCleared)
        publishDiagnostics()
        task = Task {
            do {
                try await api.signOut()
            } catch {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                logger.error("Remote session revocation failed: \(String(describing: error), privacy: .public)")
                if eraseSucceeded { self.lastError = .secureStorage }
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            task = nil
            if let lastError { self.onEvent?(.failed(lastError)) }
            self.publishDiagnostics()
        }
    }

    func beginSession(preferredVIN: String?, deferIfBusy: Bool = false) {
        switch admit(.establishSession) {
        case .refused(.asleep):
            return
        case .refused(.alreadyRunning):
            // Direct triggers (launch, wake, network restore, manual refresh) can safely
            // stand down here: the in-flight operation owns subsequent scheduling and will
            // rearm itself. A one-shot retry TIMER cannot – if it bailed silently nothing
            // would ever reschedule, parking the app on a stale cache until a manual poke.
            // Re-arm briefly instead; each tick is cheap and stops as soon as the queue
            // clears (network operations are timeout-bounded).
            guard deferIfBusy else { return }
            schedule(after: 5, retrySession: true)
            return
        case .refused(.offline):
            handle(.network(URLError(.notConnectedToInternet)), retrySession: true)
            return
        case .start, .refused:
            break
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
                    confirmations.cancelWatchdog()
                    confirmations.clear()
                }
                if confirmations.isEmpty {
                    if confirmations.restore(forVIN: vin) {
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

    func cancelCurrentWork(preservingCommandConfirmation: Bool = false) {
        let preserveReceipt = preservingCommandConfirmation && !confirmations.isEmpty
        if preserveReceipt {
            confirmations.suspend()
        }
        generation &+= 1
        task?.cancel()
        task = nil
        confirmations.cancelWatchdog()
        if !preserveReceipt {
            confirmations.clear()
        }
        streamEngine?.stop()
        scheduler.cancel()
        nextRefresh = nil
        wakeSelectionWaiters(settled: false)
    }
}
