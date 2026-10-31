import Foundation

extension RefreshCoordinator {
    func beginCommandConfirmation(
        _ receipt: CommandReceipt,
        optimisticState: VehicleState? = nil
    ) {
        // The ledger owns the Remote Command target comparison: a receipt for another vehicle
        // is filed under that target's VIN, survives relaunch there, and has no live loop here.
        let filing = confirmations.begin(receipt, selectedVIN: latest?.identity.vin)
        guard filing.isForSelectedVehicle else { return }
        if var optimisticState,
           optimisticState.identity.vin == latest?.identity.vin {
            optimisticState.publish(.empty)
            latest = optimisticState
        }
        publishCommandReceipts()
        if filing.awaitsTelemetry, let vin = latest?.identity.vin {
            refreshCommandConfirmationInfrastructure(vin: vin)
        }
        guard filing.awaitsTelemetry else {
            publishDiagnostics()
            return
        }
        schedule(after: min(confirmations.initialPollDelay, confirmations.pollInterval),
                 retrySession: false, addsJitter: false)
        publishDiagnostics()
    }

    func dismissCommandReceipt(id: UUID) {
        guard confirmations.dismiss(id: id, vin: latest?.identity.vin) else { return }
        publishAfterReceiptDismissal()
    }

    func dismissCommandReceipt(issuedAt: Date) {
        guard confirmations.dismiss(issuedAt: issuedAt, vin: latest?.identity.vin) else { return }
        publishAfterReceiptDismissal()
    }

    private func publishAfterReceiptDismissal() {
        if var displayState = latest {
            displayState.publish(confirmations.overlay)
            onEvent?(.state(displayState))
        }
        publishDiagnostics()
    }

    /// The confirmation window must actually end. A held-open exterior stream only
    /// re-evaluates its purpose on the next frame or reconnect – on a quiet car that could
    /// leave a battery/exterior connection running for the whole idle timeout after its
    /// reason expired. The loop owns the deadline and settles the records; this re-decides the
    /// transport afterwards, which is what closes the stream.
    func scheduleConfirmationWatchdog(vin: String) {
        let requestGeneration = generation
        confirmations.armWatchdog(
            vin: vin,
            isValid: { [weak self] in
                guard let self else { return false }
                return requestGeneration == self.generation
            },
            onExpiry: { [weak self] didExpire in
                guard let self else { return }
                if didExpire { self.publishCommandReceipts() }
                guard self.latest?.identity.vin == vin else { return }
                self.refreshCommandConfirmationInfrastructure(vin: vin)
                self.scheduleFallbackPoll(for: self.latest)
                self.publishDiagnostics()
            }
        )
    }

    func resumeCommandConfirmationIfNeeded() {
        guard confirmations.isSuspended else { return }
        guard confirmations.resume() else { return }
        confirmations.persist(vin: latest?.identity.vin)
        if let vin = latest?.identity.vin {
            refreshCommandConfirmationInfrastructure(vin: vin)
        }
    }

    func refreshCommandConfirmationInfrastructure(vin: String) {
        guard latest?.identity.vin == vin else { return }
        if confirmations.expireLapsedWindows(vin: latest?.identity.vin) {
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
        displayState.publish(confirmations.overlay)
        onEvent?(.state(displayState))
    }
}
