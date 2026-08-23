import Foundation
import OSLog

/// Single source of truth for the unified-logging subsystem. Every `Logger` in the app
/// must be created through `AppLog.logger(_:)` — the diagnostic bundle's `OSLogStore`
/// query filters on this exact string, so a drifted literal would silently drop that
/// file's entries from exports. `DiagnosticSourceGuardrailTests` enforces single
/// definition of the literal.
enum AppLog {
    static let subsystem = "io.kheirallah.hisingen"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
