import Foundation
import OSLog

/// SQLite persistence for the Charging Planner's fetched spot-price series.
///
/// One row per published interval per zone, plus a `fetched_at` marker per zone. The
/// service keeps the series in memory and rewrites the zone's rows wholesale after each
/// fetch, so the table never holds more than the cache itself (≤ two days × zones) and
/// needs no retention path. Market data, not user history: wipes, prunes, and backups
/// deliberately ignore these tables — a fresh fetch replaces everything.
final class ElectricityPriceStore: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("elpriser-db")

    init(sql: SQLiteDatabase) {
        self.db = sql
    }

    /// The persisted series for a zone, ordered by interval start. Empty when nothing
    /// has been fetched (or the database is unavailable).
    func prices(zone: ElspotZone) -> [ElectricityPricePoint] {
        let sql = """
        SELECT start_at, end_at, sek_per_kwh FROM electricity_prices
        WHERE zone = ? ORDER BY start_at ASC;
        """
        return (try? db.query(sql: sql) { stmt in
            try stmt.bindText(zone.rawValue, at: 1)
        } process: { stmt -> [ElectricityPricePoint] in
            var points: [ElectricityPricePoint] = []
            while stmt.step() {
                guard let start = stmt.columnDate(at: 0),
                      let end = stmt.columnDate(at: 1),
                      let price = stmt.columnDouble(at: 2) else { continue }
                points.append(ElectricityPricePoint(startDate: start, endDate: end, sekPerKwh: price))
            }
            return points
        }) ?? []
    }

    /// When the zone's series was last fetched, for diagnostics; freshness itself is
    /// derived from the intervals' coverage.
    func fetchedAt(zone: ElspotZone) -> Date? {
        let sql = "SELECT fetched_at FROM electricity_price_fetches WHERE zone = ? LIMIT 1;"
        return try? db.query(sql: sql) { stmt in
            try stmt.bindText(zone.rawValue, at: 1)
        } process: { stmt -> Date? in
            stmt.step() ? stmt.columnDate(at: 0) : nil
        } ?? nil
    }

    /// Replaces the zone's persisted series in one transaction. Old intervals are
    /// deleted first so rows for past days never accumulate.
    func save(zone: ElspotZone, points: [ElectricityPricePoint], fetchedAt: Date) {
        do {
            try db.withTransaction {
                try db.query(sql: "DELETE FROM electricity_prices WHERE zone = ?;") { stmt in
                    try stmt.bindText(zone.rawValue, at: 1)
                    try stmt.executeUpdate()
                } process: { _ in }
                let insert = """
                INSERT INTO electricity_prices (zone, start_at, end_at, sek_per_kwh)
                VALUES (?, ?, ?, ?);
                """
                for point in points {
                    try db.query(sql: insert) { stmt in
                        try stmt.bindText(zone.rawValue, at: 1)
                        try stmt.bindDate(point.startDate, at: 2)
                        try stmt.bindDate(point.endDate, at: 3)
                        try stmt.bindDouble(point.sekPerKwh, at: 4)
                        try stmt.executeUpdate()
                    } process: { _ in }
                }
                try db.query(sql: """
                INSERT INTO electricity_price_fetches (zone, fetched_at) VALUES (?, ?)
                ON CONFLICT(zone) DO UPDATE SET fetched_at = excluded.fetched_at;
                """) { stmt in
                    try stmt.bindText(zone.rawValue, at: 1)
                    try stmt.bindDate(fetchedAt, at: 2)
                    try stmt.executeUpdate()
                } process: { _ in }
            }
        } catch {
            // Degradable: the in-memory cache still serves this launch, and the next
            // fetch simply rewrites what was lost.
            logger.error("Could not persist spot prices for \(zone.rawValue, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Removes every persisted series. Not wired to wipes or sign-out (market data is
    /// not user history); available for tests and explicit maintenance.
    func removeAll() {
        try? db.execute(sql: """
        DELETE FROM electricity_prices;
        DELETE FROM electricity_price_fetches;
        """)
    }
}
