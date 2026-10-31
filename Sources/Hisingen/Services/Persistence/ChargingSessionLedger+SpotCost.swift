import Foundation

extension ChargingSessionLedger {
    /// Prices a session against hourly (or quarterly) spot prices, splitting every sample
    /// interval at price-slot boundaries so a rate change inside one polling interval
    /// prices each piece at its own rate (trapezoidal power within the pieces). Requires
    /// the whole charged window to sit inside the price series' coverage – a session that
    /// predates or overruns the available data stays uncosted (`nil`) rather than being
    /// priced with invented rates, and remains pending for a later, wider pass. The result
    /// is scaled to the authoritative session energy so sparse sampling cannot bias the
    /// figure. Price lookup advances monotonically (sessions are chronological), avoiding
    /// a linear scan per slice.
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
        var priceIndex = 0
        for (a, b) in zip(chronological, chronological.dropFirst()) {
            guard let p0 = a.powerKw, let p1 = b.powerKw else { continue }
            let intervalStart = a.timestamp
            let interval = b.timestamp.timeIntervalSince(intervalStart)
            guard interval > 0, interval <= maximumEstimateSampleGap else { continue }
            let intervalEnd = b.timestamp
            var cursor = intervalStart
            while cursor < intervalEnd {
                while priceIndex + 1 < orderedPrices.count && orderedPrices[priceIndex].endDate <= cursor {
                    priceIndex += 1
                }
                while priceIndex > 0 && orderedPrices[priceIndex].startDate > cursor {
                    priceIndex -= 1
                }
                guard let slot = (priceIndex < orderedPrices.count ? orderedPrices[priceIndex] : nil),
                      slot.startDate <= cursor && cursor < slot.endDate else { return nil }
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
            while try stmt.stepOrThrow() {
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
        logOnFailure("spot cost update") {
            try sql.query(sql: "UPDATE charging_sessions SET spot_estimated_cost = ? WHERE id = ?;") { stmt in
                try stmt.bindDouble(cost, at: 1)
                try stmt.bindText(id, at: 2)
                try stmt.executeUpdate()
            } process: { _ in }
        }
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
}
