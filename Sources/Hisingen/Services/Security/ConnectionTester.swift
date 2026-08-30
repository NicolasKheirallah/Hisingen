import Foundation
import OSLog

/// Runs a real, cheap, read-only connectivity check for a brand by re-executing the same
/// session-restore path used at launch and by the background garage scan — never a fabricated
/// result. Reports the round-trip time on success, or a human-readable failure reason,
/// including "no stored session" (returned without any network call).
///
/// Extracted from `AppDelegate.testConnection`; surfaced in Settings as "Test Connection".
@MainActor
final class ConnectionTester {
    private let logger = AppLog.logger("connection-test")
    private let sessionManager: SessionManager
    private let polestarAPI: PolestarAPI
    private let volvoAPI: VolvoAPI
    private let preferences: PreferencesStore

    init(sessionManager: SessionManager,
         polestarAPI: PolestarAPI,
         volvoAPI: VolvoAPI,
         preferences: PreferencesStore) {
        self.sessionManager = sessionManager
        self.polestarAPI = polestarAPI
        self.volvoAPI = volvoAPI
        self.preferences = preferences
    }

    func test(brand: VehicleBrand) async -> (success: Bool, message: String) {
        guard preferences.hasResumableSession(for: brand) else {
            return (false, L10n.text("No active session found. Please sign in."))
        }
        let start = Date()
        do {
            let providerCars: [CarSummary]
            switch brand {
            case .polestar:
                providerCars = try await sessionManager.restorePolestarSession(api: polestarAPI, preferences: preferences)
            case .volvo:
                providerCars = try await sessionManager.restoreVolvoSession(api: volvoAPI, preferences: preferences)
            }
            guard !providerCars.isEmpty else {
                return (false, L10n.text("Signed in, but no vehicles were returned."))
            }
            let elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
            return (true, L10n.format("Connection active & verified (%d ms)", elapsedMs))
        } catch {
            let mapped = VehicleServiceError.map(error, provider: brand)
            logger.error("Connection test for \(brand.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return (false, mapped.errorDescription ?? error.localizedDescription)
        }
    }
}
