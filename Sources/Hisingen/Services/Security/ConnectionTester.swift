import Foundation
import OSLog

/// Why a connectivity check failed, classified so the sign-in UI can offer the right
/// recovery instead of pattern-matching localized error text.
enum SignInFailureKind: Equatable, Sendable {
    /// Polestar/Polestar ID rejected the credentials themselves.
    case invalidCredentials
    /// An interactive challenge (2FA, CAPTCHA, Terms) or a callback mismatch – the
    /// in-app interactive sign-in window handles both.
    case interactiveChallenge
    /// The stored session material was rejected; signing in again is the way back.
    case sessionExpired
    /// The sign-in page or its response format changed. Interactive sign-in may still
    /// work; otherwise an app update is needed.
    case signingFlowChanged
    /// Offline, server trouble, or rate limiting – retrying later is the fix.
    case transient
    case unspecified

    /// Whether the interactive sign-in window is a plausible recovery for this kind.
    var interactiveSignInHelps: Bool {
        switch self {
        case .interactiveChallenge, .sessionExpired, .signingFlowChanged: return true
        case .invalidCredentials, .transient, .unspecified: return false
        }
    }

    /// Pure so tests can pin the mapping from each error family to a kind.
    static func classify(_ error: Error, provider: VehicleBrand) -> SignInFailureKind {
        switch VehicleServiceError.map(error, provider: provider) {
        case .authenticationRequired(_, .invalidCredentials):
            return .invalidCredentials
        case .authenticationRequired(_, .callbackRejected):
            return .interactiveChallenge
        case .authenticationRequired:
            return .sessionExpired
        case .incompatibleAPI, .decoding, .invalidResponse, .upstreamError:
            return .signingFlowChanged
        case .network, .rateLimited, .server, .temporarilyUnavailable:
            return .transient
        case .notConfigured:
            return .sessionExpired
        case .client, .permissionDenied, .responseTooLarge, .unsupported, .secureStorage:
            return .unspecified
        }
    }
}

/// Runs a real, cheap, read-only connectivity check for a brand by re-executing the same
/// session-restore path used at launch and by the background garage scan – never a fabricated
/// result. Reports the round-trip time on success, or a human-readable failure reason plus a
/// typed `failureKind`, including "no stored session" (returned without any network call).
///
/// Extracted from `AppDelegate.testConnection`; surfaced in Settings as "Test Connection".
@MainActor
final class ConnectionTester {
    private let logger = AppLog.logger("connection-test")
    private let sessionManager: SessionManager
    private let providers: ProviderRegistry
    private let preferences: PreferencesStore

    init(sessionManager: SessionManager,
         providers: ProviderRegistry,
         preferences: PreferencesStore) {
        self.sessionManager = sessionManager
        self.providers = providers
        self.preferences = preferences
    }

    func test(brand: VehicleBrand) async -> (success: Bool, message: String, failureKind: SignInFailureKind?) {
        guard preferences.hasResumableSession(for: brand) else {
            return (false, L10n.text("No active session found. Please sign in."), nil)
        }
        let start = Date()
        do {
            let provider = providers.provider(for: brand)
            let providerCars = try await sessionManager.restore(api: provider, preferences: preferences)
            guard !providerCars.isEmpty else {
                if brand == .polestar, (preferences.polestarConnectionMode == .dataPortal || preferences.polestarConnectionMode == .augmented) {
                    return (true, L10n.text("Developer Portal verified (0 vehicles linked). Link your VIN in the portal."), nil)
                }
                return (false, L10n.text("Signed in, but no vehicles were returned."), .unspecified)
            }
            let elapsedMs = Int((Date().timeIntervalSince(start) * 1000).rounded())
            return (true, L10n.format("Connection active & verified (%d ms)", elapsedMs), nil)
        } catch {
            logger.error("Connection test for \(brand.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            let mapped = VehicleServiceError.map(error, provider: brand)
            return (false, mapped.errorDescription ?? error.localizedDescription,
                    SignInFailureKind.classify(error, provider: brand))
        }
    }
}
