import Foundation

/// The Charging Session ledger — the sole owner of the Charging Session lifecycle.
///
/// Owns every domain read and write over the `charging_sessions` and `charging_samples`
/// tables: `VehicleDatabase` keeps the schema, migrations, and cross-table operations
/// (wipe, prune, backup, counts), but nothing outside this module interprets those two
/// tables. Session summaries are versioned materialized state advanced through explicit
/// lifecycle transitions; sample integration and its gap-tolerance policies live here and
/// nowhere else, so the write-time summary and the read-time estimates can never drift
/// apart in separate integrators.
///
/// `charging_samples` is the append-only observation log. `charging_sessions` is a
/// versioned materialized summary that this ledger advances through explicit states. A
/// one-poll idle or disconnect is only `pendingCompletion`; a second confirms the stop.
/// Paused and scheduled charging keep the physical session open and a new active
/// observation resumes it.
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

struct ChargingSessionLedgerConfiguration: Equatable, Sendable {
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

/// The authoritative summary integration, fed by the ledger's gap policies.
enum ChargingSessionSummaryCalculator {
    /// Gaps longer than this are evidence that Hisingen did not observe the interval and must
    /// not be silently integrated as if the last power value held throughout it. Same constant
    /// as the chart curve's visual gap threshold, so what the summary integrated and what the
    /// curve displays agree by construction.
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

/// Read-time estimate policies tolerate much wider polling gaps than the authoritative
/// summary: a long, slow AC session polled only once an hour is a perfectly ordinary
/// cadence, and discarding its intervals would understate delivered energy for loss and
/// cost purposes (where the estimate is explicitly provisional).
extension ChargingSessionLedger {
    struct TariffCost: Equatable {
        let dayEnergyKwh: Double
        let nightEnergyKwh: Double
        let cost: Double
    }

    /// An interval between consecutive samples longer than this is treated as a polling gap
    /// (e.g. the vehicle was unplugged and replugged elsewhere) rather than continuous
    /// charging, in the read-time estimators below.
    static let maximumEstimateSampleGap: TimeInterval = 3 * 3_600

    /// Splits a session's sample-integrated energy into day/night buckets by each interval's
    /// local hour and prices each bucket separately — materially more accurate than
    /// multiplying total energy by one flat rate once a night tariff is configured, since it
    /// reflects when the energy actually flowed rather than only how much flowed. `nightStart
    /// == nightEnd` disables the night bucket entirely (everything prices at `dayRatePerKwh`).
    static func tariffAwareCost(from samples: [HistoricalChargingSample], dayRatePerKwh: Double,
                                nightRatePerKwh: Double, nightStartHour: Int, nightEndHour: Int,
                                calendar: Calendar = .current) -> TariffCost? {
        let chronological = samples.sorted { $0.timestamp < $1.timestamp }
        guard chronological.count >= 2 else { return nil }
        func isNight(_ date: Date) -> Bool {
            guard nightStartHour != nightEndHour else { return false }
            let hour = calendar.component(.hour, from: date)
            if nightStartHour < nightEndHour {
                return hour >= nightStartHour && hour < nightEndHour
            }
            return hour >= nightStartHour || hour < nightEndHour
        }
        var dayKwh = 0.0
        var nightKwh = 0.0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let interval = b.timestamp.timeIntervalSince(a.timestamp)
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            let energy = (p0 + p1) / 2 * (interval / 3_600)
            let midpoint = a.timestamp.addingTimeInterval(interval / 2)
            if isNight(midpoint) { nightKwh += energy } else { dayKwh += energy }
        }
        guard dayKwh + nightKwh > 0 else { return nil }
        return TariffCost(dayEnergyKwh: dayKwh, nightEnergyKwh: nightKwh,
                          cost: dayKwh * dayRatePerKwh + nightKwh * nightRatePerKwh)
    }

    /// Prices a session against hourly (or quarterly) spot prices, splitting every sample
    /// interval at price-slot boundaries so a rate change inside one polling interval
    /// prices each piece at its own rate (trapezoidal power within the pieces). Requires
    /// the whole charged window to sit inside the price series' coverage — a session that
    /// predates or overruns the available data stays uncosted (`nil`) rather than being
    /// priced with invented rates. The result is scaled to the authoritative session
    /// energy so sparse sampling cannot bias the figure.
    static func spotAwareCost(from samples: [HistoricalChargingSample],
                              prices: [ElectricityPricePoint],
                              sessionStart: Date, sessionEnd: Date,
                              scaleToEnergyKwh authoritativeKwh: Double) -> Double? {
        guard authoritativeKwh > 0, !prices.isEmpty else { return nil }
        let chronological = samples.sorted { $0.timestamp < $1.timestamp }
        guard chronological.count >= 2 else { return nil }
        let orderedPrices = prices.sorted { $0.startDate < $1.startDate }
        guard let firstPriceStart = orderedPrices.first?.startDate,
              let lastPriceEnd = orderedPrices.last?.endDate,
              sessionStart >= firstPriceStart, sessionEnd <= lastPriceEnd else { return nil }
        var integratedKwh = 0.0
        var cost = 0.0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let intervalStart = a.timestamp
            let interval = b.timestamp.timeIntervalSince(intervalStart)
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            let intervalEnd = b.timestamp
            var cursor = intervalStart
            while cursor < intervalEnd {
                guard let slot = orderedPrices.first(where: {
                    $0.startDate <= cursor && cursor < $0.endDate
                }) else { return nil }
                let sliceEnd = min(slot.endDate, intervalEnd)
                let seconds = sliceEnd.timeIntervalSince(cursor)
                if seconds > 0 {
                    let fraction = seconds / interval
                    let offsetAtCursor = cursor.timeIntervalSince(intervalStart) / interval
                    let powerAtCursor = p0 + (p1 - p0) * offsetAtCursor
                    let powerAtSliceEnd = p0 + (p1 - p0) * (offsetAtCursor + fraction)
                    let energy = (powerAtCursor + powerAtSliceEnd) / 2 * (seconds / 3_600)
                    integratedKwh += energy
                    cost += energy * slot.sekPerKwh
                }
                cursor = sliceEnd
            }
        }
        guard integratedKwh > 0 else { return nil }
        return cost * authoritativeKwh / integratedKwh
    }

    /// Estimated round-trip loss between what the charger delivered and what actually landed
    /// as usable state of charge: integrated sample power (trapezoidal, skipping any interval
    /// that spans a polling gap) compared against SoC-gain × pack capacity. Returns `nil`
    /// rather than a fabricated figure whenever the inputs can't support a plausible estimate.
    static func estimatedChargingLossPct(from samples: [HistoricalChargingSample],
                                         packCapacityKwh: Double) -> Double? {
        guard packCapacityKwh > 0 else { return nil }
        let chronological = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = chronological.first, let last = chronological.last,
              last.soc > first.soc else { return nil }
        var energyInputKwh = 0.0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let interval = b.timestamp.timeIntervalSince(a.timestamp)
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            energyInputKwh += (p0 + p1) / 2 * (interval / 3_600)
        }
        guard energyInputKwh > 0 else { return nil }
        let storedKwh = packCapacityKwh * (last.soc - first.soc) / 100
        let lossPct = (1 - storedKwh / energyInputKwh) * 100
        return (0...40).contains(lossPct) ? lossPct : nil
    }
}

final class ChargingSessionLedger: Sendable {
    static let requiredStopObservations = 2
    static let maximumContinuityGap: TimeInterval = 48 * 60 * 60

    private let sql: SQLiteDatabase

    init(sql: SQLiteDatabase) {
        self.sql = sql
    }

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
            appendSample(observation, to: active.id)
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

    // MARK: - Session and sample reads

    func activeChargingSession(for vin: String) -> HistoricalChargingSession? {
        let query = """
        SELECT \(Self.chargingSessionColumns)
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NULL
          AND lifecycle_state IN ('active', 'paused', 'pending_completion')
        ORDER BY started_at DESC LIMIT 1;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt -> HistoricalChargingSession? in
            guard stmt.step() else { return nil }
            return Self.sessionRow(from: stmt, endedAt: nil, endSoc: nil, energy: nil,
                                   peak: nil, average: nil, location: nil)
        }) ?? nil
    }

    /// Completed sessions for a VIN with a real SoC gain or recorded energy, newest first.
    func recentChargingSessions(for vin: String, limit: Int = 20) -> [HistoricalChargingSession] {
        let query = """
        SELECT \(Self.chargingSessionColumns)
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NOT NULL
          AND lifecycle_state IN ('completed', 'interrupted')
          AND (
            end_soc > start_soc OR energy_delivered_kwh > 0 OR EXISTS (
              SELECT 1 FROM charging_samples
              WHERE charging_samples.session_id = charging_sessions.id
                AND charging_samples.soc > charging_sessions.start_soc
            )
          )
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [HistoricalChargingSession] in
            var list: [HistoricalChargingSession] = []
            while stmt.step() {
                guard let session = Self.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                    endSoc: stmt.columnDouble(at: 5),
                                                    energy: stmt.columnDouble(at: 6),
                                                    peak: stmt.columnDouble(at: 7),
                                                    average: stmt.columnDouble(at: 8),
                                                    location: stmt.columnText(at: 9)) else { continue }
                list.append(session)
            }
            return list
        }) ?? []
    }

    /// Completed sessions that have no spot-price cost yet, newest first. Bounded so a
    /// backfill pass over a long history stays a bounded read.
    func sessionsMissingSpotCost(vin: String, limit: Int = 400) -> [HistoricalChargingSession] {
        let query = """
        SELECT \(Self.chargingSessionColumns)
        FROM charging_sessions
        WHERE vin = ? AND ended_at IS NOT NULL
          AND spot_estimated_cost IS NULL AND energy_delivered_kwh > 0
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt -> [HistoricalChargingSession] in
            var list: [HistoricalChargingSession] = []
            while stmt.step() {
                guard let session = Self.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                    endSoc: stmt.columnDouble(at: 5),
                                                    energy: stmt.columnDouble(at: 6),
                                                    peak: stmt.columnDouble(at: 7),
                                                    average: stmt.columnDouble(at: 8),
                                                    location: stmt.columnText(at: 9)) else { continue }
                list.append(session)
            }
            return list
        }) ?? []
    }

    func updateSpotEstimatedCost(id: String, cost: Double) {
        try? sql.query(sql: "UPDATE charging_sessions SET spot_estimated_cost = ? WHERE id = ?;") { stmt in
            try stmt.bindDouble(cost, at: 1)
            try stmt.bindText(id, at: 2)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    /// Computes spot costs for every uncosted completed session the price series fully
    /// covers, writing each result once. Sessions outside the price coverage stay untouched
    /// so a later pass with a wider series can still price them. Returns the update count.
    @discardableResult
    func backfillSpotEstimatedCosts(vin: String, prices: [ElectricityPricePoint]) -> Int {
        guard !prices.isEmpty else { return 0 }
        var updated = 0
        for session in sessionsMissingSpotCost(vin: vin) {
            guard let endedAt = session.endedAt else { continue }
            let samples = chargingSamples(for: session.id)
            guard samples.count >= 2 else { continue }
            guard let cost = Self.spotAwareCost(
                from: samples, prices: prices,
                sessionStart: session.startedAt, sessionEnd: endedAt,
                scaleToEnergyKwh: session.energyDeliveredKwh
            ) else { continue }
            updateSpotEstimatedCost(id: session.id, cost: cost)
            updated += 1
        }
        return updated
    }

    func chargingSamples(for sessionId: String) -> [HistoricalChargingSample] {
        let query = """
        SELECT id, session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type
        FROM charging_samples WHERE session_id = ? ORDER BY timestamp ASC;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(sessionId, at: 1)
        } process: { stmt -> [HistoricalChargingSample] in
            var list: [HistoricalChargingSample] = []
            while stmt.step() {
                guard let id = stmt.columnInt64(at: 0),
                      let sess = stmt.columnText(at: 1),
                      let vin = stmt.columnText(at: 2),
                      let ts = stmt.columnDate(at: 3),
                      let soc = stmt.columnDouble(at: 4) else { continue }
                list.append(HistoricalChargingSample(
                    id: id, sessionId: sess, vin: vin, timestamp: ts, soc: soc,
                    powerKw: stmt.columnDouble(at: 5),
                    voltageVolts: stmt.columnDouble(at: 6),
                    currentAmps: stmt.columnDouble(at: 7),
                    chargingType: stmt.columnText(at: 8)
                ))
            }
            return list
        }) ?? []
    }

    /// Lifetime charging energy for a VIN across all stored sessions (kWh).
    func lifetimeChargingEnergyKwh(for vin: String) -> Double {
        var total = 0.0
        try? sql.query(sql: "SELECT COALESCE(SUM(energy_delivered_kwh),0) FROM charging_sessions WHERE vin = ? AND lifecycle_state IN ('completed', 'interrupted');", bindings: { stmt in
            try stmt.bindText(vin, at: 1)
        }, process: { stmt in
            if stmt.step() { total = stmt.columnDouble(at: 0) ?? 0 }
        })
        return total
    }

    /// Peak power history for prior sessions at the same named location (newest excluded by
    /// the caller passing its id), oldest-first — the baseline for anomaly detection.
    func priorSessionPeaks(vin: String, locationName: String,
                           excludingSessionID: String, limit: Int = 10) -> [Double] {
        guard !locationName.isEmpty else { return [] }
        let query = """
        SELECT peak_power_kw FROM charging_sessions
        WHERE vin = ? AND location_name = ? AND id != ? AND peak_power_kw > 0
          AND lifecycle_state IN ('completed', 'interrupted')
        ORDER BY started_at DESC LIMIT ?;
        """
        return (try? sql.query(sql: query) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindText(locationName, at: 2)
            try stmt.bindText(excludingSessionID, at: 3)
            try stmt.bindInt64(Int64(limit), at: 4)
        } process: { stmt -> [Double] in
            var out: [Double] = []
            while stmt.step(), let v = stmt.columnDouble(at: 0) { out.append(v) }
            return out
        }) ?? []
    }

    // MARK: - Record conversions

    /// Converts the durable summary and its samples into one internally consistent domain
    /// session.
    ///
    /// Older builds could finalize a header with a stale end SoC, or retain a header boundary
    /// that was absent from the bounded chart sample list. Treat the header start and the
    /// greatest observed final SoC as authoritative, synthesize missing boundary samples, and
    /// recover a zero energy estimate when a usable-capacity reference is available.
    func domainSession(from record: HistoricalChargingSession,
                       usableCapacityKwh: Double? = nil) -> ChargingSession {
        let samples = reconciledSamples(for: record).map {
            ChargingSample(
                timestamp: $0.timestamp,
                batteryPercentage: $0.soc,
                powerWatts: $0.powerKw.map { Int($0 * 1000.0) },
                chargingType: $0.chargingType.flatMap(ChargingType.init(rawValue:)) ?? .unknown
            )
        }

        let observedEndSoc = samples.last?.batteryPercentage ?? record.startSoc
        let resolvedEndSoc = max(record.startSoc, max(record.endSoc ?? record.startSoc, observedEndSoc))
        let resolvedEndDate = max(record.endedAt ?? record.startedAt,
                                  samples.last?.timestamp ?? record.startedAt)
        let percentageAdded = max(0, resolvedEndSoc - record.startSoc)
        let resolvedEnergy: Double = {
            if record.energyDeliveredKwh > 0 { return record.energyDeliveredKwh }
            guard let usableCapacityKwh, usableCapacityKwh > 0, percentageAdded > 0 else { return 0 }
            return percentageAdded / 100 * usableCapacityKwh
        }()
        return ChargingSession(
            id: UUID(uuidString: record.id) ?? UUID(), vin: record.vin,
            startDate: record.startedAt, endDate: resolvedEndDate,
            startBatteryPercentage: record.startSoc, endBatteryPercentage: resolvedEndSoc,
            kwhDelivered: resolvedEnergy,
            peakPowerWatts: record.peakPowerKw > 0 ? Int(record.peakPowerKw * 1000.0) : nil,
            cost: record.estimatedCost,
            targetPercentage: record.targetSoc.map { Int($0.rounded()) }, samples: samples,
            energySource: record.energySource, confidence: record.confidence,
            sampleCoverage: record.sampleCoverage, tariffPricePerKwh: record.tariffPricePerKwh,
            currencySymbol: record.currencySymbol, completionReason: record.completionReason,
            summaryVersion: record.summaryVersion, spotCost: record.spotEstimatedCost
        )
    }

    /// Repaired curve for a stored session: synthesizes missing start/end boundary samples so
    /// the curve always begins at the header's start SoC and ends at the resolved end.
    /// Historical-dashboard representation of the same repaired curve used by the vehicle
    /// card, while retaining voltage/current fields that the domain chart does not carry.
    func reconciledSamples(for record: HistoricalChargingSession) -> [HistoricalChargingSample] {
        var samples = chargingSamples(for: record.id).sorted { $0.timestamp < $1.timestamp }
        let startSample = HistoricalChargingSample(
            id: .min, sessionId: record.id, vin: record.vin, timestamp: record.startedAt,
            soc: record.startSoc, powerKw: nil, voltageVolts: nil, currentAmps: nil,
            chargingType: nil
        )
        if let first = samples.first {
            if abs(first.timestamp.timeIntervalSince(record.startedAt)) > 1
                || abs(first.soc - record.startSoc) > 0.01 {
                samples.insert(startSample, at: 0)
            }
        } else {
            samples = [startSample]
        }

        guard let endedAt = record.endedAt, let last = samples.last else { return samples }
        let resolvedEndDate = max(endedAt, last.timestamp)
        let resolvedEndSoc = max(record.startSoc, max(record.endSoc ?? record.startSoc, last.soc))
        if abs(last.timestamp.timeIntervalSince(resolvedEndDate)) > 1
            || abs(last.soc - resolvedEndSoc) > 0.01 {
            samples.append(HistoricalChargingSample(
                id: .max, sessionId: record.id, vin: record.vin,
                timestamp: resolvedEndDate, soc: resolvedEndSoc, powerKw: nil,
                voltageVolts: nil, currentAmps: nil, chargingType: nil
            ))
        }
        return samples
    }

    /// Repairs zero-value legacy summaries in memory for aggregate dashboard statistics.
    /// Normal rows return without querying their sample table.
    func reconciled(_ record: HistoricalChargingSession,
                    usableCapacityKwh: Double) -> HistoricalChargingSession {
        guard record.endedAt != nil,
              record.energyDeliveredKwh <= 0 || (record.endSoc ?? record.startSoc) <= record.startSoc
        else { return record }
        let samples = reconciledSamples(for: record)
        let resolvedEndSoc = max(record.startSoc,
                                 max(record.endSoc ?? record.startSoc, samples.last?.soc ?? record.startSoc))
        let percentageAdded = max(0, resolvedEndSoc - record.startSoc)
        guard percentageAdded > 0, usableCapacityKwh > 0 else { return record }
        let powers = samples.compactMap(\.powerKw)
        return HistoricalChargingSession(
            id: record.id, vin: record.vin, startedAt: record.startedAt,
            endedAt: max(record.endedAt ?? record.startedAt,
                         samples.last?.timestamp ?? record.startedAt),
            startSoc: record.startSoc, endSoc: resolvedEndSoc,
            energyDeliveredKwh: percentageAdded / 100 * usableCapacityKwh,
            peakPowerKw: max(record.peakPowerKw, powers.max() ?? 0),
            averagePowerKw: powers.isEmpty ? record.averagePowerKw
                : powers.reduce(0, +) / Double(powers.count),
            locationName: record.locationName, createdAt: record.createdAt,
            lifecycleState: record.lifecycleState, completionReason: record.completionReason,
            energySource: record.energySource, confidence: record.confidence,
            sampleCoverage: record.sampleCoverage,
            usableCapacityKwh: usableCapacityKwh, tariffPricePerKwh: record.tariffPricePerKwh,
            nightTariffEnabled: record.nightTariffEnabled,
            nightTariffPricePerKwh: record.nightTariffPricePerKwh,
            nightTariffStartHour: record.nightTariffStartHour,
            nightTariffEndHour: record.nightTariffEndHour,
            currencySymbol: record.currencySymbol, targetSoc: record.targetSoc,
            lastObservedAt: record.lastObservedAt, summaryVersion: record.summaryVersion,
            pendingStopCount: record.pendingStopCount, estimatedCost: record.estimatedCost
        )
    }

    // MARK: - Legacy reconciliation

    /// VINs that still carry at least one completed session whose stored summary is stale or
    /// zero-valued. Enumerated once per launch so reconciliation does not re-scan on every
    /// snapshot.
    func legacySummaryVINs() -> [String] {
        let query = """
        SELECT DISTINCT vin FROM charging_sessions
        WHERE ended_at IS NOT NULL
          AND lifecycle_state IN ('completed', 'interrupted')
          AND (end_soc <= start_soc OR energy_delivered_kwh <= 0)
        ORDER BY vin;
        """
        return (try? sql.query(sql: query) { _ in } process: { stmt -> [String] in
            var list: [String] = []
            while stmt.step(), let vin = stmt.columnText(at: 0) { list.append(vin) }
            return list
        }) ?? []
    }

    /// Repairs completed rows written by older builds with a stale/zero final summary. The
    /// operation is idempotent and only touches rows whose retained samples prove a real
    /// gain. Rows keep the usable capacity they were written with; the provided capacity
    /// (from the caller's current preference state) is only the fallback for rows that never
    /// stored one. Run once per launch from the store, not per snapshot.
    func reconcileLegacySummaries(for vin: String, usableCapacityKwh: Double?) {
        let candidates = recentChargingSessions(for: vin, limit: 1_000).filter {
            $0.energyDeliveredKwh <= 0 || ($0.endSoc ?? $0.startSoc) <= $0.startSoc
        }
        for candidate in candidates {
            let capacity = candidate.usableCapacityKwh ?? usableCapacityKwh ?? 0
            guard capacity > 0 else { continue }
            let repaired = reconciled(candidate, usableCapacityKwh: capacity)
            guard repaired.energyDeliveredKwh > 0,
                  let endSoc = repaired.endSoc, endSoc > repaired.startSoc else { continue }
            try? sql.query(sql: """
                UPDATE charging_sessions SET
                    end_soc = ?, energy_delivered_kwh = ?,
                    peak_power_kw = ?, average_power_kw = ?
                WHERE id = ? AND ended_at IS NOT NULL;
                """) { stmt in
                try stmt.bindDouble(endSoc, at: 1)
                try stmt.bindDouble(repaired.energyDeliveredKwh, at: 2)
                try stmt.bindDouble(repaired.peakPowerKw, at: 3)
                try stmt.bindDouble(repaired.averagePowerKw, at: 4)
                try stmt.bindText(repaired.id, at: 5)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    // MARK: - Exporters

    func exportChargingSessionsCSV(for vin: String? = nil) -> String {
        let sessions: [HistoricalChargingSession]
        if let vin {
            sessions = recentChargingSessions(for: vin, limit: 1000)
        } else {
            let query = """
            SELECT \(Self.chargingSessionColumns)
            FROM charging_sessions
            WHERE ended_at IS NOT NULL
              AND lifecycle_state IN ('completed', 'interrupted')
              AND (end_soc > start_soc OR energy_delivered_kwh > 0)
            ORDER BY started_at DESC LIMIT 1000;
            """
            sessions = (try? sql.query(sql: query) { _ in } process: { stmt -> [HistoricalChargingSession] in
                var list: [HistoricalChargingSession] = []
                while stmt.step() {
                    guard let session = Self.sessionRow(from: stmt, endedAt: stmt.columnDate(at: 3),
                                                        endSoc: stmt.columnDouble(at: 5),
                                                        energy: stmt.columnDouble(at: 6),
                                                        peak: stmt.columnDouble(at: 7),
                                                        average: stmt.columnDouble(at: 8),
                                                        location: stmt.columnText(at: 9)) else { continue }
                    list.append(session)
                }
                return list
            }) ?? []
        }

        var csv = "Session ID,VIN,Started At,Ended At,Start SoC (%),End SoC (%),Estimated Energy Added (kWh),Observed Peak Power (kW),Sample Average Power (kW),Location,Lifecycle,Completion Reason,Energy Source,Confidence,Sample Coverage,Usable Capacity (kWh),Day Tariff,Night Tariff Enabled,Night Tariff,Night Start Hour,Night End Hour,Estimated Cost,Currency,Target SoC,Summary Version\n"
        let df = ISO8601DateFormatter()
        for s in sessions {
            let start = df.string(from: s.startedAt)
            let end = s.endedAt.map { df.string(from: $0) } ?? ""
            let endSoc = s.endSoc.map { String(format: "%.1f", $0) } ?? ""
            let loc = (s.locationName ?? "").replacingOccurrences(of: ",", with: " ")
            let coverage = s.sampleCoverage.map { String(format: "%.3f", $0) } ?? ""
            let capacity = s.usableCapacityKwh.map { String(format: "%.2f", $0) } ?? ""
            let tariff = s.tariffPricePerKwh.map { String(format: "%.4f", $0) } ?? ""
            let nightTariff = s.nightTariffPricePerKwh.map { String(format: "%.4f", $0) } ?? ""
            let nightStart = s.nightTariffStartHour.map(String.init) ?? ""
            let nightEnd = s.nightTariffEndHour.map(String.init) ?? ""
            let cost = s.estimatedCost.map { String(format: "%.2f", $0) } ?? ""
            let target = s.targetSoc.map { String(format: "%.1f", $0) } ?? ""
            csv += "\(s.id),\(s.vin),\(start),\(end),\(String(format: "%.1f", s.startSoc)),\(endSoc),\(String(format: "%.2f", s.energyDeliveredKwh)),\(String(format: "%.1f", s.peakPowerKw)),\(String(format: "%.1f", s.averagePowerKw)),\(loc),\(s.lifecycleState.rawValue),\(s.completionReason?.rawValue ?? ""),\(s.energySource.rawValue),\(s.confidence.rawValue),\(coverage),\(capacity),\(tariff),\(s.nightTariffEnabled),\(nightTariff),\(nightStart),\(nightEnd),\(cost),\(s.currencySymbol ?? ""),\(target),\(s.summaryVersion)\n"
        }
        return csv
    }

    /// Raw per-sample export for one charging session — the curve data exactly as recorded,
    /// for third-party analysis or debugging a misshapen curve.
    func exportChargingSamplesCSV(sessionID: String) -> String {
        let samples = chargingSamples(for: sessionID)
        let formatter = ISO8601DateFormatter()
        var csv = "Timestamp,SOC (%),Power (kW),Voltage (V),Current (A)\n"
        for sample in samples {
            func cell(_ value: Double?) -> String { value.map { String(format: "%.2f", $0) } ?? "" }
            csv += "\(formatter.string(from: sample.timestamp)),\(String(format: "%.1f", sample.soc)),\(cell(sample.powerKw)),\(cell(sample.voltageVolts)),\(cell(sample.currentAmps))\n"
        }
        return csv
    }

    // MARK: - Session storage

    @discardableResult
    func startChargingSession(id: String = UUID().uuidString, vin: String, startSoc: Double,
                              location: String? = nil, startedAt: Date = Date(),
                              usableCapacityKwh: Double? = nil,
                              tariffPricePerKwh: Double? = nil,
                              nightTariffEnabled: Bool = false,
                              nightTariffPricePerKwh: Double? = nil,
                              nightTariffStartHour: Int? = nil,
                              nightTariffEndHour: Int? = nil,
                              currencySymbol: String? = nil,
                              targetSoc: Double? = nil,
                              lifecycleState: ChargingSessionLifecycleState = .active) -> String {
        let statement = """
        INSERT INTO charging_sessions (
            id, vin, started_at, start_soc, energy_delivered_kwh, peak_power_kw,
            average_power_kw, location_name, created_at, lifecycle_state, energy_source,
            confidence, usable_capacity_kwh, tariff_price_per_kwh, currency_symbol,
            night_tariff_enabled, night_tariff_price_per_kwh,
            night_tariff_start_hour, night_tariff_end_hour, target_soc,
            last_observed_at, summary_version, pending_stop_count
        ) VALUES (?, ?, ?, ?, 0.0, 0.0, 0.0, ?, ?, ?, 'soc_capacity_estimate',
                  'low', ?, ?, ?, ?, ?, ?, ?, ?, ?, 2, 0);
        """
        try? sql.query(sql: statement) { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(startedAt, at: 3)
            try stmt.bindDouble(startSoc, at: 4)
            try stmt.bindText(location, at: 5)
            try stmt.bindDate(startedAt, at: 6)
            try stmt.bindText(lifecycleState.rawValue, at: 7)
            try stmt.bindDouble(usableCapacityKwh, at: 8)
            try stmt.bindDouble(tariffPricePerKwh, at: 9)
            try stmt.bindText(currencySymbol, at: 10)
            try stmt.bindInt64(nightTariffEnabled ? 1 : 0, at: 11)
            try stmt.bindDouble(nightTariffPricePerKwh, at: 12)
            try stmt.bindInt64(nightTariffStartHour.map(Int64.init), at: 13)
            try stmt.bindInt64(nightTariffEndHour.map(Int64.init), at: 14)
            try stmt.bindDouble(targetSoc, at: 15)
            try stmt.bindDate(startedAt, at: 16)
            try stmt.executeUpdate()
        } process: { _ in }
        return id
    }

    func recordChargingSample(sessionId: String, vin: String, soc: Double,
                              powerKw: Double?, voltage: Double?, current: Double?,
                              chargingType: String? = nil, timestamp: Date = Date()) {
        let statement = """
        INSERT INTO charging_samples (session_id, vin, timestamp, soc, power_kw, voltage_volts, current_amps, charging_type)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
        """
        try? sql.query(sql: statement) { stmt in
            try stmt.bindText(sessionId, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.bindDate(timestamp, at: 3)
            try stmt.bindDouble(soc, at: 4)
            try stmt.bindDouble(powerKw, at: 5)
            try stmt.bindDouble(voltage, at: 6)
            try stmt.bindDouble(current, at: 7)
            try stmt.bindText(chargingType, at: 8)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func completeChargingSession(id: String, endSoc: Double, energyDeliveredKwh: Double,
                                 peakPowerKw: Double, averagePowerKw: Double,
                                 endedAt: Date = Date(),
                                 lifecycleState: ChargingSessionLifecycleState = .completed,
                                 completionReason: ChargingSessionCompletionReason = .stopped,
                                 energySource: ChargingSessionEnergySource = .socCapacityEstimate,
                                 confidence: ChargingSessionConfidence = .low,
                                 usableCapacityKwh: Double? = nil,
                                 tariffPricePerKwh: Double? = nil,
                                 nightTariffEnabled: Bool = false,
                                 nightTariffPricePerKwh: Double? = nil,
                                 nightTariffStartHour: Int? = nil,
                                 nightTariffEndHour: Int? = nil,
                                 currencySymbol: String? = nil,
                                 targetSoc: Double? = nil,
                                 sampleCoverage: Double? = nil,
                                 estimatedCost: Double? = nil) {
        let statement = """
        UPDATE charging_sessions SET
            ended_at = ?,
            end_soc = ?,
            energy_delivered_kwh = ?,
            peak_power_kw = ?,
            average_power_kw = ?, lifecycle_state = ?, completion_reason = ?,
            energy_source = ?, confidence = ?,
            sample_coverage = ?,
            usable_capacity_kwh = COALESCE(?, usable_capacity_kwh),
            tariff_price_per_kwh = COALESCE(?, tariff_price_per_kwh),
            night_tariff_enabled = ?,
            night_tariff_price_per_kwh = COALESCE(?, night_tariff_price_per_kwh),
            night_tariff_start_hour = COALESCE(?, night_tariff_start_hour),
            night_tariff_end_hour = COALESCE(?, night_tariff_end_hour),
            currency_symbol = COALESCE(?, currency_symbol),
            target_soc = COALESCE(?, target_soc), last_observed_at = ?,
            summary_version = 2, pending_stop_count = 0,
            estimated_cost = ?
        WHERE id = ?;
        """
        try? sql.query(sql: statement) { stmt in
            try stmt.bindDate(endedAt, at: 1)
            try stmt.bindDouble(endSoc, at: 2)
            try stmt.bindDouble(energyDeliveredKwh, at: 3)
            try stmt.bindDouble(peakPowerKw, at: 4)
            try stmt.bindDouble(averagePowerKw, at: 5)
            try stmt.bindText(lifecycleState.rawValue, at: 6)
            try stmt.bindText(completionReason.rawValue, at: 7)
            try stmt.bindText(energySource.rawValue, at: 8)
            try stmt.bindText(confidence.rawValue, at: 9)
            try stmt.bindDouble(sampleCoverage, at: 10)
            try stmt.bindDouble(usableCapacityKwh, at: 11)
            try stmt.bindDouble(tariffPricePerKwh, at: 12)
            try stmt.bindInt64(nightTariffEnabled ? 1 : 0, at: 13)
            try stmt.bindDouble(nightTariffPricePerKwh, at: 14)
            try stmt.bindInt64(nightTariffStartHour.map(Int64.init), at: 15)
            try stmt.bindInt64(nightTariffEndHour.map(Int64.init), at: 16)
            try stmt.bindText(currencySymbol, at: 17)
            try stmt.bindDouble(targetSoc, at: 18)
            try stmt.bindDate(endedAt, at: 19)
            try stmt.bindDouble(estimatedCost, at: 20)
            try stmt.bindText(id, at: 21)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func updateChargingSessionLifecycle(
        id: String, state: ChargingSessionLifecycleState, observedAt: Date,
        pendingStopCount: Int, targetSoc: Double?
    ) {
        try? sql.query(sql: """
            UPDATE charging_sessions SET lifecycle_state = ?, last_observed_at = ?,
                pending_stop_count = ?, target_soc = COALESCE(?, target_soc)
            WHERE id = ? AND ended_at IS NULL;
            """) { stmt in
            try stmt.bindText(state.rawValue, at: 1)
            try stmt.bindDate(observedAt, at: 2)
            try stmt.bindInt64(Int64(max(0, pendingStopCount)), at: 3)
            try stmt.bindDouble(targetSoc, at: 4)
            try stmt.bindText(id, at: 5)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    func abandonChargingSession(id: String, endedAt: Date,
                                reason: ChargingSessionCompletionReason) {
        try? sql.query(sql: """
            UPDATE charging_sessions SET ended_at = ?, lifecycle_state = 'abandoned',
                completion_reason = ?, last_observed_at = ?, pending_stop_count = 0,
                summary_version = 2
            WHERE id = ? AND ended_at IS NULL;
            """) { stmt in
            try stmt.bindDate(endedAt, at: 1)
            try stmt.bindText(reason.rawValue, at: 2)
            try stmt.bindDate(endedAt, at: 3)
            try stmt.bindText(id, at: 4)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    /// Removes an unfinished observation that never produced a measurable SoC gain. Keeping
    /// these rows made an interrupted poll look like a completed 0 kWh / 0 cost charge.
    func discardChargingSession(id: String) {
        try? sql.withTransaction {
            try sql.query(sql: "DELETE FROM charging_samples WHERE session_id = ?;") { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
            try sql.query(sql: "DELETE FROM charging_sessions WHERE id = ? AND ended_at IS NULL;") { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }

    // MARK: - Row mapping

    /// Shared column mapping for the `charging_sessions` SELECT shape used by every session
    /// query (previously duplicated in four readers with drift risk).
    private static func sessionRow(from stmt: SQLiteStatement,
                                   endedAt: Date?, endSoc: Double?, energy: Double?,
                                   peak: Double?, average: Double?, location: String?) -> HistoricalChargingSession? {
        guard let id = stmt.columnText(at: 0),
              let vin = stmt.columnText(at: 1),
              let startedAt = stmt.columnDate(at: 2),
              let startSoc = stmt.columnDouble(at: 4),
              let createdAt = stmt.columnDate(at: 10) else { return nil }
        return HistoricalChargingSession(
            id: id, vin: vin, startedAt: startedAt, endedAt: endedAt,
            startSoc: startSoc, endSoc: endSoc ?? stmt.columnDouble(at: 5),
            energyDeliveredKwh: energy ?? (stmt.columnDouble(at: 6) ?? 0.0),
            peakPowerKw: peak ?? (stmt.columnDouble(at: 7) ?? 0.0),
            averagePowerKw: average ?? (stmt.columnDouble(at: 8) ?? 0.0),
            locationName: location ?? stmt.columnText(at: 9), createdAt: createdAt,
            lifecycleState: stmt.columnText(at: 11).flatMap(ChargingSessionLifecycleState.init(rawValue:))
                ?? (endedAt == nil ? .active : .completed),
            completionReason: stmt.columnText(at: 12).flatMap(ChargingSessionCompletionReason.init(rawValue:)),
            energySource: stmt.columnText(at: 13).flatMap(ChargingSessionEnergySource.init(rawValue:)) ?? .legacyEstimate,
            confidence: stmt.columnText(at: 14).flatMap(ChargingSessionConfidence.init(rawValue:)) ?? .low,
            sampleCoverage: stmt.columnDouble(at: 15),
            usableCapacityKwh: stmt.columnDouble(at: 16),
            tariffPricePerKwh: stmt.columnDouble(at: 17),
            nightTariffEnabled: (stmt.columnInt64(at: 18) ?? 0) != 0,
            nightTariffPricePerKwh: stmt.columnDouble(at: 19),
            nightTariffStartHour: stmt.columnInt64(at: 20).map(Int.init),
            nightTariffEndHour: stmt.columnInt64(at: 21).map(Int.init),
            currencySymbol: stmt.columnText(at: 22),
            targetSoc: stmt.columnDouble(at: 23),
            lastObservedAt: stmt.columnDate(at: 24),
            summaryVersion: Int(stmt.columnInt64(at: 25) ?? 1),
            pendingStopCount: Int(stmt.columnInt64(at: 26) ?? 0),
            estimatedCost: stmt.columnDouble(at: 27),
            spotEstimatedCost: stmt.columnDouble(at: 28)
        )
    }

    private static let chargingSessionColumns = """
        id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
        peak_power_kw, average_power_kw, location_name, created_at, lifecycle_state,
        completion_reason, energy_source, confidence, sample_coverage,
        usable_capacity_kwh, tariff_price_per_kwh, night_tariff_enabled,
        night_tariff_price_per_kwh, night_tariff_start_hour, night_tariff_end_hour,
        currency_symbol, target_soc, last_observed_at, summary_version,
        pending_stop_count, estimated_cost, spot_estimated_cost
        """
}
