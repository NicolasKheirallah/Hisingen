import Foundation
import Testing
@testable import Hisingen

/// The diagnostic bundle's `OSLogStore` query filters on one subsystem string. A file
/// that instantiates its own `Logger(subsystem: …)` would log fine yet vanish from
/// exports if the literal ever drifted, so every logger must come from the
/// `AppLog.logger(_:)` factory — no direct `Logger(subsystem:)` call anywhere else.
struct DiagnosticSourceGuardrailTests {
    @Test
    func swiftUIRenderingNeverReadsProtectedKeychainValues() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let uiRoot = packageRoot.appendingPathComponent("Sources/Hisingen/UI")
        let files = try FileManager.default.subpathsOfDirectory(atPath: uiRoot.path)
            .filter { $0.hasSuffix(".swift") }
        #expect(files.count > 20, "guardrail found no SwiftUI files; path resolution broke")

        for relative in files {
            let contents = try String(contentsOf: uiRoot.appendingPathComponent(relative),
                                      encoding: .utf8)
            #expect(
                !contents.contains("Keychain.read"),
                "\(relative) reads Keychain while rendering; use a non-secret presence bit and reserve secret reads for explicit session/sign-in actions."
            )
        }

        let accountForm = try String(
            contentsOf: uiRoot.appendingPathComponent("Settings/AccountCredentialsForm.swift"),
            encoding: .utf8)
        let renewable = try #require(accountForm.range(of: "private var hasRenewableCredentials"))
        let renewableTail = accountForm[renewable.lowerBound...]
        let health = try #require(renewableTail.range(of: "private var connectionHealth"))
        #expect(
            !renewableTail[..<health.lowerBound].contains("preferences.email"),
            "SwiftUI credential-presence rendering must not indirectly read the Keychain-backed email."
        )

        let preferences = packageRoot.appendingPathComponent(
            "Sources/Hisingen/Services/Persistence/PreferencesStore.swift")
        let preferenceSource = try String(contentsOf: preferences, encoding: .utf8)
        let resumeCheck = try #require(
            preferenceSource.range(of: "func hasResumableSession(for brand: VehicleBrand) -> Bool")
        )
        let remaining = preferenceSource[resumeCheck.lowerBound...]
        let end = try #require(remaining.range(of: "var hasPolestarCommandAuthorization"))
        #expect(
            !remaining[..<end.lowerBound].contains("Keychain.read")
                && !remaining[..<end.lowerBound].contains("keychain.read"),
            "Session-presence checks are called by SwiftUI and must use non-secret mirrors."
        )
    }

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
