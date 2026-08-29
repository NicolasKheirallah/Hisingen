import Foundation

struct ChargingSessionObservation: Equatable, Sendable {
    let vin: String
    let timestamp: Date
    let soc: Double
    let chargingState: ChargingState
    let chargerConnection: ChargerConnection
    let powerKw: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
    let chargingType: ChargingType
    let targetSoc: Double?
}

struct ChargingSessionEngineConfiguration: Equatable, Sendable {
    let usableCapacityKwh: Double
    let tariffPricePerKwh: Double?
    let nightTariffEnabled: Bool
    let nightTariffPricePerKwh: Double?
    let nightTariffStartHour: Int
    let nightTariffEndHour: Int
    let currencySymbol: String?
    let locationName: String?

    init(
        usableCapacityKwh: Double, tariffPricePerKwh: Double?,
        nightTariffEnabled: Bool = false, nightTariffPricePerKwh: Double? = nil,
        nightTariffStartHour: Int = 22, nightTariffEndHour: Int = 6,
        currencySymbol: String?, locationName: String?
    ) {
        self.usableCapacityKwh = usableCapacityKwh
        self.tariffPricePerKwh = tariffPricePerKwh
        self.nightTariffEnabled = nightTariffEnabled
        self.nightTariffPricePerKwh = nightTariffPricePerKwh
        self.nightTariffStartHour = nightTariffStartHour
        self.nightTariffEndHour = nightTariffEndHour
        self.currencySymbol = currencySymbol
        self.locationName = locationName
    }
}

struct ChargingSessionCalculatedSummary: Equatable, Sendable {
    let endSoc: Double
    let energyKwh: Double
    let peakPowerKw: Double
    let averagePowerKw: Double
    let source: ChargingSessionEnergySource
    let confidence: ChargingSessionConfidence
    let sampleCoverage: Double
}

enum ChargingSessionSummaryCalculator {
    /// Gaps longer than this are evidence that Hisingen did not observe the interval and must
    /// not be silently integrated as if the last power value held throughout it.
    static let maximumIntegratableGap = HistoryInsights.chargingCurveGapThreshold

    static func calculate(
        startSoc: Double, terminalSoc: Double, startedAt: Date, endedAt: Date,
        samples: [HistoricalChargingSample], usableCapacityKwh: Double
    ) -> ChargingSessionCalculatedSummary {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        // A provider's first stop snapshots can lag behind its final charging sample. Preserve
        // the greatest SoC actually observed inside the session instead of allowing one stale
        // terminal value to erase the gain.
        let greatestObservedSoc = ordered.map(\.soc).max() ?? startSoc
        let endSoc = max(startSoc, max(terminalSoc, greatestObservedSoc))
        let powers = ordered.compactMap(\.powerKw).filter { $0 > 0 }
        let peak = powers.max() ?? 0
        let average = powers.isEmpty ? 0 : powers.reduce(0, +) / Double(powers.count)
        let duration = max(0, endedAt.timeIntervalSince(startedAt))

        var integratedKwh = 0.0
        var coveredSeconds = 0.0
        if ordered.count >= 2 {
            for (first, second) in zip(ordered, ordered.dropFirst()) {
                let interval = second.timestamp.timeIntervalSince(first.timestamp)
                guard interval > 0, interval <= maximumIntegratableGap,
                      let firstPower = first.powerKw, firstPower > 0,
                      let secondPower = second.powerKw, secondPower > 0 else { continue }
                integratedKwh += ((firstPower + secondPower) / 2) * interval / 3_600
                coveredSeconds += interval
            }
        }
        let coverage = duration > 0 ? min(1, coveredSeconds / duration) : 0
        if integratedKwh > 0, coverage >= 0.70 {
            return ChargingSessionCalculatedSummary(
                endSoc: endSoc, energyKwh: integratedKwh,
                peakPowerKw: peak, averagePowerKw: average,
                source: .observedPowerIntegration,
                confidence: coverage >= 0.90 ? .high : .medium,
                sampleCoverage: coverage
            )
        }

        let socEnergy = max(0, endSoc - startSoc) / 100 * max(0, usableCapacityKwh)
        let confidence: ChargingSessionConfidence = ordered.count >= 3 && endSoc - startSoc >= 1
            ? .medium : .low
        return ChargingSessionCalculatedSummary(
            endSoc: endSoc, energyKwh: socEnergy,
            peakPowerKw: peak, averagePowerKw: average,
            source: .socCapacityEstimate, confidence: confidence,
            sampleCoverage: coverage
        )
    }
}

/// The sole owner of charging-session lifecycle transitions.
///
/// `charging_samples` is the append-only observation log. `charging_sessions` is a versioned
/// materialized summary that this engine advances through explicit states. A one-poll idle or
/// disconnect is only `pendingCompletion`; a second confirms the stop. Paused and scheduled
/// charging keep the physical session open and a new active observation resumes it.
final class ChargingSessionEngine: Sendable {
    static let requiredStopObservations = 2
    static let maximumContinuityGap: TimeInterval = 48 * 60 * 60

    private let database: VehicleDatabase

    init(database: VehicleDatabase) {
        self.database = database
    }

    func ingest(
        _ observation: ChargingSessionObservation,
        configuration: ChargingSessionEngineConfiguration,
        recordingEnabled: Bool
    ) {
        guard recordingEnabled else {
            if let active = database.activeChargingSession(for: observation.vin) {
                // Disabling local history is a privacy instruction, so an unfinished row and
                // its observations are removed instead of retained as an abandoned diagnostic.
                database.discardChargingSession(id: active.id)
            }
            return
        }

        // An app restart may encounter an unfinished row whose last observation is days old.
        // Close that boundary before interpreting *any* new state; otherwise two idle polls
        // could accidentally turn yesterday's orphan into a multi-day completed charge.
        if let active = database.activeChargingSession(for: observation.vin),
           observation.timestamp.timeIntervalSince(active.lastObservedAt ?? active.startedAt)
            > Self.maximumContinuityGap {
            database.abandonChargingSession(
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
            guard let active = database.activeChargingSession(for: observation.vin) else { return }
            append(observation, to: active.id)
            database.updateChargingSessionLifecycle(
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
            guard let active = database.activeChargingSession(for: observation.vin) else { return }
            append(observation, to: active.id)
            let pendingCount = active.pendingStopCount + 1
            guard pendingCount >= Self.requiredStopObservations else {
                database.updateChargingSessionLifecycle(
                    id: active.id, state: .pendingCompletion,
                    observedAt: observation.timestamp, pendingStopCount: pendingCount,
                    targetSoc: observation.targetSoc
                )
                return
            }
            let greatestSoc = database.chargingSamples(for: active.id).map(\.soc).max()
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
        configuration: ChargingSessionEngineConfiguration
    ) {
        let active = database.activeChargingSession(for: observation.vin)

        let sessionId: String
        if let active {
            sessionId = active.id
        } else {
            sessionId = database.startChargingSession(
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
        append(observation, to: sessionId)
        database.updateChargingSessionLifecycle(
            id: sessionId, state: .active, observedAt: observation.timestamp,
            pendingStopCount: 0, targetSoc: observation.targetSoc
        )
    }

    private func finalize(
        _ observation: ChargingSessionObservation,
        configuration: ChargingSessionEngineConfiguration,
        reason: ChargingSessionCompletionReason,
        lifecycle: ChargingSessionLifecycleState
    ) {
        guard let active = database.activeChargingSession(for: observation.vin) else { return }
        finalizeExisting(
            active, observation: observation, configuration: configuration,
            reason: reason, lifecycle: lifecycle, appendTerminalObservation: true
        )
    }

    private func finalizeExisting(
        _ active: HistoricalChargingSession,
        observation: ChargingSessionObservation,
        configuration: ChargingSessionEngineConfiguration,
        reason: ChargingSessionCompletionReason,
        lifecycle: ChargingSessionLifecycleState,
        appendTerminalObservation: Bool
    ) {
        if appendTerminalObservation { append(observation, to: active.id) }
        let samples = database.chargingSamples(for: active.id)
        let capacity = active.usableCapacityKwh ?? configuration.usableCapacityKwh
        let summary = ChargingSessionSummaryCalculator.calculate(
            startSoc: active.startSoc, terminalSoc: observation.soc,
            startedAt: active.startedAt, endedAt: observation.timestamp,
            samples: samples, usableCapacityKwh: capacity
        )
        guard summary.endSoc > active.startSoc, summary.energyKwh > 0 else {
            database.abandonChargingSession(
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
               let split = HistoryInsights.tariffAwareCost(
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
        database.completeChargingSession(
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

    private func append(_ observation: ChargingSessionObservation, to sessionId: String) {
        database.recordChargingSample(
            sessionId: sessionId, vin: observation.vin, soc: observation.soc,
            powerKw: observation.powerKw, voltage: observation.voltageVolts,
            current: observation.currentAmps, chargingType: observation.chargingType.rawValue,
            timestamp: observation.timestamp
        )
    }
}
