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
    /// Throws on delivery rejection (permission revoked mid-session, oversized payload,
    /// system limits) so callers can log rather than silently drop an alert.
    func add(_ request: UNNotificationRequest) async throws
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func removeAllDeliveredNotifications()
    func removeAllPendingNotificationRequests()
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>)
}

/// Wraps the shared center. Posting goes through the async `add(_:)` API; the completion-
/// handler variant it replaces is deprecated on this deployment target (macOS 15) and, when
/// passed a nil handler, swallowed every rejection.
@MainActor
final class SystemNotificationDispatcher: NotificationDispatching {
    func add(_ request: UNNotificationRequest) async throws {
        try await UNUserNotificationCenter.current().add(request)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
    }
    func removeAllDeliveredNotifications() {
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }
    func removeAllPendingNotificationRequests() {
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {
        UNUserNotificationCenter.current().setNotificationCategories(categories)
    }
}

@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Instance wired to live telemetry, for settings surfaces (test notification).
    private(set) static var shared: Notifier?

    let logger = AppLog.logger("notifier")
    let available: Bool
    private let detector = ChargingTransitionDetector()
    let stateStore: VehicleStateStore
    let preferences: PreferencesStore
    let defaults: UserDefaults
    let dispatcher: () -> any NotificationDispatching
    private(set) var permission: NotificationPermission {
        didSet { if permission != oldValue { onPermissionChanged?(permission) } }
    }
    var authorized: Bool { permission == .authorized }
    private var authenticationNoticePostedByBrand: [String: Bool] = [:]
    var previousStateByVIN: [String: VehicleState] = [:]
    var pendingClimateStopReadingDateByVIN: [String: Date] = [:]
    var sustainedConditionStartedAt: [String: Date]
    var sustainedNotificationsDelivered: Set<String>
    var serviceDueByVIN: [String: Bool]
    var warningVehicles = Set<String>()
    var sustainedRecheckTimer: Timer?

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
    static let openingsCategoryID = "vehicle-openings-actionable"
    static let vehicleAlertCategoryID = "vehicle-alert-actionable"
    nonisolated static let muteVehicleActionID = "mute-vehicle"

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
         dispatcher: (any NotificationDispatching)? = nil,
         availableOverride: Bool? = nil,
         initialPermission: NotificationPermission? = nil,
         configuresSystemIntegration: Bool = true) {
        self.available = availableOverride ?? (Bundle.main.bundleURL.pathExtension == "app")
        self.stateStore = stateStore
        self.preferences = preferences
        self.defaults = defaults
        let actualDispatcher = dispatcher ?? SystemNotificationDispatcher()
        self.dispatcher = { actualDispatcher }
        self.permission = initialPermission ?? .notDetermined
        let starts = (defaults.dictionary(forKey: "notifier_sustained_starts_v1") as? [String: Double]) ?? [:]
        self.sustainedConditionStartedAt = starts.mapValues(Date.init(timeIntervalSince1970:))
        self.sustainedNotificationsDelivered = Set(defaults.stringArray(forKey: "notifier_sustained_delivered_v1") ?? [])
        self.serviceDueByVIN = (defaults.dictionary(forKey: "notifier_service_due_v1") as? [String: Bool]) ?? [:]
        // One-time cleanup: builds before the bounded latch below leaked one persistent
        // "anomaly_<session id>" defaults key per charging session, forever. The done-flag
        // keeps every later launch from scanning the whole defaults domain again.
        let anomalyCleanupKey = "notifier_anomaly_key_cleanup_v1"
        if !defaults.bool(forKey: anomalyCleanupKey) {
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("anomaly_") {
                defaults.removeObject(forKey: key)
            }
            defaults.set(true, forKey: anomalyCleanupKey)
        }
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

    /// Registers the notification categories that carry quick actions. Lock is the only vehicle
    /// command offered from a banner, and it demands device-owner authentication. Mute is a
    /// local preference, so it needs no authentication and stays out of the command path.
    private func registerQuickActionCategories() {
        let lock = UNNotificationAction(
            identifier: "lock-vehicle",
            title: L10n.text("Lock"),
            options: [.authenticationRequired]
        )
        let mute = UNNotificationAction(
            identifier: Self.muteVehicleActionID,
            title: L10n.text("Mute This Vehicle"),
            options: []
        )
        // Resuming a schedule is a write command too, so it demands the same explicit
        // device unlock the lock action does – consistent capability gates.
        let resume = UNNotificationAction(
            identifier: "resume-charge",
            title: L10n.text("Resume Schedule"),
            options: [.authenticationRequired]
        )
        let unlockedCategory = UNNotificationCategory(
            identifier: Self.unlockedCategoryID,
            actions: [lock, mute],
            intentIdentifiers: [],
            options: []
        )
        let openingsCategory = UNNotificationCategory(
            identifier: Self.openingsCategoryID,
            actions: [lock, mute],
            intentIdentifiers: [],
            options: []
        )
        let vehicleAlertCategory = UNNotificationCategory(
            identifier: Self.vehicleAlertCategoryID,
            actions: [mute],
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
            unlockedCategory, interruptedCategory, openingsCategory, vehicleAlertCategory
        ])
    }


    func requestAuthorizationFromSettings() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            [weak self] granted, _ in
            Task { @MainActor in self?.permission = granted ? .authorized : .denied }
        }
    }

    /// Requests system authorization only when notifications are enabled as a feature *and* at
    /// least one alert type is on – there is nothing to prompt for otherwise. Called after any
    /// settings change that could turn the first alert on.
    func requestAuthorizationIfAnyAlertEnabled() {
        guard preferences.features.contains(.notifications), preferences.anyNotificationAlertEnabled else { return }
        requestAuthorizationFromSettings()
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
        // RefreshCoordinator may publish a display projection while a command is pending.
        // It deliberately carries the optimistic value and a receipt; it is not telemetry
        // evidence and must not advance transition baselines or produce notifications.
        if state.commandState.receipts.contains(where: {
            $0.status.isAwaiting && $0.supportsTelemetryConfirmation
        }) {
            pendingClimateStopReadingDateByVIN[state.identity.vin] = nil
            return
        }
        let previousState = previousStateByVIN[state.identity.vin]
        previousStateByVIN[state.identity.vin] = state
        let result = detector.evaluate(
            previous: stateStore.baseline(for: state.identity.vin),
            current: state,
            lowBatteryThreshold: preferences.lowBatteryThreshold
        )
        stateStore.save(result.baseline)

        updateWarningVehicleCount(state: state)

        // Muted vehicles keep their baselines advancing above, so un-muting never
        // replays a burst of stale edge events accumulated during the quiet period.
        guard preferences.features.contains(.notifications), available, authorized,
              !preferences.isMuted(vin: state.identity.vin) else { return }

        for event in result.events {
            let reading: VehicleReading
            if case .lowBattery = event { reading = .battery } else { reading = .charging }
            guard state.hasFreshReading(reading) else { continue }
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
        checkClimateWarnings(previous: previousState, current: state)
        checkRainWithWindows(previous: previousState, current: state)
        checkEveningUnlocked(previous: previousState, current: state)
        checkUsageMode(current: state)
        checkLowBatteryPlugIn(previous: previousState, current: state)
        checkSoftwareUpdate(previous: previousState, current: state)
        checkVehicleWarnings(previous: previousState, current: state)
        checkServiceDue(current: state)
        checkSlowCharging(current: state)
        checkStaleTelemetry(current: state)
        checkOpeningsLeftOpen(current: state)
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

}

extension Notifier: VehicleMemoryCaching {
    /// Drops every in-memory entry filed under an erased vehicle, and its persisted mirrors.
    ///
    /// `previousStateByVIN` is the one that keeps answering: `displayName(forVIN:)` falls back
    /// to it for a vehicle's brand, so a wiped snapshot would still name itself in the next
    /// banner. The rest is the same kind of residue – a pending climate reading, a sustained
    /// condition timer, a service-due latch, a warning badge count – and would otherwise let a
    /// re-added car inherit half-elapsed state from the vehicle that was erased.
    func dropCachedVehicles(_ scope: VehicleScope) {
        dropCachedSnapshots(scope)
        let serviceDueCountBefore = serviceDueByVIN.count
        serviceDueByVIN = serviceDueByVIN.filter { !scope.covers($0.key) }
        let warningCountBefore = warningVehicles.count
        warningVehicles = warningVehicles.filter { !scope.covers($0) }
        // The optional dock badge is a count of vehicles in this set; leaving it stale would
        // keep advertising a warning that belongs to a vehicle the reader just erased.
        if warningVehicles.count != warningCountBefore {
            onWarningVehicleCountChanged?(warningVehicles.count)
        }
        // Sustained-condition keys are "<vin>.<condition>", so they match on the VIN prefix
        // rather than by equality.
        let belongsToErasedVehicle = { (key: String) in
            scope.covers(key.split(separator: ".").first.map(String.init) ?? key)
        }
        sustainedConditionStartedAt = sustainedConditionStartedAt.filter { !belongsToErasedVehicle($0.key) }
        sustainedNotificationsDelivered = sustainedNotificationsDelivered.filter { !belongsToErasedVehicle($0) }
        if serviceDueByVIN.count != serviceDueCountBefore {
            defaults.set(serviceDueByVIN, forKey: "notifier_service_due_v1")
        }
        persistSustainedState()
        let anomalyKey = "notifier_anomaly_last_checked_by_vin_v1"
        let checked = (defaults.dictionary(forKey: anomalyKey) as? [String: String]) ?? [:]
        defaults.set(checked.filter { !scope.covers($0.key) }, forKey: anomalyKey)
        let climateWarningKey = "notifier_climate_warning_session_v1"
        let warned = (defaults.dictionary(forKey: climateWarningKey) as? [String: String]) ?? [:]
        defaults.set(warned.filter { !scope.covers($0.key) }, forKey: climateWarningKey)
    }

    /// The snapshot half of the erase: what the vehicle last reported, which a location clear has
    /// to drop because a held snapshot still carries the coordinates. The service-due and
    /// sustained latches, the dock badge and the persisted dedupe mirrors say what the reader has
    /// already been told, which a location change neither replays nor forgives.
    func dropCachedSnapshots(_ scope: VehicleScope) {
        previousStateByVIN = previousStateByVIN.filter { !scope.covers($0.key) }
        pendingClimateStopReadingDateByVIN = pendingClimateStopReadingDateByVIN.filter { !scope.covers($0.key) }
    }
}
