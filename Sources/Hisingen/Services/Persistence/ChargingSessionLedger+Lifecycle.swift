import Foundation

extension ChargingSessionLedger {
    // MARK: - Lifecycle ingest

    func ingest(
        _ observation: ChargingSessionObservation,
        configuration: ChargingSessionLedgerConfiguration,
        recordingEnabled: Bool
    ) {
        guard recordingEnabled else {
            if let active = activeChargingSession(for: observation.vin) {
                // Disabling local history is a privacy instruction, so an unfinished row and
                // its observations are removed instead of retained as an abandoned diagnostic.
                discardChargingSession(id: active.id)
            }
            return
        }

        // An app restart may encounter an unfinished row whose last observation is days old.
        // Close that boundary before interpreting *any* new state; otherwise two idle polls
        // could accidentally turn yesterday's orphan into a multi-day completed charge.
        if let active = activeChargingSession(for: observation.vin),
           observation.timestamp.timeIntervalSince(active.lastObservedAt ?? active.startedAt)
            > Self.maximumContinuityGap {
            abandonChargingSession(
                id: active.id, endedAt: active.lastObservedAt ?? active.startedAt,
                reason: .staleObservation
            )
            guard observation.chargingState.isActivelyCharging else { return }
        }

        if observation.chargerConnection == .fault {
            finalize(observation, configuration: configuration, reason: .fault,
                     lifecycle: .interrupted)
            return
        }

        switch observation.chargingState {
        case .charging, .smartCharging:
            ingestActive(observation, configuration: configuration)
        case .paused, .scheduled:
            guard let active = activeChargingSession(for: observation.vin) else { return }
            if !shouldThinPausedSample(sessionId: active.id, observation: observation) {
                appendSample(observation, to: active.id)
                enforceSampleCap(sessionId: active.id)
            }
            updateChargingSessionLifecycle(
                id: active.id, state: .paused, observedAt: observation.timestamp,
                pendingStopCount: 0, targetSoc: observation.targetSoc
            )
        case .complete:
            finalize(observation, configuration: configuration, reason: .targetReached,
                     lifecycle: .completed)
        case .fault:
            finalize(observation, configuration: configuration, reason: .fault,
                     lifecycle: .interrupted)
        case .idle, .discharging, .unknown:
            guard let active = activeChargingSession(for: observation.vin) else { return }
            appendSample(observation, to: active.id)
            let pendingCount = active.pendingStopCount + 1
            guard pendingCount >= Self.requiredStopObservations else {
                updateChargingSessionLifecycle(
                    id: active.id, state: .pendingCompletion,
                    observedAt: observation.timestamp, pendingStopCount: pendingCount,
                    targetSoc: observation.targetSoc
                )
                return
            }
            let greatestSoc = chargingSamples(for: active.id).map(\.soc).max()
                ?? observation.soc
            let reachedTarget = (observation.targetSoc ?? active.targetSoc).map {
                greatestSoc >= $0 - 0.5
            } ?? (greatestSoc >= 99.5)
            let reason: ChargingSessionCompletionReason = reachedTarget
                ? .targetReached
                : (observation.chargerConnection == .disconnected ? .disconnected : .stopped)
            finalizeExisting(
                active, observation: observation, configuration: configuration,
                reason: reason, lifecycle: reachedTarget ? .completed : .interrupted,
                appendTerminalObservation: false
            )
        }
    }

    private func ingestActive(
        _ observation: ChargingSessionObservation,
        configuration: ChargingSessionLedgerConfiguration
    ) {
        let active = activeChargingSession(for: observation.vin)

        let sessionId: String
        if let active {
            sessionId = active.id
        } else {
            sessionId = startChargingSession(
                vin: observation.vin, startSoc: observation.soc,
                location: configuration.locationName, startedAt: observation.timestamp,
                usableCapacityKwh: configuration.usableCapacityKwh,
                tariffPricePerKwh: configuration.tariffPricePerKwh,
                nightTariffEnabled: configuration.nightTariffEnabled,
                nightTariffPricePerKwh: configuration.nightTariffPricePerKwh,
                nightTariffStartHour: configuration.nightTariffStartHour,
                nightTariffEndHour: configuration.nightTariffEndHour,
                currencySymbol: configuration.currencySymbol,
                targetSoc: observation.targetSoc
            )
        }
        appendSample(observation, to: sessionId)
        updateChargingSessionLifecycle(
            id: sessionId, state: .active, observedAt: observation.timestamp,
            pendingStopCount: 0, targetSoc: observation.targetSoc
        )
    }

    private func finalize(
        _ observation: ChargingSessionObservation,
        configuration: ChargingSessionLedgerConfiguration,
        reason: ChargingSessionCompletionReason,
        lifecycle: ChargingSessionLifecycleState
    ) {
        guard let active = activeChargingSession(for: observation.vin) else { return }
        finalizeExisting(
            active, observation: observation, configuration: configuration,
            reason: reason, lifecycle: lifecycle, appendTerminalObservation: true
        )
    }

    private func finalizeExisting(
        _ active: HistoricalChargingSession,
        observation: ChargingSessionObservation,
        configuration: ChargingSessionLedgerConfiguration,
        reason: ChargingSessionCompletionReason,
        lifecycle: ChargingSessionLifecycleState,
        appendTerminalObservation: Bool
    ) {
        if appendTerminalObservation { appendSample(observation, to: active.id) }
        let samples = chargingSamples(for: active.id)
        let capacity = active.usableCapacityKwh ?? configuration.usableCapacityKwh
        let summary = ChargingSessionSummaryCalculator.calculate(
            startSoc: active.startSoc, terminalSoc: observation.soc,
            startedAt: active.startedAt, endedAt: observation.timestamp,
            samples: samples, usableCapacityKwh: capacity
        )
        guard summary.endSoc > active.startSoc, summary.energyKwh > 0 else {
            abandonChargingSession(
                id: active.id, endedAt: observation.timestamp, reason: .noEnergyAdded
            )
            return
        }
        let tariff = active.tariffPricePerKwh ?? configuration.tariffPricePerKwh
        let nightEnabled = active.nightTariffEnabled
        let nightTariff = active.nightTariffPricePerKwh
        let nightStart = active.nightTariffStartHour
        let nightEnd = active.nightTariffEndHour
        let estimatedCost: Double? = {
            if nightEnabled, let tariff, let nightTariff, let nightStart, let nightEnd,
               let split = Self.tariffAwareCost(
                from: samples, dayRatePerKwh: tariff,
                nightRatePerKwh: nightTariff,
                nightStartHour: nightStart, nightEndHour: nightEnd
               ) {
                // The split's integrated power is used only as a day/night weighting. Scale
                // it to the authoritative session energy so sparse observations cannot make
                // a SoC-derived charge look artificially cheap.
                let weightedEnergy = split.dayEnergyKwh + split.nightEnergyKwh
                guard weightedEnergy > 0 else { return tariff * summary.energyKwh }
                return split.cost * summary.energyKwh / weightedEnergy
            }
            return tariff.map { $0 * summary.energyKwh }
        }()
        completeChargingSession(
            id: active.id, endSoc: summary.endSoc,
            energyDeliveredKwh: summary.energyKwh,
            peakPowerKw: summary.peakPowerKw, averagePowerKw: summary.averagePowerKw,
            endedAt: observation.timestamp, lifecycleState: lifecycle,
            completionReason: reason, energySource: summary.source,
            confidence: summary.confidence, usableCapacityKwh: capacity,
            tariffPricePerKwh: tariff,
            nightTariffEnabled: nightEnabled,
            nightTariffPricePerKwh: nightTariff,
            nightTariffStartHour: nightStart,
            nightTariffEndHour: nightEnd,
            currencySymbol: active.currencySymbol ?? configuration.currencySymbol,
            targetSoc: observation.targetSoc ?? active.targetSoc,
            sampleCoverage: summary.sampleCoverage,
            estimatedCost: estimatedCost
        )
    }

    private func appendSample(_ observation: ChargingSessionObservation, to sessionId: String) {
        recordChargingSample(
            sessionId: sessionId, vin: observation.vin, soc: observation.soc,
            powerKw: observation.powerKw, voltage: observation.voltageVolts,
            current: observation.currentAmps, chargingType: observation.chargingType.rawValue,
            timestamp: observation.timestamp
        )
    }

    private func shouldThinPausedSample(sessionId: String, observation: ChargingSessionObservation) -> Bool {
        let last: (Date, Double)? = (try? sql.query(sql: "SELECT timestamp, soc FROM charging_samples WHERE session_id = ? ORDER BY timestamp DESC LIMIT 1;") { stmt in
            try stmt.bindText(sessionId, at: 1)
        } process: { stmt -> (Date, Double)? in
            guard try stmt.stepOrThrow(), let ts = stmt.columnDate(at: 0), let soc = stmt.columnDouble(at: 1) else { return nil }
            return (ts, soc)
        }) ?? nil
        guard let (lastTs, lastSoc) = last else { return false }
        if abs(observation.soc - lastSoc) >= 0.1 { return false }
        return observation.timestamp.timeIntervalSince(lastTs) < 3_600
    }

    private func enforceSampleCap(sessionId: String) {
        let count: Int = (try? sql.query(sql: "SELECT COUNT(*) FROM charging_samples WHERE session_id = ?;") { stmt in
            try stmt.bindText(sessionId, at: 1)
        } process: { stmt -> Int in
            guard try stmt.stepOrThrow() else { return 0 }
            return Int(stmt.columnInt64(at: 0) ?? 0)
        }) ?? 0
        guard count > Self.maximumSamplesPerSession else { return }
        let excess = count - Self.maximumSamplesPerSession
        logOnFailure("sample cap prune") {
            try sql.query(sql: "DELETE FROM charging_samples WHERE rowid IN (SELECT rowid FROM charging_samples WHERE session_id = ? ORDER BY timestamp ASC LIMIT ?);") { stmt in
                try stmt.bindText(sessionId, at: 1)
                try stmt.bindInt64(Int64(excess), at: 2)
            } process: { _ in }
        }
    }
}
