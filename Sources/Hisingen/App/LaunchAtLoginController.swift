import Foundation
import OSLog
import ServiceManagement

/// Reconciles the macOS login-item registration with the user's stored intent.
///
/// `preferences.launchAtLogin` is the single source of truth for what the user wants; the
/// `SMAppService` registration is separate OS state that an app update, move, or re-sign
/// invalidates (`SMAppService.mainApp` is bound to the bundle's code signature, and
/// locally-built copies are ad-hoc signed with a fresh hash every build). `reconcile` only
/// moves the *registration* toward the *intent* — the decision lives in
/// ``LaunchAtLoginReconciliation/resolve(intent:status:userInitiated:)`` so it never writes
/// the intent from `status`, which is what made the first launch after every replace silently
/// forget the setting.
///
/// Extracted from `AppDelegate.applyLaunchAtLogin`.
@MainActor
final class LaunchAtLoginController {
    private let logger = AppLog.logger("launch-at-login")
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) {
        self.preferences = preferences
    }

    func reconcile(userInitiated: Bool) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        let status = service.status
        let action = LaunchAtLoginReconciliation.resolve(
            intent: preferences.launchAtLogin, status: status, userInitiated: userInitiated
        )
        switch action {
        case .none:
            break
        case .restoreClearedIntent:
            // The login item is still enabled but the preference reads off — only the
            // old destructive reconcile produced that; a real opt-out unregisters.
            preferences.launchAtLogin = true
        case .register:
            // `.notFound` is the post-update state: the registration points at a
            // bundle whose signature/location no longer matches. Re-register for the
            // current bundle instead of giving up on the setting. A failure here
            // (disk image, ~/Downloads, App Translocation) keeps the stored intent so
            // the next launch from /Applications self-heals.
            do { try service.register() }
            catch {
                logger.error("Launch-at-login register failed (status \(String(describing: status), privacy: .public)): \(String(describing: error), privacy: .public)")
            }
        case .unregister:
            do { try service.unregister() }
            catch {
                logger.error("Launch-at-login unregister failed: \(String(describing: error), privacy: .public)")
            }
        case .promptForApproval:
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
