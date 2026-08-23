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
    private let preferences: PreferencesStore
    private(set) var permission: NotificationPermission = .notDetermined {
        didSet { if permission != oldValue { onPermissionChanged?(permission) } }
    }
    private var authorized: Bool { permission == .authorized }
    private var authenticationNoticePosted = false
    private var previousStateByVIN: [String: VehicleState] = [:]
    private var sustainedConditionStartedAt: [String: Date] = [:]
    private var sustainedNotificationsDelivered = Set<String>()

    /// Handler for notification quick actions, set by the app delegate so the notifier never
    /// reaches into command dispatch itself. Receives the action identifier from the tapped
    /// banner; the notification's thread VIN is passed alongside for multi-vehicle safety.
    var onQuickAction: ((_ action: QuickAction, _ vin: String) -> Void)?

    enum QuickAction {
        case lockVehicle
        case resumeChargeSchedule
    }

    static let unlockedCategoryID = "vehicle-unlocked-actionable"
    static let chargingInterruptedCategoryID = "charging-interrupted-actionable"


    var onPermissionChanged: ((NotificationPermission) -> Void)?

    init(stateStore: VehicleStateStore, preferences: PreferencesStore) {
        self.stateStore = stateStore
        self.preferences = preferences
        super.init()
        guard available else { return }
        registerQuickActionCategories()
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorizationStatus()
    }

    /// Registers the two notification categories that carry quick actions. Actions are
    /// foreground-only on purpose: acting on a vehicle command without opening the app would
    /// bypass the same capability gates the in-app controls honour.
    private func registerQuickActionCategories() {
        let lock = UNNotificationAction(
            identifier: "lock-vehicle",
            title: L10n.text("Lock"),
            options: [.authenticationRequired]
        )
        let resume = UNNotificationAction(
            identifier: "resume-charge",
            title: L10n.text("Resume Schedule")
        )
        let unlockedCategory = UNNotificationCategory(
            identifier: Self.unlockedCategoryID,
            actions: [lock],
            intentIdentifiers: [],
            options: []
        )
        let interruptedCategory = UNNotificationCategory(
            identifier: Self.chargingInterruptedCategoryID,
            actions: [resume],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([
            unlockedCategory, interruptedCategory
        ])
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
            lowBatteryThreshold: preferences.lowBatteryThreshold
        )
        stateStore.save(result.baseline)
        guard preferences.features.contains(.notifications), available, authorized else { return }

        for event in result.events {
            switch event {
            case .started where preferences.notifyChargingStarted:
                post(event, state: state, title: L10n.text("Charging started"), body: chargingBody(state))
            case .completed where preferences.notifyChargingComplete:
                post(event, state: state, title: L10n.text("Charging complete"), body: completionBody(state))
            case .fault where preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging problem"),
                     body: privateBody(L10n.text("The vehicle reported a charging fault.")))
            case .interrupted where preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging interrupted"),
                     body: privateBody(L10n.text("Charging stopped before the target was reached.")),
                     category: Self.chargingInterruptedCategoryID)
            case .lowBattery(let threshold) where preferences.notifyLowBattery:
                let brandName = displayName(for: state)
                post(event, state: state, title: L10n.format("Battery at %d%%", threshold),
                     body: privateBody(L10n.format("Your %@ battery is low.", brandName)))
            default:
                break
            }
        }

        checkRainWithWindows(previous: previousState, current: state)
        checkEveningUnlocked(previous: previousState, current: state)
        checkLowBatteryPlugIn(previous: previousState, current: state)
        checkSoftwareUpdate(previous: previousState, current: state)
        checkVehicleWarnings(previous: previousState, current: state)
        checkOpeningsLeftOpen(current: state)
        checkServiceDue(previous: previousState, current: state)
        checkStaleTelemetry(current: state)
        checkSlowCharging(current: state)
    }

    private func checkOpeningsLeftOpen(current: VehicleState) {
        let openings = current.exteriorStatus?.itemsNeedingAttention.map(\.displayName) ?? []
        let condition = current.isEngineRunning != true && !openings.isEmpty
        trackSustained(condition: condition, key: "\(current.vin).openings", duration: 15 * 60) {
            guard self.preferences.notifyOpeningsLeftOpen else { return }
            self.postNotice(identifier: "hisingen.\(current.vin).openings-left-open",
                            thread: "hisingen.security.\(current.vin)",
                            title: L10n.text("Vehicle left open"),
                            body: self.privateBody(openings.joined(separator: " · ")))
        }
    }

    private func checkServiceDue(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyServiceDue else { return }
        let due = current.serviceWarning || (current.daysToService.map { $0 <= 30 } ?? false)
            || (current.distanceToServiceKm.map { $0 <= 1_000 } ?? false)
        let wasDue = previous?.serviceWarning == true || (previous?.daysToService.map { $0 <= 30 } ?? false)
            || (previous?.distanceToServiceKm.map { $0 <= 1_000 } ?? false)
        guard due, !wasDue else { return }
        var details: [String] = []
        if let days = current.daysToService { details.append(L10n.format("%d days", days)) }
        if let km = current.distanceToServiceKm { details.append(Format.distance(km: km, unit: preferences.distanceUnit)) }
        postNotice(identifier: "hisingen.\(current.vin).service-due", thread: "hisingen.service.\(current.vin)",
                   title: L10n.text("Vehicle service due soon"),
                   body: privateBody(details.isEmpty ? L10n.text("Open Hisingen for details.") : details.joined(separator: " · ")))
    }

    private func checkStaleTelemetry(current: VehicleState) {
        let condition = current.isStale()
        trackSustained(condition: condition, key: "\(current.vin).stale", duration: 1) {
            guard self.preferences.notifyStaleTelemetry else { return }
            self.postNotice(identifier: "hisingen.\(current.vin).stale-telemetry", thread: "hisingen.telemetry.\(current.vin)",
                            title: L10n.text("Vehicle data is stale"),
                            body: self.privateBody(current.freshnessDescription))
        }
    }

    private func checkSlowCharging(current: VehicleState) {
        let condition = current.isCharging && (current.chargingPowerWatts.map { $0 > 0 && $0 < 2_000 } ?? false)
        trackSustained(condition: condition, key: "\(current.vin).slow-charging", duration: 15 * 60) {
            guard self.preferences.notifySlowCharging else { return }
            let power = current.chargingPowerWatts.map(Format.kilowatts) ?? L10n.text("Unavailable")
            self.postNotice(identifier: "hisingen.\(current.vin).slow-charging", thread: "hisingen.charging.\(current.vin)",
                            title: L10n.text("Charging power is unusually low"), body: self.privateBody(power))
        }
    }

    private func trackSustained(condition: Bool, key: String, duration: TimeInterval,
                                action: () -> Void) {
        guard condition else {
            sustainedConditionStartedAt.removeValue(forKey: key)
            sustainedNotificationsDelivered.remove(key)
            return
        }
        let started = sustainedConditionStartedAt[key] ?? Date()
        sustainedConditionStartedAt[key] = started
        guard !sustainedNotificationsDelivered.contains(key),
              Date().timeIntervalSince(started) >= duration else { return }
        sustainedNotificationsDelivered.insert(key)
        action()
    }

    private func checkSoftwareUpdate(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifySoftwareUpdates,
              let previousSoftware = previous?.softwareInfo,
              let software = current.softwareInfo,
              software.state != previousSoftware.state else { return }

        let title: String
        let body: String
        switch software.state {
        case .available, .downloaded:
            title = L10n.text("Vehicle software update available")
            body = software.version ?? software.title ?? L10n.text("Open Hisingen for details.")
        case .scheduled:
            title = L10n.text("Vehicle software update scheduled")
            body = software.scheduledAt.map { Format.dateTimeFormatter.string(from: $0) }
                ?? L10n.text("The vehicle has an install time scheduled.")
        case .downloading:
            title = L10n.text("Vehicle software downloading")
            body = software.version ?? L10n.text("The vehicle has started downloading a software update.")
        case .installing:
            title = L10n.text("Vehicle software installing")
            body = L10n.text("The vehicle may be briefly unavailable while it installs the update.")
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
        guard preferences.notifyVehicleWarnings, let previous else { return }
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


    nonisolated static func rainWithWindowsOpenCondition(_ state: VehicleState?) -> Bool {
        guard let state, let weather = state.weather,
              let condition = weather.condition?.lowercased(),
              (condition.contains("rain") || condition.contains("drizzle") || condition.contains("shower") || condition.contains("snow")),
              let ext = state.exteriorStatus,
              ext.itemsNeedingAttention.contains(where: { $0.displayName.lowercased().contains("window") })
        else { return false }
        return true
    }

    private func checkRainWithWindows(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyRainWithWindowsOpen,
              Self.rainWithWindowsOpenCondition(current),
              !Self.rainWithWindowsOpenCondition(previous) else { return }

        // Titles stay emoji-free across all notification builders for visual consistency;
        // the charging/security semantics live in the thread identifiers and actions.
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Rain Alert")
        content.body = privateBody(L10n.text("Rain detected near your vehicle with windows left open!"))
        content.threadIdentifier = "hisingen.weather.\(current.vin)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.\(current.vin).rain-windows", content: content, trigger: nil)
        )
    }


    nonisolated static func eveningUnlockedCondition(_ state: VehicleState?) -> Bool {
        guard let state, let ext = state.exteriorStatus, ext.isLocked == false else { return false }
        let hour = Calendar.current.component(.hour, from: state.fetchedAt)
        return hour >= 21 || hour < 6
    }

    private func checkEveningUnlocked(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyEveningUnlocked,
              Self.eveningUnlockedCondition(current),
              !Self.eveningUnlockedCondition(previous) else { return }

        let brandName = current.model.brand.displayName
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Security Reminder")
        content.body = privateBody(L10n.format("Your %@ is parked and currently unlocked.", brandName))
        content.threadIdentifier = "hisingen.security.\(current.vin)"
        content.categoryIdentifier = Self.unlockedCategoryID
        content.userInfo = ["vin": current.vin]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.\(current.vin).evening-unlocked", content: content, trigger: nil)
        )
    }

    nonisolated static func plugInReminderCondition(_ state: VehicleState?) -> Bool {
        guard let state, state.powertrain.hasElectricRange,
              let battery = state.batteryPercentage, battery <= 40.0,
              state.chargerConnection == .disconnected, !state.isCharging else { return false }
        return true
    }

    private func checkLowBatteryPlugIn(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyPlugInReminder,
              Self.plugInReminderCondition(current),
              !Self.plugInReminderCondition(previous) else { return }

        let brandTitle = displayName(for: current)
        let detailedBody = current.batteryPercentage.map {
            L10n.format("Your %@ is parked at %.0f%% and unplugged. Connect to a charger to ensure departure range.", brandTitle, $0)
        } ?? L10n.format("Your %@ is parked and unplugged. Connect to a charger to ensure departure range.", brandTitle)
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Plug-In Reminder")
        content.body = privateBody(detailedBody)
        content.threadIdentifier = "hisingen.charging.\(current.vin)"
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "hisingen.\(current.vin).plugin-reminder", content: content, trigger: nil)
        )
    }

    func authenticationRequired() {
        guard preferences.features.contains(.notifications), available, authorized,
              !authenticationNoticePosted else { return }
        authenticationNoticePosted = true
        let brandName = preferences.activeBrand.displayName
        let content = UNMutableNotificationContent()
        content.title = L10n.text("Hisingen needs you to sign in")
        content.body = L10n.format("Open Hisingen Settings to reconnect your %@ account.", brandName)
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
        guard available, !preferences.features.contains(.notifications) else { return }
        authenticationNoticePosted = false
        let center = UNUserNotificationCenter.current()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    private func chargingBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        guard !preferences.privateNotificationDetails else { return L10n.format("Your %@ started charging.", brandName) }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(String(format: "%.0f%%", battery)) }
        if let minutes = state.estimatedChargingTimeToFullMinutes {
            values.append(L10n.format("full in %@", Format.shortDuration(minutes: minutes)))
        }
        return values.isEmpty ? L10n.format("Your %@ started charging.", brandName) : values.joined(separator: " · ")
    }

    private func completionBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        guard !preferences.privateNotificationDetails else { return L10n.format("Your %@ finished charging.", brandName) }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(String(format: "%.0f%%", battery)) }
        if let range = state.rangeKm {
            values.append(L10n.format("%@ range", Format.distance(km: range, unit: preferences.distanceUnit)))
        }
        return values.isEmpty ? L10n.format("Your %@ finished charging.", brandName) : values.joined(separator: " · ")
    }

    /// Vehicle display name for notification copy: user nickname when set, brand fallback.
    private func displayName(for state: VehicleState) -> String {
        let nick = preferences.vehicleNickname(for: state.vin)
        return nick.isEmpty ? state.model.brand.displayName : nick
    }

    private func privateBody(_ detailed: String) -> String {
        preferences.privateNotificationDetails ? L10n.text("Open Hisingen for details.") : detailed
    }

    private func post(_ event: ChargingEvent, state: VehicleState, title: String,
                      body: String, category: String? = nil) {
        postNotice(
            identifier: "hisingen.\(state.vin).\(event.identifierComponent)",
            thread: "hisingen.charging.\(state.vin)",
            title: title,
            body: body,
            category: category,
            vin: state.vin
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

    private func postNotice(identifier: String, thread: String, title: String,
                            body: String, category: String? = nil, vin: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.threadIdentifier = thread
        if let category { content.categoryIdentifier = category }
        if let vin { content.userInfo = ["vin": vin] }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let action = Self.quickAction(forResponse: response) else { return }
        let vin = response.notification.request.content.userInfo["vin"] as? String
            ?? Self.vin(fromThread: response.notification.request.content.threadIdentifier)
        Task { @MainActor [weak self] in
            self?.onQuickAction?(action, vin)
        }
    }

    nonisolated static func quickAction(forResponse response: UNNotificationResponse) -> QuickAction? {
        switch response.actionIdentifier {
        case "lock-vehicle": return .lockVehicle
        case "resume-charge": return .resumeChargeSchedule
        default: return nil
        }
    }

    nonisolated static func vin(fromThread thread: String) -> String {
        // Threads are "hisingen.<domain>.<vin>".
        guard let vin = thread.split(separator: ".").last else { return "" }
        return String(vin)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
