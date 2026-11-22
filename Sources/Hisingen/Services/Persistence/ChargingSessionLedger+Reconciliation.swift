import Foundation

extension ChargingSessionLedger {
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
        // Display the observed end even when balancing erased gain; energy math below
        // still clamps negative gain to zero so a SoC drop never becomes negative kWh.
        let resolvedEndSoc = max(record.endSoc ?? observedEndSoc, observedEndSoc)
        let resolvedEndDate = Self.resolvedEndDate(
            reported: record.endedAt ?? record.startedAt,
            observed: samples.last?.timestamp ?? record.startedAt,
            now: Date()
        )
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
            summaryVersion: record.summaryVersion, spotCost: record.spotEstimatedCost,
            wallbox: record.wallbox
        )
    }

    /// Repaired curve for a stored session: synthesizes missing start/end boundary samples so
    /// the curve always begins at the header's start SoC and ends at the resolved end.
    /// Historical-dashboard representation of the same repaired curve used by the vehicle
    /// card, while retaining voltage/current fields that the domain chart does not carry.
    func reconciledSamples(for record: HistoricalChargingSession) -> [HistoricalChargingSample] {
        // A session the charger recorded without any battery reading has no curve to repair.
        guard record.startSoc >= 0 else { return [] }
        var samples = chargingSamples(for: record.id).sorted { $0.timestamp < $1.timestamp }
        // Synthetic boundaries inherit the nearest real power so cost/summary integration
        // does not drop the first/last real intervals (nil power intervals are skipped).
        let nearestStartPower = samples.first?.powerKw
        let startSample = HistoricalChargingSample(
            id: .min, sessionId: record.id, vin: record.vin, timestamp: record.startedAt,
            soc: record.startSoc, powerKw: nearestStartPower, voltageVolts: nil, currentAmps: nil,
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
        let resolvedEndDate = Self.resolvedEndDate(reported: endedAt, observed: last.timestamp, now: Date())
        let observedEndSoc = max(record.endSoc ?? last.soc, last.soc)
        if abs(last.timestamp.timeIntervalSince(resolvedEndDate)) > 1
            || abs(last.soc - observedEndSoc) > 0.01 {
            samples.append(HistoricalChargingSample(
                id: .max, sessionId: record.id, vin: record.vin,
                timestamp: resolvedEndDate, soc: observedEndSoc, powerKw: last.powerKw,
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
            endedAt: Self.resolvedEndDate(
                reported: record.endedAt ?? record.startedAt,
                observed: samples.last?.timestamp ?? record.startedAt,
                now: Date()
            ),
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

    static func resolvedEndDate(reported: Date, observed: Date, now: Date) -> Date {
        let latestPlausibleDate = now.addingTimeInterval(5 * 60)
        return max(reported > latestPlausibleDate ? now : reported,
                   observed > latestPlausibleDate ? now : observed)
    }

    // MARK: - Legacy reconciliation

    /// Rows whose energy was integrated over part of the session only. See
    /// `ChargingSessionSummaryCalculator.undercountRatio`.
    static let undercountedPredicate = "(energy_source = 'observed_power_integration' AND sample_coverage < 0.9)"

    /// Recomputes the energy of finished sessions that an older build integrated over 70 to 90% of
    /// the time and stored as if it were all of it. A row changes only when the current calculation
    /// prefers the charge-level estimate; the stored costs follow the energy, and the market-price
    /// cost is cleared so the next backfill prices the corrected figure. Idempotent.
    func repairUndercountedIntegrations(for vin: String, usableCapacityKwh: Double?) {
        let rows = recentChargingSessions(for: vin, limit: 1_000).filter {
            $0.energySource == .observedPowerIntegration && $0.endedAt != nil
                && ($0.sampleCoverage ?? 1) < ChargingSessionSummaryCalculator.partialCoverageLimit
        }
        for row in rows {
            guard let endedAt = row.endedAt, let capacity = row.usableCapacityKwh ?? usableCapacityKwh, capacity > 0 else { continue }
            let summary = ChargingSessionSummaryCalculator.calculate(
                startSoc: row.startSoc, terminalSoc: row.endSoc ?? row.startSoc, startedAt: row.startedAt, endedAt: endedAt,
                samples: reconciledSamples(for: row), usableCapacityKwh: capacity)
            guard summary.source == .socCapacityEstimate, summary.energyKwh > row.energyDeliveredKwh else { continue }
            let ratio = row.energyDeliveredKwh > 0 ? summary.energyKwh / row.energyDeliveredKwh : 1
            logOnFailure("session undercount repair") {
                try sql.query(sql: """
                    UPDATE charging_sessions SET
                        energy_delivered_kwh = ?, energy_source = 'soc_capacity_estimate', confidence = ?,
                        estimated_cost = estimated_cost * ?, spot_estimated_cost = NULL
                    WHERE id = ? AND ended_at IS NOT NULL;
                    """) { stmt in
                    try stmt.bindDouble(summary.energyKwh, at: 1)
                    try stmt.bindText(summary.confidence.rawValue, at: 2)
                    try stmt.bindDouble(ratio, at: 3)
                    try stmt.bindText(row.id, at: 4)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        }
    }

    /// VINs that still carry at least one completed session whose stored summary is stale or
    /// zero-valued. Enumerated once per launch so reconciliation does not re-scan on every
    /// snapshot.
    func legacySummaryVINs() -> [String] {
        let query = """
        SELECT DISTINCT vin FROM charging_sessions
        WHERE ended_at IS NOT NULL
          AND lifecycle_state IN ('completed', 'interrupted')
          AND (end_soc <= start_soc OR energy_delivered_kwh <= 0 OR \(Self.undercountedPredicate))
        ORDER BY vin;
        """
        return (try? sql.query(sql: query) { _ in } process: { stmt -> [String] in
            var list: [String] = []
            while try stmt.stepOrThrow(), let vin = stmt.columnText(at: 0) { list.append(vin) }
            return list
        }) ?? []
    }

    /// Repairs completed rows written by older builds with a stale/zero final summary. The
    /// operation is idempotent and only touches rows whose retained samples prove a real
    /// gain. Rows keep the usable capacity they were written with; the provided capacity
    /// (from the caller's current preference state) is only the fallback for rows that never
    /// stored one. Run once per launch from the store, not per snapshot.
    func reconcileLegacySummaries(for vin: String, usableCapacityKwh: Double?) {
        repairUndercountedIntegrations(for: vin, usableCapacityKwh: usableCapacityKwh)
        let candidates = recentChargingSessions(for: vin, limit: 1_000).filter {
            $0.energyDeliveredKwh <= 0 || ($0.endSoc ?? $0.startSoc) <= $0.startSoc
        }
        for candidate in candidates {
            let capacity = candidate.usableCapacityKwh ?? usableCapacityKwh ?? 0
            guard capacity > 0 else { continue }
            let repaired = reconciled(candidate, usableCapacityKwh: capacity)
            guard repaired.energyDeliveredKwh > 0,
                  let endSoc = repaired.endSoc, endSoc > repaired.startSoc else { continue }
            logOnFailure("session reconcile") {
                try sql.query(sql: """
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
    }
}
