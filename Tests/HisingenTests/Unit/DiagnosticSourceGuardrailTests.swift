import Foundation
import Testing
@testable import Hisingen

/// The diagnostic bundle's `OSLogStore` query filters on one subsystem string. A file
/// that instantiates its own `Logger(subsystem: …)` would log fine yet vanish from
/// exports if the literal ever drifted, so every logger must come from the
/// `AppLog.logger(_:)` factory – no direct `Logger(subsystem:)` call anywhere else.
struct DiagnosticSourceGuardrailTests {
    @Test
    func chargingPlannerPriceCurveIsNeverHiddenByEntranceState() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let packageRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRoot.appendingPathComponent(
            "Sources/Hisingen/UI/Vehicle/PriceCurveView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(
            !source.contains("hasPlayedEntrance")
                && !source.contains(".opacity(appeared ? 1 : 0)"),
            "The price graph must render at full opacity whenever it has plottable points; process-wide entrance state can leave a rebuilt chart permanently hidden."
        )
    }

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

        // The connection health and renewability decisions moved out of the account form
        // into `AccountConnectionModel`; the same rule follows them there. Their span must
        // classify from presence bits and the typed failure kinds alone — never from the
        // Keychain-backed email, whose first read can trigger a Keychain round-trip.
        let connectionModel = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Hisingen/Services/Security/AccountConnectionModel.swift"),
            encoding: .utf8)
        let factsStart = try #require(
            connectionModel.range(of: "func isConnected(_ brand: VehicleBrand)")
        ).lowerBound
        let factsTail = connectionModel[factsStart...]
        let authFailureStart = try #require(
            factsTail.range(of: "private func isAuthFailure")
        ).lowerBound
        #expect(
            !factsTail[..<authFailureStart].contains("preferences.email"),
            "Connection-health classification must use presence bits, not the Keychain-backed email."
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
