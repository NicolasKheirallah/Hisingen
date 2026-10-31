import AppKit
import UserNotifications

extension Notifier {
    /// Pure decision for `willPresent` so the frontmost-app behaviour stays testable:
    /// while the user is actively looking at the app, routine banners drop into the
    /// notification list silently; time-sensitive ones still surface.
    nonisolated static func presentationOptions(
        appIsActive: Bool,
        interruptionLevel: UNNotificationInterruptionLevel?
    ) -> UNNotificationPresentationOptions {
        if appIsActive && interruptionLevel != .timeSensitive { return [.list] }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // Muting is a local preference, not a vehicle command, so it bypasses the command
        // path and its gates. It can only silence the car; it never sends anything to it.
        if response.actionIdentifier == Self.muteVehicleActionID {
            let vin = response.notification.request.content.userInfo["vin"] as? String
                ?? Self.vin(fromThread: response.notification.request.content.threadIdentifier)
            Task { @MainActor [weak self] in self?.muteVehicle(vin: vin) }
            return
        }
        if let action = Self.quickAction(forResponse: response) {
            let vin = response.notification.request.content.userInfo["vin"] as? String
                ?? Self.vin(fromThread: response.notification.request.content.threadIdentifier)
            Task { @MainActor [weak self] in
                self?.onQuickAction?(action, vin)
            }
            return
        }
        // A plain tap should land the user on the vehicle the banner came from, not
        // just bring the app forward wherever it happened to leave off.
        let vin = response.notification.request.content.userInfo["vin"] as? String
            ?? Self.vin(fromThread: response.notification.request.content.threadIdentifier)
        guard !vin.isEmpty else { return }
        Task { @MainActor [weak self] in
            self?.onOpen?(vin)
        }
    }

    nonisolated static func quickAction(forResponse response: UNNotificationResponse) -> QuickAction? {
        switch response.actionIdentifier {
        case "lock-vehicle": return .lockVehicle
        case "resume-charge": return .resumeChargeSchedule
        default: return nil
        }
    }

    /// Same effect as the Settings toggle: the car's banners stop, its baselines keep advancing.
    func muteVehicle(vin: String) {
        guard !vin.isEmpty else { return }
        preferences.setMuted(true, for: vin)
        vehicleMuteDidChange(vin: vin)
    }

    nonisolated static func vin(fromThread thread: String) -> String {
        // Threads are "hisingen.<domain>.<vin>"; account-level threads carry no VIN.
        let parts = thread.split(separator: ".").map(String.init)
        guard parts.count >= 3, !["notices", "account"].contains(parts[1]) else { return "" }
        return parts.dropFirst(2).joined(separator: ".")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let interruptionLevel = notification.request.content.interruptionLevel
        let appIsActive = await MainActor.run {
            guard Bundle.main.bundleURL.pathExtension == "app" else { return false }
            return NSApp?.isActive ?? false
        }
        return Self.presentationOptions(
            appIsActive: appIsActive,
            interruptionLevel: interruptionLevel
        )
    }
}
