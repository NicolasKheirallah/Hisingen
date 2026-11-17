import Foundation
import OSLog

/// Owns the `custom_themes` table: the durable copy of every theme the reader made.
///
/// The database lives in Application Support, so it outlives app updates, reinstalls of the app
/// bundle, and a reset of the preferences domain; it also rides along in database backups.
/// `CustomThemeStore` keeps a preferences mirror for fast palette reads and reconciles the two.
final class CustomThemeLedger: @unchecked Sendable {
    private let db: SQLiteDatabase
    private let logger = AppLog.logger("database")
    init(sql: SQLiteDatabase) { self.db = sql }

    func all() -> [CustomThemeDefinition] {
        do {
            return try db.query(sql: "SELECT definition FROM custom_themes ORDER BY created_at, id;") { _ in } process: { stmt in
                var out: [CustomThemeDefinition] = []
                let decoder = JSONDecoder()
                while try stmt.stepOrThrow() {
                    if let text = stmt.columnText(at: 0), let data = text.data(using: .utf8),
                       let definition = try? decoder.decode(CustomThemeDefinition.self, from: data) {
                        out.append(definition)
                    }
                }
                return out
            }
        } catch {
            logger.error("Could not read custom themes: \(error, privacy: .public)")
            return []
        }
    }

    func upsert(_ definition: CustomThemeDefinition) {
        do {
            let json = String(decoding: try JSONEncoder().encode(definition), as: UTF8.self)
            let now = Date().timeIntervalSince1970
            try db.query(sql: """
                INSERT INTO custom_themes (id, definition, created_at, updated_at) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET definition = excluded.definition, updated_at = excluded.updated_at;
                """) { stmt in
                try stmt.bindText(definition.id, at: 1)
                try stmt.bindText(json, at: 2)
                try stmt.bindDouble(now, at: 3)
                try stmt.bindDouble(now, at: 4)
            } process: { stmt in _ = try stmt.stepOrThrow() }
        } catch {
            logger.error("Could not save custom theme: \(error, privacy: .public)")
        }
    }

    func delete(id: String) {
        do {
            try db.query(sql: "DELETE FROM custom_themes WHERE id = ?;") { stmt in
                try stmt.bindText(id, at: 1)
            } process: { stmt in _ = try stmt.stepOrThrow() }
        } catch {
            logger.error("Could not delete custom theme: \(error, privacy: .public)")
        }
    }
}
