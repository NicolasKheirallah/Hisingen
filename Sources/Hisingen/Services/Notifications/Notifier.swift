import AppKit
import UserNotifications


enum NotificationPermission: Sendable {
    case notDetermined
    case authorized
    case denied
}

/// Abstraction over `UNUserNotificationCenter` so posting logic is unit-testable.
/// The production conformant is the shared center; tests inject an in-memory fake.
@MainActor
protocol NotificationDispatching: AnyObject {
    func add(_ request: UNNotificationRequest)
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removeAllDeliveredNotifications()
    func removeAllPendingNotificationRequests()
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

/// Wraps the shared center. Deliberately synchronous from the caller's perspective:
/// `UNUserNotificationCenter.add(_:)`'s completion variant is deprecated, so the add
/// hop wraps the async API in a task.
@MainActor
final class SystemNotificationDispatcher: NotificationDispatching {
    private let center = UNUserNotificationCenter.current()
    func add(_ request: UNNotificationRequest) {
        Task { @MainActor in
            try? await center.add(request)
        }
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func removeAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }
    func removeAllPendingNotificationRequests() {
        center.removeAllPendingNotificationRequests()
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Instance wired to live telemetry, for settings surfaces (test notification).
    private(set) static var shared: Notifier?

    private let available: Bool
    private let detector = ChargingTransitionDetector()
    private let stateStore: VehicleStateStore
    private let preferences: PreferencesStore
    private let defaults: UserDefaults
    private let dispatcher: () -> any NotificationDispatching
    private(set) var permission: NotificationPermission {
        didSet { if permission != oldValue { onPermissionChanged?(permission) } }
    }
    private var authorized: Bool { permission == .authorized }
    private var authenticationNoticePostedByBrand: [String: Bool] = [:]
    private var previousStateByVIN: [String: VehicleState] = [:]
    private var sustainedConditionStartedAt: [String: Date]
    private var sustainedNotificationsDelivered: Set<String>
    private var serviceDueByVIN: [String: Bool]
    private var warningVehicles = Set<String>()
    private var sustainedRecheckTimer: Timer?

    /// Fires whenever the authorization state changes (settings surfaces listen).
    var onPermissionChanged: ((NotificationPermission) -> Void)?

    /// Handler for notification quick actions, set by the app delegate so the notifier never
    /// reaches into command dispatch itself. Receives the action identifier from the tapped
    /// banner; the notification's thread VIN is passed alongside for multi-vehicle safety.
    var onQuickAction: ((_ action: QuickAction, _ vin: String) -> Void)?

    /// Handler for plain banner taps: opens the app focused on the tapped vehicle.
    var onOpen: ((_ vin: String) -> Void)?

    /// Fires whenever the number of vehicles reporting warnings/alarm changes, so the
    /// host can render an optional dock badge.
    var onWarningVehicleCountChanged: ((Int) -> Void)?

    enum QuickAction {
        case lockVehicle
        case resumeChargeSchedule
    }

    static let unlockedCategoryID = "vehicle-unlocked-actionable"
    static let chargingInterruptedCategoryID = "charging-interrupted-actionable"

    /// How intrusive a notification should be. Urgent security banners break through
    /// Focus and quiet hours; routine telemetry chatter stays passive and silent.
    enum Urgency {
        case urgent      // time-sensitive + sound; bypasses quiet hours
        case attention   // sound; respects quiet hours
        case info        // silent; respects quiet hours
        case background  // silent + passive interruption level; respects quiet hours

        var playsSound: Bool { self == .urgent || self == .attention }
        var bypassesQuietHours: Bool { self == .urgent }
    }

    init(stateStore: VehicleStateStore,
         preferences: PreferencesStore,
         defaults: UserDefaults = .standard,
         dispatcher: @autoclosure @escaping () -> any NotificationDispatching = SystemNotificationDispatcher(),
         availableOverride: Bool? = nil,
         initialPermission: NotificationPermission? = nil,
         configuresSystemIntegration: Bool = true) {
        self.available = availableOverride ?? (Bundle.main.bundleURL.pathExtension == "app")
        self.stateStore = stateStore
        self.preferences = preferences
        self.defaults = defaults
        self.dispatcher = dispatcher
        self.permission = initialPermission ?? .notDetermined
        let starts = (defaults.dictionary(forKey: "notifier_sustained_starts_v1") as? [String: Double]) ?? [:]
        self.sustainedConditionStartedAt = starts.mapValues(Date.init(timeIntervalSince1970:))
        self.sustainedNotificationsDelivered = Set(defaults.stringArray(forKey: "notifier_sustained_delivered_v1") ?? [])
        self.serviceDueByVIN = (defaults.dictionary(forKey: "notifier_service_due_v1") as? [String: Bool]) ?? [:]
        super.init()
        guard available else { return }
        if configuresSystemIntegration {
            registerQuickActionCategories()
            UNUserNotificationCenter.current().delegate = self
            refreshAuthorizationStatus()
            Self.shared = self
            startSustainedRecheckTimer()
        }
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
        // Resuming a schedule is a write command too, so it demands the same explicit
        // device unlock the lock action does — consistent capability gates.
        let resume = UNNotificationAction(
            identifier: "resume-charge",
            title: L10n.text("Resume Schedule"),
            options: [.authenticationRequired]
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
        dispatcher().setNotificationCategories([
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

        updateWarningVehicleCount(state: state)

        // Muted vehicles keep their baselines advancing above, so un-muting never
        // replays a burst of stale edge events accumulated during the quiet period.
        guard preferences.features.contains(.notifications), available, authorized,
              !preferences.isMuted(vin: state.vin) else { return }

        for event in result.events {
            switch event {
            case .started where preferences.notifyChargingStarted:
                post(event, state: state, title: L10n.text("Charging started"), body: chargingBody(state))
            case .completed where preferences.notifyChargingComplete:
                post(event, state: state, title: L10n.text("Charging complete"), body: completionBody(state))
            case .fault where preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging problem"),
                     body: privateBody(L10n.text("The vehicle reported a charging fault.")),
                     urgency: .attention)
            case .interrupted where preferences.notifyChargingProblem:
                post(event, state: state, title: L10n.text("Charging interrupted"),
                     body: privateBody(L10n.text("Charging stopped before the target was reached.")),
                     urgency: .attention,
                     category: Self.chargingInterruptedCategoryID)
            case .lowBattery(let threshold) where preferences.notifyLowBattery:
                post(event, state: state, title: L10n.format("Battery at %d%%", threshold),
                     body: lowBatteryBody(state),
                     urgency: .attention)
            default:
                break
            }
        }

        checkChargerConnection(previous: previousState, current: state)
        checkClimateChanges(previous: previousState, current: state)
        checkRainWithWindows(previous: previousState, current: state)
        checkEveningUnlocked(previous: previousState, current: state)
        checkLowBatteryPlugIn(previous: previousState, current: state)
        checkSoftwareUpdate(previous: previousState, current: state)
        checkVehicleWarnings(previous: previousState, current: state)
        checkServiceDue(current: state)
        checkSlowCharging(current: state)
        checkStaleTelemetry(current: state)
        checkOpeningsLeftOpen(current: state)
    }

    /// Re-evaluates conditions that depend on wall-clock time rather than fresh
    /// telemetry, so a parked-open car still escalates even if polling stalls.
    private func recheckSustainedConditions() {
        guard available, authorized, preferences.features.contains(.notifications) else { return }
        for state in previousStateByVIN.values where !preferences.isMuted(vin: state.vin) {
            checkOpeningsLeftOpen(current: state)
            checkSlowCharging(current: state)
            checkStaleTelemetry(current: state)
        }
    }

    private func startSustainedRecheckTimer() {
        guard available else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recheckSustainedConditions() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sustainedRecheckTimer = timer
    }

    private func updateWarningVehicleCount(state: VehicleState) {
        let hasWarning = !warningLabels(state).isEmpty || state.exteriorStatus?.alarmTriggered == true
        let changed: Bool
        if hasWarning {
            changed = warningVehicles.insert(state.vin).inserted
        } else {
            changed = warningVehicles.remove(state.vin) != nil
        }
        if changed { onWarningVehicleCountChanged?(warningVehicles.count) }
    }

    private func checkChargerConnection(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyChargerConnection,
              let previous, previous.vin == current.vin else { return }
        let wasConnected = previous.chargerConnection == .connected
        let isConnected = current.chargerConnection == .connected
        guard isConnected != wasConnected else { return }
        if isConnected {
            postNotice(identifier: "hisingen.\(current.vin).cable-connected",
                       thread: "hisingen.charging.\(current.vin)",
                       title: L10n.text("Cable connected"),
                       body: privateBody(cableBody(battery: current.batteryPercentage)),
                       subtitle: displayName(for: current), vin: current.vin)
        } else {
            postNotice(identifier: "hisingen.\(current.vin).cable-disconnected",
                       thread: "hisingen.charging.\(current.vin)",
                       title: L10n.text("Cable disconnected"),
                       body: privateBody(L10n.text("Charging cable disconnected.")),
                       subtitle: displayName(for: current), vin: current.vin)
        }
    }

    private func checkClimateChanges(previous: VehicleState?, current: VehicleState) {
        guard preferences.notifyClimateChanges,
              let previousActivity = previous?.climateStatus?.activity,
              let currentActivity = current.climateStatus?.activity,
              currentActivity != previousActivity else { return }
        let wasActive = previousActivity.isActiveClimate
        let isActive = currentActivity.isActiveClimate
        guard isActive != wasActive else { return }
        if isActive {
            postNotice(identifier: "hisingen.\(current.vin).climate-started",
                       thread: "hisingen.climate.\(current.vin)",
                       title: L10n.text("Climate started"),
                       body: privateBody(L10n.text("Cabin climate is now active.")),
                       subtitle: displayName(for: current), vin: current.vin)
        } else {
            postNotice(identifier: "hisingen.\(current.vin).climate-stopped",
                       thread: "hisingen.climate.\(current.vin)",
                       title: L10n.text("Climate stopped"),
                       body: privateBody(L10n.text("Cabin climate has turned off.")),
                       subtitle: displayName(for: current), vin: current.vin)
        }
    }

    private func checkOpeningsLeftOpen(current: VehicleState) {
        let openings = current.exteriorStatus?.itemsNeedingAttention.map(\.displayName) ?? []
        let condition = current.isEngineRunning != true && !openings.isEmpty
        trackSustained(condition: condition, key: "\(current.vin).openings", duration: 15 * 60) {
            guard self.preferences.notifyOpeningsLeftOpen else { return }
            self.postNotice(identifier: "hisingen.\(current.vin).openings-left-open",
                            thread: "hisingen.security.\(current.vin)",
                            title: L10n.text("Vehicle left open"),
                            body: self.privateBody(openings.joined(separator: " · ")),
                            subtitle: self.displayName(for: current),
                            vin: current.vin,
                            urgency: .urgent)
        }
    }

    private func checkServiceDue(current: VehicleState) {
        guard preferences.notifyServiceDue else { return }
        let due = current.serviceWarning || (current.daysToService.map { $0 <= 30 } ?? false)
            || (current.distanceToServiceKm.map { $0 <= 1_000 } ?? false)
        // The was-due flag persists across launches: without it, staying due re-fired
        // the banner on every relaunch because the in-memory previous state was empty.
        let wasDue = serviceDueByVIN[current.vin] ?? false
        serviceDueByVIN[current.vin] = due
        defaults.set(serviceDueByVIN, forKey: "notifier_service_due_v1")
        guard due, !wasDue else { return }
        var details: [String] = []
        if let days = current.daysToService { details.append(L10n.format("%d days", days)) }
        if let km = current.distanceToServiceKm { details.append(Format.distance(km: km, unit: preferences.distanceUnit)) }
        postNotice(identifier: "hisingen.\(current.vin).service-due", thread: "hisingen.service.\(current.vin)",
                   title: L10n.text("Vehicle service due soon"),
                   body: privateBody(details.isEmpty ? L10n.text("Open Hisingen for details.") : details.joined(separator: " · ")),
                   subtitle: displayName(for: current), vin: current.vin,
                   urgency: .background)
    }

    private func checkStaleTelemetry(current: VehicleState) {
        let condition = current.isStale()
        trackSustained(condition: condition, key: "\(current.vin).stale", duration: 1) {
            guard self.preferences.notifyStaleTelemetry else { return }
            self.postNotice(identifier: "hisingen.\(current.vin).stale-telemetry", thread: "hisingen.telemetry.\(current.vin)",
                            title: L10n.text("Vehicle data is stale"),
                            body: self.privateBody(current.freshnessDescription),
                            subtitle: self.displayName(for: current), vin: current.vin,
                            urgency: .background)
        }
    }

    private func checkSlowCharging(current: VehicleState) {
        let condition = current.isCharging && (current.chargingPowerWatts.map { $0 > 0 && $0 < 2_000 } ?? false)
        trackSustained(condition: condition, key: "\(current.vin).slow-charging", duration: 15 * 60) {
            guard self.preferences.notifySlowCharging else { return }
            let power = current.chargingPowerWatts.map(Format.kilowatts) ?? L10n.text("Unavailable")
            self.postNotice(identifier: "hisingen.\(current.vin).slow-charging", thread: "hisingen.charging.\(current.vin)",
                            title: L10n.text("Charging power is unusually low"), body: self.privateBody(power),
                            subtitle: self.displayName(for: current), vin: current.vin,
                            urgency: .background)
        }
    }

    private func trackSustained(condition: Bool, key: String, duration: TimeInterval,
                                action: () -> Void) {
        guard condition else {
            if sustainedConditionStartedAt.removeValue(forKey: key) != nil {
                persistSustainedState()
            }
            if sustainedNotificationsDelivered.remove(key) != nil {
                persistSustainedState()
            }
            return
        }
        let started = sustainedConditionStartedAt[key] ?? Date()
        sustainedConditionStartedAt[key] = started
        guard !sustainedNotificationsDelivered.contains(key),
              Date().timeIntervalSince(started) >= duration else { return }
        sustainedNotificationsDelivered.insert(key)
        persistSustainedState()
        action()
    }

    private func persistSustainedState() {
        defaults.set(sustainedConditionStartedAt.mapValues { $0.timeIntervalSince1970 },
                     forKey: "notifier_sustained_starts_v1")
        defaults.set(Array(sustainedNotificationsDelivered), forKey: "notifier_sustained_delivered_v1")
    }

    /// Called when a vehicle's mute state flips so lingering sustained timers for that
    /// car don't fire the moment it is un-muted.
    func vehicleMuteDidChange(vin: String) {
        let prefix = "\(vin)."
        sustainedConditionStartedAt = sustainedConditionStartedAt.filter { !$0.key.hasPrefix(prefix) }
        sustainedNotificationsDelivered = sustainedNotificationsDelivered.filter { !$0.hasPrefix(prefix) }
        persistSustainedState()
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
            body = software.version.map { L10n.format("Installing version %@.", $0) }
                ?? L10n.text("The vehicle may be briefly unavailable while it installs the update.")
        case .completed:
            title = L10n.text("Vehicle software updated")
            body = software.version ?? L10n.text("The vehicle completed its software update.")
        case .failed:
            title = L10n.text("Vehicle software update failed")
            body = software.version.map { L10n.format("Update to %@ failed.", $0) }
                ?? L10n.text("Open Hisingen for details.")
        default:
            return
        }
        postNotice(identifier: "hisingen.\(current.vin).software", thread: "hisingen.software.\(current.vin)",
                   title: title, body: privateBody(body), subtitle: displayName(for: current),
                   vin: current.vin, urgency: .background)
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
                       body: privateBody(added.joined(separator: " · ")),
                       subtitle: displayName(for: current), vin: current.vin,
                       urgency: .urgent)
        }
        if current.exteriorStatus?.alarmTriggered == true,
           previous.exteriorStatus?.alarmTriggered != true {
            postNotice(identifier: "hisingen.\(current.vin).alarm",
                       thread: "hisingen.security.\(current.vin)",
                       title: L10n.text("Vehicle alarm triggered"),
                       body: privateBody(L10n.text("Open Hisingen for details.")),
                       subtitle: displayName(for: current), vin: current.vin,
                       urgency: .urgent)
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
        postNotice(identifier: "hisingen.\(current.vin).rain-windows",
                   thread: "hisingen.weather.\(current.vin)",
                   title: L10n.text("Rain Alert"),
                   body: privateBody(L10n.text("Rain detected near your vehicle with windows left open!")),
                   subtitle: displayName(for: current), vin: current.vin,
                   urgency: .urgent)
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

        let body: String
        if preferences.privateNotificationDetails {
            body = L10n.text("Parked and currently unlocked.")
        } else {
            body = L10n.format("Your %@ is parked and currently unlocked.", displayName(for: current))
        }
        postNotice(identifier: "hisingen.\(current.vin).evening-unlocked",
                   thread: "hisingen.security.\(current.vin)",
                   title: L10n.text("Security Reminder"),
                   body: privateBody(body),
                   subtitle: displayName(for: current), vin: current.vin,
                   urgency: .urgent,
                   category: Self.unlockedCategoryID)
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

        let name = displayName(for: current)
        let detailedBody: String
        if preferences.privateNotificationDetails {
            detailedBody = L10n.text("Parked and unplugged. Connect to a charger to ensure departure range.")
        } else if let battery = current.batteryPercentage {
            detailedBody = L10n.format("Parked at %.0f%% and unplugged. Connect to a charger to ensure departure range.", battery)
        } else {
            detailedBody = L10n.text("Parked and unplugged. Connect to a charger to ensure departure range.")
        }
        postNotice(identifier: "hisingen.\(current.vin).plugin-reminder",
                   thread: "hisingen.charging.\(current.vin)",
                   title: L10n.text("Plug-In Reminder"),
                   body: privateBody(detailedBody),
                   subtitle: name, vin: current.vin)
    }

    func authenticationRequired() {
        guard preferences.features.contains(.notifications), available, authorized else { return }
        // Latch per brand: a Polestar sign-out must not suppress the Volvo one, and the
        // brand in the copy must be the account that actually failed, not whichever is
        // active when a second error arrives.
        let brand = preferences.activeBrand
        guard authenticationNoticePostedByBrand[brand.rawValue] != true else { return }
        authenticationNoticePostedByBrand[brand.rawValue] = true
        let brandName = brand.displayName
        postNotice(identifier: "hisingen.authentication-required",
                   thread: "hisingen.account.\(brand.rawValue)",
                   title: L10n.text("Hisingen needs you to sign in"),
                   body: L10n.format("Open Hisingen Settings to reconnect your %@ account.", brandName),
                   subtitle: brandName, urgency: .attention,
                   respectQuietHours: false)
    }

    func authenticationSucceeded() {
        authenticationNoticePostedByBrand.removeAll()
        dispatcher().removeDeliveredNotifications(
            withIdentifiers: ["hisingen.authentication-required"]
        )
    }

    func featureSelectionDidChange() {
        guard available, !preferences.features.contains(.notifications) else { return }
        authenticationNoticePostedByBrand.removeAll()
        let center = dispatcher()
        center.removeAllDeliveredNotifications()
        center.removeAllPendingNotificationRequests()
    }

    /// Sample banner from Settings so users can preview exactly how alerts render
    /// (privacy mode, sounds, and the vehicle subtitle included).
    func sendTestNotification() {
        guard available else { return }
        let vin = preferences.vin
        let name = vin.isEmpty ? nil : displayName(forVIN: vin)
        postNotice(identifier: "hisingen.notice.test-\(UUID().uuidString)",
                   thread: "hisingen.notices",
                   title: L10n.text("Test notification"),
                   body: privateBody(L10n.text("This is how Hisingen alerts will look.")),
                   subtitle: name, vin: vin.isEmpty ? nil : vin)
    }

    private func chargingBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        // Private mode keeps the banner anonymous now that the subtitle carries the
        // vehicle name — repeating it here said the same thing twice.
        guard !preferences.privateNotificationDetails else { return L10n.text("Started charging.") }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(percentText(battery)) }
        if let minutes = state.estimatedChargingTimeToFullMinutes {
            values.append(L10n.format("full in %@", Format.shortDuration(minutes: minutes)))
        }
        return values.isEmpty ? L10n.format("Your %@ started charging.", brandName) : values.joined(separator: " · ")
    }

    private func completionBody(_ state: VehicleState) -> String {
        let brandName = displayName(for: state)
        guard !preferences.privateNotificationDetails else { return L10n.text("Finished charging.") }
        var values: [String] = []
        if let battery = state.batteryPercentage { values.append(percentText(battery)) }
        if let range = state.rangeKm {
            values.append(L10n.format("%@ range", Format.distance(km: range, unit: preferences.distanceUnit)))
        }
        return values.isEmpty ? L10n.format("Your %@ finished charging.", brandName) : values.joined(separator: " · ")
    }

    private func lowBatteryBody(_ state: VehicleState) -> String {
        preferences.privateNotificationDetails
            ? L10n.text("Battery is low.")
            : L10n.format("Your %@ battery is low.", displayName(for: state))
    }

    private func cableBody(battery: Double?) -> String {
        guard let battery else { return L10n.text("Charging cable connected.") }
        return L10n.format("Charging cable connected. %@", percentText(battery))
    }

    /// Vehicle display name for notification copy: user nickname when set, brand fallback.
    private func displayName(for state: VehicleState) -> String {
        let nick = preferences.vehicleNickname(for: state.vin)
        return nick.isEmpty ? state.model.brand.displayName : nick
    }

    private func displayName(forVIN vin: String) -> String {
        let nick = preferences.vehicleNickname(for: vin)
        if !nick.isEmpty { return nick }
        if let state = previousStateByVIN[vin] { return state.model.brand.displayName }
        return preferences.activeBrand.displayName
    }

    private func percentText(_ battery: Double) -> String {
        L10n.format("%.0f%%", battery)
    }

    private func privateBody(_ detailed: String) -> String {
        preferences.privateNotificationDetails ? L10n.text("Open Hisingen for details.") : detailed
    }

    private func post(_ event: ChargingEvent, state: VehicleState, title: String,
                      body: String, urgency: Urgency = .info, category: String? = nil) {
        postNotice(
            identifier: "hisingen.\(state.vin).\(event.identifierComponent)",
            thread: "hisingen.charging.\(state.vin)",
            title: title,
            body: body,
            subtitle: displayName(for: state),
            vin: state.vin,
            urgency: urgency,
            category: category
        )
    }

    func notifyCommandNotice(title: String, body: String, subtitle: String? = nil) {
        postNotice(
            identifier: "hisingen.notice.\(UUID().uuidString)",
            thread: "hisingen.notices",
            title: title,
            body: body,
            subtitle: subtitle
        )
    }

    /// Per-session anomaly banner. Location names are personal data, so the body goes
    /// through the same privacy gate as vehicle telemetry banners.
    func notifyChargingAnomaly(locationName: String, vin: String) {
        postNotice(
            identifier: "hisingen.notice.\(UUID().uuidString)",
            thread: "hisingen.charging.\(vin)",
            title: L10n.text("Unusually slow charging"),
            body: privateBody(L10n.format("Peak power at %@ was far below this location's usual level — the cable or charger may be derating.", locationName)),
            subtitle: displayName(forVIN: vin),
            vin: vin
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

    private func postNotice(identifier: String, thread: String, title: String,
                            body: String, subtitle: String? = nil, vin: String? = nil,
                            urgency: Urgency = .info, category: String? = nil,
                            respectQuietHours: Bool = true) {
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
        dispatcher().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
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
        let appIsActive = await MainActor.run { NSApp.isActive }
        return Self.presentationOptions(
            appIsActive: appIsActive,
            interruptionLevel: interruptionLevel
        )
    }
}

private extension ClimateActivity {
    var isActiveClimate: Bool {
        switch self {
        case .heating, .cooling, .ventilating, .active, .starting: return true
        default: return false
        }
    }
}
