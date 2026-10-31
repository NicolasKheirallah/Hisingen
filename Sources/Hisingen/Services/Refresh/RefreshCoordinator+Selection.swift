import Foundation

extension RefreshCoordinator {
    /// Switches the active vehicle. Idempotence is decided HERE and nowhere else.
    ///
    /// A switch is skipped only when it is a genuine no-op: the car is already selected,
    /// its state is live, and no earlier attempt is unresolved. Everything else runs –
    /// including a repeat click for a car whose previous switch failed, which is the only
    /// way the user can recover. The old pair of independent guards (the UI compared its
    /// stale `activeVin` copy while this method compared `preferences.vin`) disagreed after
    /// any same-brand switch: clicking the previously-active car was vetoed by the UI guard,
    /// re-clicking the new car was vetoed here, and the switcher locked up entirely until
    /// relaunch – invisible with one car, fatal with two on the same account.
    func selectCar(vin: String) {
        if case .refused(.rateLimited(let until)) = admit(.selection(vin: vin)) {
            // A silent drop reads as a frozen app; surface why switching is paused instead.
            // Multi-vehicle accounts double the request volume and hit this window far
            // more often than the single-car case.
            onEvent?(.switchPaused(.rateLimited(
                retryAfter: until.timeIntervalSince(now())
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

    /// One awaited seam for "vehicle X is selected and its first telemetry applied".
    /// Returns `true` when the selection settled for `vin` (its state was applied and no
    /// selection work remains), `false` when the selection failed, was superseded, the
    /// coordinator stopped, or `timeout` elapsed. Wakes on the selection task's own
    /// completion instead of leaving callers to poll display state.
    func selectionSettled(vin: String, timeout: TimeInterval = 30) async -> Bool {
        if selectionIsSettled(for: vin) { return true }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask {
                await self.awaitSelectionWaiter(vin: vin)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if let settled = first { return settled }
            // Timeout: release the still-registered waiter (resumed `false`), never leaked.
            self.wakeSelectionWaiters(vin: vin, settled: false)
            return false
        }
    }

    /// Registers one waiter. Runs on the actor, so registration cannot interleave with a
    /// wake: between the settled check in `selectionSettled` and this append, the main
    /// actor has not suspended.
    private func awaitSelectionWaiter(vin: String) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            selectionWaiters[vin, default: []].append(continuation)
        }
    }

    private func selectionIsSettled(for vin: String) -> Bool {
        vin == latest?.identity.vin && requestedSelectionVIN == nil && task == nil
    }

    func wakeSelectionWaiters(vin: String? = nil, settled: Bool) {
        let targets = vin.map { [$0] } ?? Array(selectionWaiters.keys)
        for key in targets {
            guard let waiters = selectionWaiters.removeValue(forKey: key) else { continue }
            waiters.forEach { $0.resume(returning: settled) }
        }
    }

    private func beginSelection(vin: String) {
        // Any earlier waiter is waiting on a selection this call supersedes.
        wakeSelectionWaiters(settled: false)
        confirmations.persist(vin: latest?.identity.vin)
        generation &+= 1
        failureCount = 0
        task?.cancel()
        task = nil
        confirmations.cancelWatchdog()
        confirmations.clear()
        streamEngine?.stop()
        scheduler.cancel()
        preferences.vin = vin
        requestedSelectionVIN = vin
        if confirmations.restore(forVIN: vin) {
            scheduleConfirmationWatchdog(vin: vin)
        }
        latestAuthoritative = stateStore.snapshot(for: vin)
        latestAuthoritative?.setOptimisticLock(nil)
        latest = latestAuthoritative
        latest?.publish(confirmations.overlay)
        if let latest { onEvent?(.state(latest)) } else { onEvent?(.loading) }
        onEvent?(.selectionChanged(vin))
        publishDiagnostics()
        runSelection(vin: vin)
    }

    private func runSelection(vin: String) {
        // Single-flight invariant: a selection retry firing inside its 2 s window can race a
        // manual/wake/network-restored refresh that legitimately holds `task`. Reschedule
        // instead of clobbering the slot – overwriting it ran two fetches concurrently and
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
                wakeSelectionWaiters(vin: vin, settled: true)
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
                wakeSelectionWaiters(vin: vin, settled: false)
                handle(mapped, retrySession: false)
            }
        }
    }

    private func scheduleSelectionRetry(vin: String, after seconds: TimeInterval) {
        let requestGeneration = generation
        let scheduler = scheduler
        Task { @MainActor [weak self] in
            do { try await scheduler.sleep(for: seconds) } catch { return }
            guard let self, !Task.isCancelled else { return }
            guard requestGeneration == self.generation else { return }
            self.publishDiagnostics()
            self.runSelection(vin: vin)
        }
    }
}
