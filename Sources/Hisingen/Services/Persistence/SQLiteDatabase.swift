import Foundation
import SQLite3

/// Error types thrown during SQLite operations.
enum SQLiteError: Error, LocalizedError, Sendable {
    case openDatabase(String)
    case prepareStatement(String)
    case stepExecution(String)
    case bindParameter(String)
    case busy
    case closed

    var errorDescription: String? {
        switch self {
        case .openDatabase(let msg): return "SQLite open failed: \(msg)"
        case .prepareStatement(let msg): return "SQLite prepare failed: \(msg)"
        case .stepExecution(let msg): return "SQLite step failed: \(msg)"
        case .bindParameter(let msg): return "SQLite bind failed: \(msg)"
        case .busy: return "SQLite database is busy"
        case .closed: return "SQLite database is closed"
        }
    }
}

/// A lightweight, memory-safe, thread-safe Swift wrapper around Apple's native `libsqlite3`.
final class SQLiteDatabase: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    let path: String

    init(path: String) throws {
        self.path = path
        var handle: OpaquePointer?

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let dbHandle = handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error (code \(status))"
            if let handle { sqlite3_close(handle) }
            throw SQLiteError.openDatabase(message)
        }

        self.db = dbHandle

        // Configure WAL mode and busy timeout for high-concurrency desktop performance
        try execute(sql: "PRAGMA journal_mode = WAL;")
        try execute(sql: "PRAGMA synchronous = NORMAL;")
        try execute(sql: "PRAGMA busy_timeout = 5000;")
        try execute(sql: "PRAGMA foreign_keys = ON;")
    }

    deinit {
        close()
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db {
            sqlite3_close(db)
            self.db = nil
        }
    }

    /// Convenience initializer for in-memory databases (ideal for unit testing).
    static func inMemory() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    /// Executes arbitrary SQL statements that return no rows (e.g. CREATE TABLE, PRAGMA).
    func execute(sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.closed }

        var errmsg: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &errmsg)
        if status != SQLITE_OK {
            let message = errmsg.flatMap { String(cString: $0) } ?? "Code \(status)"
            sqlite3_free(errmsg)
            throw SQLiteError.stepExecution(message)
        }
    }

    /// Prepares, binds parameters, and executes a statement within a thread lock.
    ///
    /// - Important: `bindings` and `process` run while the lock is held, and the lock is
    ///   **not** recursive. Calling any other method on this database (directly, or via a
    ///   repository method such as `VehicleDatabase.deleteSnapshot`) from inside either
    ///   closure deadlocks the calling thread permanently. Collect what you need, return,
    ///   and perform follow-up writes after this call returns.
    func query<T>(sql: String, bindings: (SQLiteStatement) throws -> Void = { _ in },
                  process: (SQLiteStatement) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { throw SQLiteError.closed }

        var stmtHandle: OpaquePointer?
        let status = sqlite3_prepare_v2(db, sql, -1, &stmtHandle, nil)
        guard status == SQLITE_OK, let stmt = stmtHandle else {
            let message = String(cString: sqlite3_errmsg(db))
            throw SQLiteError.prepareStatement(message)
        }

        let statement = SQLiteStatement(stmt: stmt, db: db)
        defer { sqlite3_finalize(stmt) }

        try bindings(statement)
        return try process(statement)
    }

    /// Runs multiple statements inside an ACID transaction.
    func withTransaction<T>(_ block: () throws -> T) throws -> T {
        try execute(sql: "BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try block()
            try execute(sql: "COMMIT TRANSACTION;")
            return result
        } catch {
            try? execute(sql: "ROLLBACK TRANSACTION;")
            throw error
        }
    }
}

/// Represents an active SQLite prepared statement.
final class SQLiteStatement: @unchecked Sendable {
    private let stmt: OpaquePointer
    private let db: OpaquePointer

    init(stmt: OpaquePointer, db: OpaquePointer) {
        self.stmt = stmt
        self.db = db
    }

    // MARK: - Binding Parameters (1-indexed)

    func bindText(_ value: String?, at index: Int32) throws {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let status = sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, nil)
        guard status == SQLITE_OK else {
            throw SQLiteError.bindParameter("Bind text at index \(index) failed: \(errorMessage)")
        }
    }

    func bindDouble(_ value: Double?, at index: Int32) throws {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let status = sqlite3_bind_double(stmt, index, value)
        guard status == SQLITE_OK else {
            throw SQLiteError.bindParameter("Bind double at index \(index) failed: \(errorMessage)")
        }
    }

    func bindInt64(_ value: Int64?, at index: Int32) throws {
        guard let value else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let status = sqlite3_bind_int64(stmt, index, value)
        guard status == SQLITE_OK else {
            throw SQLiteError.bindParameter("Bind int64 at index \(index) failed: \(errorMessage)")
        }
    }

    func bindDate(_ value: Date?, at index: Int32) throws {
        if let value {
            try bindDouble(value.timeIntervalSince1970, at: index)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    func bindBlob(_ value: Data?, at index: Int32) throws {
        guard let value, !value.isEmpty else {
            sqlite3_bind_null(stmt, index)
            return
        }
        let status = value.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(stmt, index, rawBuffer.baseAddress, Int32(value.count), nil)
        }
        guard status == SQLITE_OK else {
            throw SQLiteError.bindParameter("Bind blob at index \(index) failed: \(errorMessage)")
        }
    }

    // MARK: - Stepping & Reading Columns (0-indexed)

    func step() -> Bool {
        sqlite3_step(stmt) == SQLITE_ROW
    }

    func executeUpdate() throws {
        let status = sqlite3_step(stmt)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw SQLiteError.stepExecution(errorMessage)
        }
    }

    func columnText(at index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cStr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cStr)
    }

    func columnDouble(at index: Int32) -> Double? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(stmt, index)
    }

    func columnInt64(at index: Int32) -> Int64? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(stmt, index)
    }

    func columnDate(at index: Int32) -> Date? {
        guard let timestamp = columnDouble(at: index) else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    func columnBlob(at index: Int32) -> Data? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return Data(bytes: bytes, count: count)
    }

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }
}
