import AppKit
import UserNotifications


enum NotificationPermission: Sendable {
    case notDetermined
    case authorized
    case denied
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private let available = Bundle.main.bundleURL.pathExtension == "app"
    private let detector = ChargingTransitionDetector()
    private let stateStore: VehicleStateStore
    private(set) var permission: NotificationPermission = .notDetermined {
        didSet { if permission != oldValue { onPermissionChanged?(permission) } }
    }
    private var authorized: Bool { permission == .authorized }
    private var authenticationNoticePosted = false
    private var previousStateByVIN: [String: VehicleState] = [:]


    var onPermissionChanged: ((NotificationPermission) -> Void)?

    init(stateStore: VehicleStateStore) {
        self.stateStore = stateStore
        super.init()
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
    }


    func requestAuthorizationFromSettings() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
            Task { @MainActor in self?.permission = granted ? .authorized : .denied }
        }
    }

    func refreshAuthorizationStatus() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let resolved: NotificationPermission
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: resolved = .authorized
            case .denied: resolved = .denied
            case .notDetermined: resolved = .notDetermined
            @unknown default: resolved = .notDetermined
            }
            Task { @MainActor in self?.permission = resolved }
        }
    }

    func vehicleStateDidUpdate(_ state: VehicleState) {
        let previousState = previousStateByVIN[state.vin]
        previousStateByVIN[state.vin] = state
        let result = detector.evaluate(
            previous: stateStore.baseline(for: state.vin),
            current: state,
            lowBatteryThreshold: Preferences.lowBatteryThreshold
        )
        stateStore.save(result.baseline)
        guard Preferences.features.contains(.notifications), available, authorized else { return }

        for event in result.events {
            switch event {
            case .started where Preferences.notifyChargingStarted:
                post(event, state: state, title: L10n.text("Charging started"), body: chargingBody(state))
            case .completed where Preferences.notifyChargingComplete:
                post(event, state: state, title: L10n.text("Charging complete"), body: completionBody(state))
            case .fault where Preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging problem"),
                     body: privateBody(L10n.text("The vehicle reported a charging fault.")))
            case .interrupted where Preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging interrupted"),
                     body: privateBody(L10n.text("Charging stopped before the target was reached.")))
            case .lowBattery(let threshold) where Preferences.notifyLowBattery:
                post(event, state: state, title: L10n.format("Battery at %d%%", threshold),
                     body: privateBody(L10n.text("Your Polestar battery is low.")))
            default:
                break
            }
        }

        checkRainWithWindows(previous: previousState, current: state)
        checkEveningUnlocked(previous: previousState, current: state)
        checkSoftwareUpdate(previous: previousState, current: state)
        checkVehicleWarnings(previous: previousState, current: state)
    }

    private func checkSoftwareUpdate(previous: VehicleState?, current: VehicleState) {
        guard Preferences.notifySoftwareUpdates,
              let previousSoftware = previous?.softwareInfo,
              let software = current.softwareInfo,
              software.state != previousSoftware.state else { return }

        let title: String
        let body: String
        switch software.state {
        case .available, .downloaded:
            title = L10n.text("Vehicle software update available")
            body = software.version ?? software.title ?? L10n.text("Open Hisingen for details.")
        case .completed:
            title = L10n.text("Vehicle software updated")
            body = software.version ?? L10n.text("The vehicle completed its software update.")
        case .failed:
            title = L10n.text("Vehicle software update failed")
            body = L10n.text("Open Hisingen for details.")
        default:
            return
        }
        postNotice(identifier: "hisingen.\(current.vin).software", thread: "hisingen.software.\(current.vin)",
                   title: title, body: privateBody(body))
    }

    private func checkVehicleWarnings(previous: VehicleState?, current: VehicleState) {
        guard Preferences.notifyVehicleWarnings, let previous else { return }
        let previousWarnings = warningLabels(previous)
        let currentWarnings = warningLabels(current)
        let added = currentWarnings.subtracting(previousWarnings).sorted()
        if !added.isEmpty {
            postNotice(identifier: "hisingen.\(current.vin).vehicle-warnings",
                       thread: "hisingen.warnings.\(current.vin)",
                       title: L10n.text("Vehicle warning"),
                       body: privateBody(added.joined(separator: " · ")))
        }
        if current.exteriorStatus?.alarmTriggered == true,
           previous.exteriorStatus?.alarmTriggered != true {
            postNotice(identifier: "hisingen.\(current.vin).alarm",
                       thread: "hisingen.security.\(current.vin)",
                       title: L10n.text("Vehicle alarm triggered"),
                       body: privateBody(L10n.text("Open Hisingen for details.")))
        }
    }

    private func warningLabels(_ state: VehicleState) -> Set<String> {
        var labels = Set(state.healthDetails?.warnings.map(\.displayName) ?? [])
        labels.formUnion(state.fluidWarnings)
        if state.serviceWarning { labels.insert(L10n.text("Service warning")) }
        return labels
    }


    static func rainWithWindowsOpenCondition(_ state: VehicleState?) -> Bool {
        guard let state, let weather = state.weather,
              let condition = weather.condition?.lowercased(),
              (condition.contains("rain") || condition.contains("drizzle") || condition.contains("shower") || condition.contains("snow")),
              let ext = state.exteriorStatus,
              ext.itemsNeedingAttention.contains(where: { $0.displayName.lowercased().contains("window") })
        else { return false }
        return true
    }

    private func checkRainWithWindows(previous: VehicleState?, current: VehicleState) {
        guard Preferences.notifyRainWithWindowsOpen,
              Self.rainWithWindowsOpenCondition(current),
              !Self.rainWithWindowsOpenCondition(previous) else { return }

        let content = UNMutableNotificationContent()
        content.title = "🌧️ " + L10n.text("Rain Alert")
        content.body = L10n.text("Rain detected near your vehicle with windows left open!")
        content.threadIdentifier = "hisingen.weather.\(current.vin)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.\(current.vin).rain-windows", content: content, trigger: nil)
        )
    }


    static func eveningUnlockedCondition(_ state: VehicleState?) -> Bool {
        guard let state, let ext = state.exteriorStatus, ext.isLocked == false else { return false }
        let hour = Calendar.current.component(.hour, from: state.fetchedAt)
        return hour >= 21 || hour < 6
    }

    private func checkEveningUnlocked(previous: VehicleState?, current: VehicleState) {
        guard Preferences.notifyEveningUnlocked,
              Self.eveningUnlockedCondition(current),
              !Self.eveningUnlockedCondition(previous) else { return }

        let content = UNMutableNotificationContent()
        content.title = "🔒 " + L10n.text("Security Reminder")
        content.body = L10n.text("Your Polestar is parked and currently unlocked.")
        content.threadIdentifier = "hisingen.security.\(current.vin)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.\(current.vin).evening-unlocked", content: content, trigger: nil)
        )
    }

    func authenticationRequired() {
        guard Preferences.features.contains(.notifications), available, authorized,
              !authenticationNoticePosted else { return }
        authenticationNoticePosted = true
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Hisingen needs you to sign in")
        content.body = L10n.text("Open Hisingen Settings to reconnect your Polestar account.")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.authentication-required",
                                  content: content, trigger: nil)
        )
    }

    func authenticationSucceeded() {
        authenticationNoticePosted = false
        UNUserNotificationCenter.current().removeDeliveredNotifications(
            withIdentifiers: ["hisingen.authentication-required"]
        )
    }

    func featureSelectionDidChange() {
        guard available, !Preferences.features.contains(.notifications) else { return }
        authenticationNoticePosted = false
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    private func chargingBody(_ state: VehicleState) -> String {
        guard !Preferences.privateNotificationDetails else { return L10n.text("Your Polestar started charging.") }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(String(format: "%.0f%%", battery)) }
        if let minutes = state.estimatedChargingTimeToFullMinutes {
            values.append(L10n.format("full in %@", Format.shortDuration(minutes: minutes)))
        }
        return values.isEmpty ? L10n.text("Your Polestar started charging.") : values.joined(separator: " · ")
    }

    private func completionBody(_ state: VehicleState) -> String {
        guard !Preferences.privateNotificationDetails else { return L10n.text("Your Polestar finished charging.") }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(String(format: "%.0f%%", battery)) }
        if let range = state.rangeKm {
            values.append(L10n.format("%@ range", Format.distance(km: range, unit: Preferences.distanceUnit)))
        }
        return values.isEmpty ? L10n.text("Your Polestar finished charging.") : values.joined(separator: " · ")
    }

    private func privateBody(_ detailed: String) -> String {
        Preferences.privateNotificationDetails ? L10n.text("Open Hisingen for details.") : detailed
    }

    private func post(_ event: ChargingEvent, state: VehicleState, title: String, body: String) {
        postNotice(
            identifier: "hisingen.\(state.vin).\(event.identifierComponent)",
            thread: "hisingen.charging.\(state.vin)",
            title: title,
            body: body
        )
    }

    func notifyCommandNotice(title: String, body: String) {
        postNotice(
            identifier: "hisingen.notice.\(UUID().uuidString)",
            thread: "hisingen.notices",
            title: title,
            body: body
        )
    }

    private func postNotice(identifier: String, thread: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}


