import Foundation

/// What the update controller needs from the app shell: the status-item badge (an available
/// version to advertise, a "checking…" spinner) and a re-render request.
@MainActor
protocol UpdateControllerContext: AnyObject {
    func setAvailableUpdateVersion(_ version: String?)
    func setCheckingForUpdates(_ checking: Bool)
    func updateStateDidChange()
}

/// Owns the Sparkle-backed `UpdateService` and its mediation to the status item: feature-gated
/// automatic checking, the manual "Check for Updates…" action, and translating update-cycle
/// state into the badge / spinner the menu shows.
///
/// Extracted from `AppDelegate` (`updateCheckConfiguration` / `checkForUpdates` /
/// `updateStateChanged`).
@MainActor
final class UpdateController {
    private let updateService = UpdateService()
    private let preferences: PreferencesStore
    private weak var context: (any UpdateControllerContext)?

    init(context: any UpdateControllerContext, preferences: PreferencesStore) {
        self.context = context
        self.preferences = preferences
        updateService.onStateChanged = { [weak self] state in self?.handleStateChange(state) }
    }

    /// Applies the current feature / auto-check preferences to the updater. When update checks
    /// are disabled entirely it also clears any stale "update available" badge.
    func applyConfiguration() {
        if preferences.features.contains(.updateChecks) {
            updateService.start(
                automaticallyChecks: preferences.automaticallyChecksForUpdates,
                automaticallyDownloads: preferences.automaticallyDownloadsUpdates
            )
        } else {
            updateService.configure(automaticallyChecks: false, automaticallyDownloads: false)
            context?.setAvailableUpdateVersion(nil)
        }
    }

    /// Manual "Check for Updates…" — a no-op when the updates feature is off.
    func checkNow() {
        guard preferences.features.contains(.updateChecks) else { return }
        updateService.checkForUpdates()
    }

    private func handleStateChange(_ state: UpdateService.State) {
        switch state {
        case .idle:
            context?.setAvailableUpdateVersion(nil)
            context?.setCheckingForUpdates(false)
        case .checking:
            context?.setCheckingForUpdates(true)
        case .updateAvailable(let update):
            context?.setAvailableUpdateVersion(update.marketingVersion)
            context?.setCheckingForUpdates(false)
        case .failed:
            context?.setCheckingForUpdates(false)
        }
        context?.updateStateDidChange()
    }
}
