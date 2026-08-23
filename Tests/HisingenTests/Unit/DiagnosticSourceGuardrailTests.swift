import Foundation
import Testing
@testable import Hisingen

/// The diagnostic bundle's `OSLogStore` query filters on one subsystem string. A file
/// that instantiates its own `Logger(subsystem: …)` would log fine yet vanish from
/// exports if the literal ever drifted, so every logger must come from the
/// `AppLog.logger(_:)` factory — no direct `Logger(subsystem:)` call anywhere else.
struct DiagnosticSourceGuardrailTests {
    @Test
    func unifiedLoggersAreCreatedOnlyThroughAppLog() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()  // Unit/
            .deletingLastPathComponent()  // HisingenTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let sources = packageRoot.appendingPathComponent("Sources/Hisingen")

        let files = try FileManager.default.subpathsOfDirectory(atPath: sources.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 50, "guardrail found no source files; path resolution broke")

        for relative in files where !relative.hasSuffix("Support/AppLog.swift") {
            let contents = try String(contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            #expect(
                !contents.contains("Logger(subsystem:"),
                "\(relative) instantiates Logger directly; use AppLog.logger(_:) so the subsystem stays single-sourced."
            )
        }

        let appLog = try String(contentsOf: sources.appendingPathComponent("Support/AppLog.swift"),
                                encoding: .utf8)
        #expect(appLog.contains(AppLog.subsystem))
        #expect(appLog.contains("Logger(subsystem:"))
    }
}
