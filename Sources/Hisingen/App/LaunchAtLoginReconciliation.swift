import ServiceManagement

/// The decision the app shell makes on every launch (and whenever the user toggles
/// "Launch at login") about how to line the macOS login-item registration up with
/// the user's stored intent.
///
/// Pulled out of `AppDelegate` as a pure function because the previous inline
/// version wrote `preferences.launchAtLogin` straight from `SMAppService.status`.
/// An app update, move, or re-sign invalidates that registration —
/// `SMAppService.mainApp` is bound to the bundle's code signature, and a
/// locally-built copy is ad-hoc signed with a fresh hash every build — so the
/// first launch after a replace saw `.notFound` and silently turned the setting
/// off. Here the intent is only ever an input; the output moves the *registration*
/// toward it, never the other way.
enum LaunchAtLoginReconciliation: Equatable {
    /// Nothing to do — the registration already matches the intent.
    case none
    /// (Re-)register the main app as a login item. Also the post-update recovery
    /// path: `.notFound` means the old registration no longer matches this bundle.
    case register
    /// Remove the login-item registration.
    case unregister
    /// Open System Settings ▸ General ▸ Login Items so the user can approve a
    /// registration macOS is holding in `.requiresApproval`.
    case promptForApproval
    /// Startup only: the registration is live but the stored intent reads off — a
    /// signature only the old destructive reconcile produced (a genuine opt-out
    /// unregisters first, and it would be `userInitiated`). Restore the intent to
    /// on; leave the registration alone.
    case restoreClearedIntent

    /// - Parameters:
    ///   - intent: `preferences.launchAtLogin` — what the user asked for.
    ///   - status: the current `SMAppService.mainApp.status`.
    ///   - userInitiated: whether this reconcile is a direct response to the user
    ///     toggling the setting (only then is it appropriate to bounce them to
    ///     System Settings).
    static func resolve(
        intent: Bool,
        status: SMAppService.Status,
        userInitiated: Bool
    ) -> LaunchAtLoginReconciliation {
        guard intent else {
            // A user turning the setting off (always `userInitiated`) must be
            // honoured. The same shape on an automatic reconcile instead means a
            // past build wiped the preference while the login item stayed
            // registered — recover it rather than tearing the registration down.
            if status == .enabled {
                return userInitiated ? .unregister : .restoreClearedIntent
            }
            return status == .requiresApproval ? .unregister : .none
        }

        switch status {
        case .enabled:
            return .none
        case .notRegistered, .notFound:
            return .register
        case .requiresApproval:
            return userInitiated ? .promptForApproval : .none
        @unknown default:
            return .none
        }
    }
}
