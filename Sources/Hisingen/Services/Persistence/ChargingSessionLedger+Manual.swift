import Foundation

extension ChargingSessionLedger {
    // MARK: - Sessions entered by hand

    /// Inserts a completed session the reader typed in. Energy is the number from the receipt,
    /// not a battery-side estimate, so `start_soc` stays negative (no reading) and the row is
    /// excluded from percentage-gain figures. The price is stored twice: the total the reader
    /// paid in `estimated_cost`, and the per-kWh figure in `tariff_price_per_kwh`, so both the
    /// session row and the cost policy can use it without re-deriving one from the other.
    @discardableResult
    func addManualChargingSession(
        vin: String,
        startedAt: Date,
        endedAt: Date,
        locationName: String?,
        place: ChargingSessionPlace,
        energyKwh: Double,
        totalCost: Double?,
        pricePerKwh: Double?,
        currencySymbol: String?
    ) -> String {
        let id = UUID().uuidString
        let perKwh = pricePerKwh ?? (energyKwh > 0 ? totalCost.map { $0 / energyKwh } : nil)
        let total = totalCost ?? perKwh.map { $0 * energyKwh }
        let statement = """
        INSERT INTO charging_sessions (
            id, vin, started_at, ended_at, start_soc, end_soc, energy_delivered_kwh,
            peak_power_kw, average_power_kw, location_name, charging_place, created_at,
            lifecycle_state, completion_reason, energy_source, confidence,
            tariff_price_per_kwh, currency_symbol, estimated_cost,
            last_observed_at, summary_version, pending_stop_count
        ) VALUES (?, ?, ?, ?, -1, NULL, ?, 0, 0, ?, ?, ?, 'completed', 'manual_entry',
                  'manual_entry', 'high', ?, ?, ?, ?, 2, 0);
        """
        logOnFailure("manual session insert") {
            try sql.query(sql: statement) { stmt in
                try stmt.bindText(id, at: 1)
                try stmt.bindText(vin, at: 2)
                try stmt.bindDate(startedAt, at: 3)
                try stmt.bindDate(endedAt, at: 4)
                try stmt.bindDouble(energyKwh, at: 5)
                try stmt.bindText(locationName, at: 6)
                try stmt.bindText(place.rawValue, at: 7)
                try stmt.bindDate(startedAt, at: 8)
                try stmt.bindDouble(perKwh, at: 9)
                try stmt.bindText(currencySymbol, at: 10)
                try stmt.bindDouble(total, at: 11)
                try stmt.bindDate(endedAt, at: 12)
                try stmt.executeUpdate()
            } process: { _ in }
        }
        return id
    }

    /// Edits the parts a reader can know better than the app: when it ran, where it happened,
    /// how much energy it delivered, and what it cost. Provenance columns are left untouched so
    /// an edited recorded session still says it was recorded, and an edited manual one still
    /// says it was entered by hand.
    func updateChargingSessionDetails(
        id: String,
        vin: String,
        startedAt: Date,
        endedAt: Date,
        locationName: String?,
        place: ChargingSessionPlace,
        energyKwh: Double,
        totalCost: Double?,
        pricePerKwh: Double?
    ) {
        let perKwh = pricePerKwh ?? (energyKwh > 0 ? totalCost.map { $0 / energyKwh } : nil)
        let total = totalCost ?? perKwh.map { $0 * energyKwh }
        logOnFailure("session details update") {
            try sql.query(sql: """
                UPDATE charging_sessions SET
                    started_at = ?, ended_at = ?, location_name = ?, charging_place = ?,
                    energy_delivered_kwh = ?, tariff_price_per_kwh = ?,
                    estimated_cost = ?, last_observed_at = ?
                WHERE id = ? AND vin = ? AND ended_at IS NOT NULL;
                """) { stmt in
                try stmt.bindDate(startedAt, at: 1)
                try stmt.bindDate(endedAt, at: 2)
                try stmt.bindText(locationName, at: 3)
                try stmt.bindText(place.rawValue, at: 4)
                try stmt.bindDouble(energyKwh, at: 5)
                try stmt.bindDouble(perKwh, at: 6)
                try stmt.bindDouble(total, at: 7)
                try stmt.bindDate(endedAt, at: 8)
                try stmt.bindText(id, at: 9)
                try stmt.bindText(vin, at: 10)
                try stmt.executeUpdate()
            } process: { _ in }
        }
    }
}
