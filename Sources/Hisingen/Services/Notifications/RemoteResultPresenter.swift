import Foundation
import UserNotifications

/// Posts a transient command / sign-in outcome through `UNUserNotificationCenter`, so it
/// follows the user's system notification settings. Successful outcomes self-clean after
/// 5 seconds; failures persist until dismissed — a failure that disappears early reads as
/// "the command worked".
///
/// Extracted from `AppDelegate.showRemoteResult`, which both the remote-command pipeline
/// (`CommandCoordinator`) and the sign-in flows (`SignInCoordinator`) had reason to call.
struct RemoteResultPresenter {
    func present(title: String, message: String, success: Bool, subtitle: String? = nil) {
        let identifier = "remote-command-\(UUID().uuidString)"
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        if let subtitle { content.subtitle = subtitle }
        if !success { content.sound = .default }

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )

        // Successes self-clean after 5 seconds; failures persist until dismissed.
        guard success else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }
}
