import AppKit
import UserNotifications

extension Notifier {
    /// Sample banner from Settings so users can preview exactly how alerts render
    /// (privacy mode, sounds, and the vehicle subtitle included).
    func sendTestNotification() {
        guard available else { return }
        let vin = preferences.vin
        let name = vin.isEmpty ? nil : displayName(forVIN: vin)
        postNotice(identifier: "hisingen.notice.test",
                   thread: "hisingen.notices",
                   title: L10n.text("Test notification"),
                   body: privateBody(L10n.text("This is how Hisingen alerts will look.")),
                   subtitle: name, vin: vin.isEmpty ? nil : vin)
    }

    /// Vehicle display name for notification copy: user nickname when set, brand fallback.
    func displayName(for state: VehicleState) -> String {
        let nick = preferences.vehicleNickname(for: state.identity.vin)
        return nick.isEmpty ? state.model.brand.displayName : nick
    }

    func displayName(forVIN vin: String) -> String {
        let nick = preferences.vehicleNickname(for: vin)
        if !nick.isEmpty { return nick }
        if let state = previousStateByVIN[vin] { return state.model.brand.displayName }
        return preferences.activeBrand.displayName
    }

    func privateBody(_ detailed: String) -> String {
        preferences.privateNotificationDetails ? L10n.text("Open Hisingen for details.") : detailed
    }

    /// Keyed by title so a repeat of the same notice replaces the banner already on screen
    /// instead of stacking a second copy.
    func notifyCommandNotice(title: String, body: String, subtitle: String? = nil) {
        postNotice(
            identifier: "hisingen.notice.command.\(title)",
            thread: "hisingen.notices",
            title: title,
            body: body,
            subtitle: subtitle
        )
    }

    /// Quiet-hours window check: start == end means "disabled", and a window that wraps
    /// midnight (22 → 7) matches either side of the day boundary.
    nonisolated static func isQuietHour(now: Date = Date(), startHour: Int, endHour: Int) -> Bool {
        guard startHour != endHour else { return false }
        let hour = Calendar.current.component(.hour, from: now)
        if startHour < endHour { return hour >= startHour && hour < endHour }
        return hour >= startHour || hour < endHour
    }

    func postNotice(identifier: String, thread: String, title: String,
                            body: String, subtitle: String? = nil, vin: String? = nil,
                            urgency: Urgency = .info, category: String? = nil,
                            respectQuietHours: Bool = true) {
        // Every banner funnels through here, so the Notifications switch covers the notice
        // entry points too, not only the telemetry path that checks it before calling in.
        guard preferences.features.contains(.notifications) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let subtitle { content.subtitle = subtitle }
        content.threadIdentifier = thread
        if let category { content.categoryIdentifier = category }
        if let vin { content.userInfo = ["vin": vin] }
        if urgency.playsSound && preferences.notifySounds { content.sound = .default }
        content.interruptionLevel = urgency == .urgent ? .timeSensitive
            : (urgency == .background ? .passive : .active)

        let quietApplies = respectQuietHours && !urgency.bypassesQuietHours
            && preferences.quietHoursEnabled
            && Self.isQuietHour(startHour: preferences.quietHoursStartHour,
                                endHour: preferences.quietHoursEndHour)
        let trigger: UNNotificationTrigger?
        if quietApplies {
            // Hold until the window ends rather than dropping the notice entirely.
            var components = DateComponents()
            components.hour = preferences.quietHoursEndHour
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else {
            trigger = nil
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        // The add hop is async in the system API; failures are logged rather than dropped
        // silently – notification delivery is the primary anomaly channel.
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.dispatcher().add(request) }
            catch {
                self.logger.error("Notification \(identifier, privacy: .public) rejected: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
