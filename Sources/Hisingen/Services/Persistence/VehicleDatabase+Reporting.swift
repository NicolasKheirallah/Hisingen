import Foundation

extension VehicleDatabase {
    // MARK: - Maintenance log

    /// The reader's maintenance entries for one vehicle, newest first. Reader-authored and local:
    /// nothing here comes from a provider, so a failed refresh cannot change or drop it.
    func maintenanceEntries(for vin: String, limit: Int = 500) -> [MaintenanceEntry] {
        let sql = """
        SELECT id, vin, date, odometer_km, kind, title, notes, cost
        FROM maintenance_entries WHERE vin = ? ORDER BY date DESC LIMIT ?;
        """
        return (try? db.readQuery(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.bindInt64(Int64(limit), at: 2)
        } process: { stmt in
            var rows: [MaintenanceEntry] = []
            while try stmt.stepOrThrow() {
                guard let id = stmt.columnText(at: 0),
                      let rowVIN = stmt.columnText(at: 1),
                      let date = stmt.columnDate(at: 2),
                      let kindText = stmt.columnText(at: 4),
                      let kind = MaintenanceKind(rawValue: kindText) else { continue }
                rows.append(MaintenanceEntry(
                    id: id, vin: rowVIN, date: date,
                    odometerKm: stmt.columnInt64(at: 3).map(Int.init),
                    kind: kind,
                    title: stmt.columnText(at: 5) ?? "",
                    notes: stmt.columnText(at: 6),
                    cost: stmt.columnDouble(at: 7)))
            }
            return rows
        }) ?? []
    }

    /// Adds one entry and hands it back with the id it was stored under. A writer that failed is
    /// reported as `nil` so the sheet can say the entry was not saved rather than clear its fields.
    @discardableResult
    func addMaintenanceEntry(_ entry: MaintenanceEntry) -> MaintenanceEntry? {
        let sql = """
        INSERT INTO maintenance_entries (id, vin, date, odometer_km, kind, title, notes, cost)
        VALUES (?,?,?,?,?,?,?,?);
        """
        do {
            try db.query(sql: sql) { stmt in
                try stmt.bindText(entry.id, at: 1)
                try stmt.bindText(entry.vin, at: 2)
                try stmt.bindDate(entry.date, at: 3)
                try stmt.bindInt64(entry.odometerKm.map(Int64.init), at: 4)
                try stmt.bindText(entry.kind.rawValue, at: 5)
                try stmt.bindText(entry.title, at: 6)
                try stmt.bindText(entry.notes, at: 7)
                try stmt.bindDouble(entry.cost, at: 8)
                try stmt.executeUpdate()
            } process: { _ in }
            return entry
        } catch {
            logger.error("Maintenance entry insert failed: \(error, privacy: .public)")
            return nil
        }
    }

    func deleteMaintenanceEntry(id: String, vin: String) {
        try? db.query(sql: "DELETE FROM maintenance_entries WHERE id = ? AND vin = ?;") { stmt in
            try stmt.bindText(id, at: 1)
            try stmt.bindText(vin, at: 2)
            try stmt.executeUpdate()
        } process: { _ in }
    }

    // MARK: - Ownership assumption

    /// The reader's purchase price, purchase date and annual decline for this vehicle, or nil when
    /// they have not entered one. Never inferred.
    func ownership(for vin: String) -> VehicleOwnership? {
        let sql = """
        SELECT vin, purchase_price, purchase_date, annual_decline_percent
        FROM vehicle_ownership WHERE vin = ?;
        """
        return try? db.readQuery(sql: sql) { stmt in
            try stmt.bindText(vin, at: 1)
        } process: { stmt in
            guard try stmt.stepOrThrow(),
                  let rowVIN = stmt.columnText(at: 0),
                  let price = stmt.columnDouble(at: 1),
                  let purchaseDate = stmt.columnDate(at: 2),
                  let decline = stmt.columnDouble(at: 3) else { return nil }
            return VehicleOwnership(
                vin: rowVIN,
                assumption: DepreciationAssumption(
                    purchasePrice: price, purchaseDate: purchaseDate,
                    annualDeclinePercent: decline).sanitized)
        } ?? nil
    }

    @discardableResult
    func saveOwnership(_ ownership: VehicleOwnership) -> Bool {
        let clean = ownership.assumption.sanitized
        guard clean.purchasePrice > 0 else {
            // A cleared assumption is a delete: keeping a zero row would read as "this car is worth
            // nothing", which is not what leaving the field empty means.
            clearOwnership(for: ownership.vin)
            return true
        }
        let sql = """
        INSERT INTO vehicle_ownership (vin, purchase_price, purchase_date, annual_decline_percent)
        VALUES (?,?,?,?)
        ON CONFLICT(vin) DO UPDATE SET
            purchase_price = excluded.purchase_price,
            purchase_date = excluded.purchase_date,
            annual_decline_percent = excluded.annual_decline_percent;
        """
        do {
            try db.query(sql: sql) { stmt in
                try stmt.bindText(ownership.vin, at: 1)
                try stmt.bindDouble(clean.purchasePrice, at: 2)
                try stmt.bindDate(clean.purchaseDate, at: 3)
                try stmt.bindDouble(clean.annualDeclinePercent, at: 4)
                try stmt.executeUpdate()
            } process: { _ in }
            return true
        } catch {
            logger.error("Ownership assumption save failed: \(error, privacy: .public)")
            return false
        }
    }

    func clearOwnership(for vin: String) {
        try? db.query(sql: "DELETE FROM vehicle_ownership WHERE vin = ?;") { stmt in
            try stmt.bindText(vin, at: 1)
            try stmt.executeUpdate()
        } process: { _ in }
    }
}
