import Foundation
import Testing
@testable import Hisingen

/// Three ways the SQLite schema can drift out of step with the code that reads and writes it.
///
/// The field failures this guards are slow and quiet: a column added to `createTables()` but
/// not to a migration leaves every existing install missing it, and an additive migration
/// whose declaration disagrees with the baseline leaves new installs different from upgraded
/// ones. Neither shows up until a write hits the gap, months later, on someone else's machine.
///
/// 1. The checked-in schema fixture pins the app's real schema. Any change to it is a reviewed
///    line in the diff rather than a side effect of editing `createTables()`.
/// 2. A store built from `legacy-database-v0.sql` (the schema an install from before
///    `PRAGMA user_version` has) is upgraded by the real launch path and must end up
///    identical to a fresh install. This is the direction that catches a baseline-only column.
/// 3. Every table and column written by SQL under `Sources/Hisingen` is checked against the
///    upgraded store, so a writer cannot target a column only the fresh schedule creates.
@Suite("VehicleDatabaseSchemaParity")
struct VehicleDatabaseSchemaParityTests {

    /// `Tests/HisingenTests/Unit/<this file>` → repository root.
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureDirectory: URL {
        packageRoot().appendingPathComponent("Tests/HisingenTests/Fixtures", isDirectory: true)
    }

    private func legacySchemaSQL() throws -> String {
        let url = try #require(
            Bundle.module.url(forResource: "legacy-database-v0", withExtension: "sql"),
            "legacy-database-v0.sql is missing from the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func freshSnapshot() throws -> [String] {
        let raw = try SQLiteDatabase.inMemory()
        _ = VehicleDatabase(database: raw)
        return try schemaSnapshot(of: raw)
    }

    /// The schema as SQLite reports it, one fact per line and sorted, so a migration that
    /// appends columns in a different order to the baseline is not reported as a difference.
    private func schemaSnapshot(of database: SQLiteDatabase) throws -> [String] {
        var lines: [String] = []
        let version = try database.query(sql: "PRAGMA user_version;") { _ in } process: { statement -> Int in
            try statement.stepOrThrow() ? Int(statement.columnInt64(at: 0) ?? 0) : 0
        }
        lines.append("user-version \(version)")

        let tables = try database.query(sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            ORDER BY name;
            """) { _ in } process: { statement -> [String] in
            var names: [String] = []
            while try statement.stepOrThrow() {
                if let name = statement.columnText(at: 0) { names.append(name) }
            }
            return names
        }

        for table in tables {
            lines.append("table \(table)")
            let columns = try database.query(sql: "PRAGMA table_info(\"\(table)\");") { _ in } process: { statement -> [(String, String)] in
                var rows: [(String, String)] = []
                while try statement.stepOrThrow() {
                    let name = statement.columnText(at: 1) ?? "?"
                    let type = (statement.columnText(at: 2) ?? "").lowercased()
                    let notNull = statement.columnInt64(at: 3) ?? 0
                    let defaultValue = statement.columnText(at: 4) ?? "-"
                    let primaryKey = statement.columnInt64(at: 5) ?? 0
                    rows.append(("column \(name) \(type) notnull=\(notNull) default=\(defaultValue) pk=\(primaryKey)", name))
                }
                return rows
            }
            for (line, _) in columns.sorted(by: { $0.1 < $1.1 }) {
                lines.append("  \(line)")
            }
        }

        let indexes = try database.query(sql: """
            SELECT name, tbl_name, COALESCE(sql, '') FROM sqlite_master
            WHERE type = 'index' AND sql IS NOT NULL
            ORDER BY name;
            """) { _ in } process: { statement -> [(String, String, String)] in
            var rows: [(String, String, String)] = []
            while try statement.stepOrThrow() {
                rows.append((statement.columnText(at: 0) ?? "?",
                             statement.columnText(at: 1) ?? "?",
                             statement.columnText(at: 2) ?? ""))
            }
            return rows
        }
        for (name, table, sql) in indexes {
            let normalized = sql.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
            lines.append("index \(name) on \(table) \(normalized)")
        }
        return lines
    }

    // MARK: - 1. The checked-in fixture is the app's real schema

    @Test func freshInstallSchemaMatchesTheCheckedInFixture() throws {
        let actual = try freshSnapshot()
        let fixtureURL = fixtureDirectory.appendingPathComponent("database-schema.txt")

        if ProcessInfo.processInfo.environment["HISINGEN_WRITE_SCHEMA_FIXTURE"] == "1" {
            try (actual.joined(separator: "\n") + "\n")
                .write(to: fixtureURL, atomically: true, encoding: .utf8)
            Issue.record("""
                Rewrote Tests/HisingenTests/Fixtures/database-schema.txt. Review the diff and \
                commit it; this run is not a pass until the fixture is committed.
                """)
            return
        }

        let expected = try String(contentsOf: fixtureURL, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let difference = Self.firstDifference(actual, expected)
        #expect(difference == nil, """
            The app's schema and Tests/HisingenTests/Fixtures/database-schema.txt disagree \
            (\(difference ?? "unknown difference")). Review the schema change, then regenerate \
            the fixture with HISINGEN_WRITE_SCHEMA_FIXTURE=1 sh Scripts/test.sh --skip Live \
            --no-parallel --filter VehicleDatabaseSchemaParity and commit the result.
            """)
    }

    // MARK: - 2. An old store upgrades to exactly the fresh-install schema

    @Test func aStoreFromBeforeSchemaVersioningUpgradesToTheFreshInstallSchema() throws {
        let upgraded = try SQLiteDatabase.inMemory()
        try upgraded.execute(sql: try legacySchemaSQL())
        try upgraded.execute(sql: "PRAGMA user_version = 0;")

        // The launch path, not a test-only migrator call: baseline DDL runs against the old
        // tables (IF NOT EXISTS leaves them alone), then every migration applies in order.
        let database = VehicleDatabase(database: upgraded)
        #expect(database.schemaIncompatibility == nil)

        let migrated = try schemaSnapshot(of: upgraded)
        let fresh = try freshSnapshot()
        let difference = Self.firstDifference(migrated, fresh)
        #expect(difference == nil, """
            A store from before schema versioning no longer upgrades to the fresh-install \
            schema (\(difference ?? "unknown difference")). A column or index was added to \
            `createTables()` without a migration (or a migration was changed without its \
            baseline counterpart).
            """)

        // Canary: the fixture really is an old schema. If the migration steps were skipped
        // wholesale, the comparison above would pass trivially.
        #expect(migrated.contains { $0.hasPrefix("user-version \(VehicleDatabase.latestSchemaVersion)") })
        #expect(fresh.contains("table custom_themes"), "the fresh schema lost a migration-created table")
    }

    // MARK: - 3. Every table and column the app writes exists on the upgraded store

    @Test func everyTableAndColumnTheAppWritesExistsOnAnUpgradedStore() throws {
        let upgraded = try SQLiteDatabase.inMemory()
        try upgraded.execute(sql: try legacySchemaSQL())
        try upgraded.execute(sql: "PRAGMA user_version = 0;")
        _ = VehicleDatabase(database: upgraded)

        let schema = try tableColumns(of: upgraded)
        let writes = try sourceWriteSurface()

        // Fail closed on a broken scan: a regex that silently finds nothing would let the
        // write surface go unchecked while the test still passed.
        #expect(writes.count >= 10, "the SQL scan found only \(writes.count) written tables; it broke")
        #expect(writes.values.reduce(0, { $0 + $1.count }) >= 40,
                "the SQL scan found too few written columns to be meaningful")

        for (table, columns) in writes.sorted(by: { $0.key < $1.key }) {
            guard let available = schema[table] else {
                Issue.record("""
                    The app writes to table "\(table)", which does not exist on a store \
                    upgraded from the oldest schema. Add it to createTables() and to a \
                    migration.
                    """)
                continue
            }
            for column in columns.sorted() {
                let known = available.contains(column)
                #expect(known, """
                    The app writes "\(table).\(column)", which is missing from a store \
                    upgraded from the oldest schema. Add the column to a migration (the \
                    baseline alone only helps new installs).
                    """)
            }
        }
    }

    private func tableColumns(of database: SQLiteDatabase) throws -> [String: Set<String>] {
        let tables = try database.query(sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%';
            """) { _ in } process: { statement -> [String] in
            var names: [String] = []
            while try statement.stepOrThrow() {
                if let name = statement.columnText(at: 0) { names.append(name) }
            }
            return names
        }
        var schema: [String: Set<String>] = [:]
        for table in tables {
            let columns = try database.query(sql: "PRAGMA table_info(\"\(table)\");") { _ in } process: { statement -> Set<String> in
                var names: Set<String> = []
                while try statement.stepOrThrow() {
                    if let name = statement.columnText(at: 1) { names.insert(name) }
                }
                return names
            }
            schema[table] = columns
        }
        return schema
    }

    // MARK: - Source scan

    /// Table → columns named by `INSERT INTO`, `UPDATE … SET` and `DELETE FROM` statements in
    /// the app's string literals. Parsing the literals instead of a maintained list means a
    /// new writer is covered the moment it is added.
    private func sourceWriteSurface() throws -> [String: Set<String>] {
        let sources = packageRoot().appendingPathComponent("Sources/Hisingen", isDirectory: true)
        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(files.count > 50, "the source scan found no Swift files; path resolution broke")

        var surface: [String: Set<String>] = [:]

        for relative in files {
            let contents = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            for sql in Self.stringLiteralContents(in: contents) {
                for (table, columns) in Self.writes(in: sql) {
                    surface[table, default: []].formUnion(columns)
                }
            }
        }
        return surface
    }

    /// Contents of every ordinary Swift string literal, multi-line or single-line. SQL lives in
    /// these; comments are not literals and are skipped, so prose about a statement cannot be
    /// mistaken for the statement.
    private static func stringLiteralContents(in source: String) -> [String] {
        var literals: [String] = []
        let nsSource = source as NSString
        let multiLine = try? NSRegularExpression(pattern: "\"\"\"([\\s\\S]*?)\"\"\"")
        let singleLine = try? NSRegularExpression(pattern: "\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
        for regex in [multiLine, singleLine].compactMap({ $0 }) {
            let matches = regex.matches(in: source, range: NSRange(location: 0, length: nsSource.length))
            for match in matches where match.numberOfRanges > 1 {
                literals.append(nsSource.substring(with: match.range(at: 1)))
            }
        }
        return literals
    }

    private static func writes(in sql: String) -> [(String, Set<String>)] {
        var writes: [(String, Set<String>)] = []
        let nsSQL = sql as NSString
        let whole = NSRange(location: 0, length: nsSQL.length)

        if let insert = try? NSRegularExpression(
            pattern: "(?i)\\bINSERT\\s+(?:OR\\s+(?:REPLACE|IGNORE|ABORT|FAIL|ROLLBACK)\\s+)?INTO\\s+([a-z_][a-z0-9_]*)\\s*\\(([^)]*)\\)") {
            for match in insert.matches(in: sql, range: whole) {
                let table = nsSQL.substring(with: match.range(at: 1)).lowercased()
                let columns = identifiers(in: nsSQL.substring(with: match.range(at: 2)))
                writes.append((table, columns))
            }
        }

        if let update = try? NSRegularExpression(
            pattern: "(?is)\\bUPDATE\\s+([a-z_][a-z0-9_]*)\\s+SET\\s+(.*?)(?=\\s+WHERE\\b|;)") {
            for match in update.matches(in: sql, range: whole) {
                let table = nsSQL.substring(with: match.range(at: 1)).lowercased()
                let assignments = nsSQL.substring(with: match.range(at: 2))
                var columns: Set<String> = []
                for assignment in topLevelCommaSeparated(assignments) {
                    guard let equals = assignment.firstIndex(of: "=") else { continue }
                    let target = assignment[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = target.split(separator: ".").last.map(String.init) ?? target
                    if isIdentifier(name) { columns.insert(name.lowercased()) }
                }
                writes.append((table, columns))
            }
        }

        if let delete = try? NSRegularExpression(
            pattern: "(?i)\\bDELETE\\s+FROM\\s+([a-z_][a-z0-9_]*)") {
            for match in delete.matches(in: sql, range: whole) {
                writes.append((nsSQL.substring(with: match.range(at: 1)).lowercased(), []))
            }
        }
        return writes
    }

    private static func identifiers(in list: String) -> Set<String> {
        var names: Set<String> = []
        for candidate in topLevelCommaSeparated(list) {
            let name = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if isIdentifier(name) { names.insert(name.lowercased()) }
        }
        return names
    }

    /// Splits on commas that are not inside parentheses or quotes, so `COALESCE(?, x)` and a
    /// quoted value stay in one piece.
    private static func topLevelCommaSeparated(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var depth = 0
        var inQuote: Character?
        for character in text {
            if let quote = inQuote {
                current.append(character)
                if character == quote { inQuote = nil }
                continue
            }
            switch character {
            case "'", "\"":
                inQuote = character
                current.append(character)
            case "(":
                depth += 1
                current.append(character)
            case ")":
                depth = max(0, depth - 1)
                current.append(character)
            case "," where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(current)
        }
        return parts
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard let first = text.first, first == "_" || first.isLetter else { return false }
        return text.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// One readable line describing the first disagreement, or `nil` when the two agree.
    /// Returning a sentence instead of the arrays keeps a failure about the schema difference
    /// rather than a few hundred lines of column dump.
    private static func firstDifference(_ actual: [String], _ expected: [String]) -> String? {
        for (index, line) in actual.enumerated() where index >= expected.count || expected[index] != line {
            let other = index < expected.count ? expected[index] : "<missing>"
            return "line \(index + 1): app has \"\(line)\", fixture has \"\(other)\""
        }
        if expected.count > actual.count {
            return "the app's schema is missing \"\(expected[actual.count])\""
        }
        return nil
    }
}
