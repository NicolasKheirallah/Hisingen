import Foundation
import Testing
import UserNotifications
@testable import Hisingen

@MainActor
final class FakeNotificationDispatcher: NotificationDispatching {
    var added: [UNNotificationRequest] = []
    var removedIdentifiers: [[String]] = []
    var removedAllDelivered = 0
    var removedAllPending = 0

    func add(_ request: UNNotificationRequest) {
        added.append(request)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(identifiers)
    }
    func removeAllDeliveredNotifications() {
        removedAllDelivered += 1
    }
    func removeAllPendingNotificationRequests() {
        removedAllPending += 1
    }
    func setNotificationCategories(_ categories: Set<UNNotificationCategory>) {}
}

@MainActor
struct NotificationTestHarness {
    let defaults: UserDefaults
    let suiteName: String
    let dispatcher: FakeNotificationDispatcher
    let preferences: PreferencesStore
    let store: VehicleStateStore

    static let vin = "YSMVSEDE6PL147228"

    init() throws {
        suiteName = "HisingenTests.Notifier.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        dispatcher = FakeNotificationDispatcher()
        preferences = PreferencesStore(defaults: defaults)
        store = VehicleStateStore(defaults: defaults, database: .inMemory())
    }

    func makeNotifier() -> Notifier {
        Notifier(
            stateStore: store,
            preferences: preferences,
            defaults: defaults,
            dispatcher: dispatcher,
            availableOverride: true,
            initialPermission: .authorized,
            configuresSystemIntegration: false
        )
    }

    func makeState(
        battery: Double = 50,
        chargingState: ChargingState = .idle,
        chargerConnection: ChargerConnection = .disconnected,
        powerWatts: Int? = nil,
        serviceWarning: Bool = false,
        reportedAt: Date = Date()
    ) -> VehicleState {
        VehicleState(
            batteryPercentage: battery,
            rangeKm: 350,
            chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: nil,
            chargeTargetPercentage: 80,
            chargingPowerWatts: powerWatts,
            chargingCurrentAmps: 16,
            chargingVoltageVolts: nil,
            chargingType: chargingState == .idle ? .none : .ac,
            chargerConnection: chargerConnection,
            availability: .available,
            modelName: "Polestar 2",
            modelYear: "2024",
            registrationNo: "TEST123",
            vin: Self.vin,
            ownerFirstName: nil,
            odometerKm: 25_000,
            daysToService: 120,
            distanceToServiceKm: 5_000,
            serviceWarning: serviceWarning,
            fluidWarnings: [],
            powertrain: .bev,
            reportedBatteryCapacityKwh: 75.0,
            imageData: nil,
            fetchedAt: reportedAt,
            vehicleReportedAt: reportedAt,
            dataWarnings: []
        )
    }
}

@Suite("Notification posting")
@MainActor
struct NotificationPostingTests {

    @Test func chargingStartIncludesVehicleSubtitle() throws {
        let harness = try NotificationTestHarness()
        harness.preferences.privateNotificationDetails = false
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))

        let posted = try XCTUnwrap(
            harness.dispatcher.added.first { $0.identifier.contains(".started") })
        XCTAssertEqual(posted.content.title, L10n.text("Charging started"))
        XCTAssertEqual(posted.content.subtitle, "Polestar")
        XCTAssertEqual(posted.content.userInfo["vin"] as? String, NotificationTestHarness.vin)
    }

    @Test func privateModeKeepsBodiesAnonymousButSubtitleIdentifiesCar() throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        // Fresh defaults: privacy mode ON. The body stays anonymous; the subtitle
        // still says which car the alert is about.
        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))

        let posted = try XCTUnwrap(
            harness.dispatcher.added.first { $0.identifier.contains(".started") })
        XCTAssertEqual(posted.content.body, L10n.text("Started charging."))
        XCTAssertEqual(posted.content.subtitle, "Polestar")
    }

    @Test func serviceDueDoesNotRefireAfterRelaunchWhileStillDue() throws {
        let harness = try NotificationTestHarness()
        let first = harness.makeNotifier()

        first.vehicleStateDidUpdate(harness.makeState(reportedAt: Date(timeIntervalSinceNow: -120)))
        first.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date()))
        let countAfterFirstFire = harness.dispatcher.added.count
        XCTAssertTrue(countAfterFirstFire > 0)

        // "Relaunch": a brand-new notifier over the same persisted defaults, still due.
        let second = harness.makeNotifier()
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date().addingTimeInterval(60)))
        XCTAssertEqual(harness.dispatcher.added.count, countAfterFirstFire,
                       "service-due banner refired after relaunch while already due")

        // Clearing and re-raising must notify again.
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: false, reportedAt: Date().addingTimeInterval(120)))
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date().addingTimeInterval(180)))
        XCTAssertTrue(harness.dispatcher.added.count > countAfterFirstFire)
    }

    @Test func sustainedDeduplicationSurvivesRelaunch() throws {
        let harness = try NotificationTestHarness()
        // Seed the persisted started-at so the 1-second stale condition is already
        // satisfied at launch — exactly the mid-condition relaunch scenario.
        let staleSince = Date().addingTimeInterval(-10).timeIntervalSince1970
        harness.defaults.set([("\(NotificationTestHarness.vin).stale"): staleSince],
                             forKey: "notifier_sustained_starts_v1")
        let staleReport = Date(timeIntervalSinceNow: -3 * 3_600)

        let first = harness.makeNotifier()
        first.vehicleStateDidUpdate(harness.makeState(reportedAt: staleReport))
        let countAfterFirstNotice = harness.dispatcher.added.count
        XCTAssertTrue(countAfterFirstNotice > 0, "stale-telemetry banner should fire")

        // Relaunch during the same stale window: the delivered latch persists.
        let second = harness.makeNotifier()
        second.vehicleStateDidUpdate(harness.makeState(reportedAt: staleReport.addingTimeInterval(-30)))
        XCTAssertEqual(harness.dispatcher.added.count, countAfterFirstNotice,
                       "stale-telemetry banner refired after relaunch during the same condition")
    }

    @Test func mutedVehiclePostsNothingWhileBaselinesKeepAdvancing() throws {
        let harness = try NotificationTestHarness()
        harness.preferences.setMuted(true, for: NotificationTestHarness.vin)
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))

        XCTAssertTrue(harness.dispatcher.added.isEmpty, "muted vehicle produced a banner")
        let baseline = harness.store.baseline(for: NotificationTestHarness.vin)
        XCTAssertEqual(baseline?.chargingSessionActive, true, "baseline did not advance while muted")
    }

    @Test func quietHoursDeferNonUrgentButUrgentBreaksThrough() throws {
        let harness = try NotificationTestHarness()
        harness.preferences.privateNotificationDetails = false
        // Window covering "now" regardless of wall clock: start = current hour.
        let hour = Calendar.current.component(.hour, from: Date())
        harness.preferences.quietHoursEnabled = true
        harness.preferences.quietHoursStartHour = hour
        harness.preferences.quietHoursEndHour = (hour + 1) % 24

        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        // Non-urgent (charging started) inside quiet hours → deferred with a trigger.
        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))
        let deferred = try XCTUnwrap(
            harness.dispatcher.added.first { $0.identifier.contains(".started") })
        XCTAssertNotNil(deferred.trigger, "quiet-hours notice was posted immediately")

        // Urgent class (vehicle warning) must bypass the window entirely.
        notifier.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: base.addingTimeInterval(90)))
        let urgent = harness.dispatcher.added.first { $0.identifier.contains("vehicle-warnings") }
        XCTAssertNotNil(urgent, "urgent warning was not delivered")
        XCTAssertNil(urgent?.trigger, "urgent warning did not bypass quiet hours")
    }

    @Test func warningCountCallbackTracksVehicles() throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        var counts: [Int] = []
        notifier.onWarningVehicleCountChanged = { counts.append($0) }
        let base = Date(timeIntervalSinceNow: -600)

        notifier.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: base.addingTimeInterval(60)))
        notifier.vehicleStateDidUpdate(harness.makeState(serviceWarning: false, reportedAt: base.addingTimeInterval(120)))

        XCTAssertEqual(counts, [1, 0])
    }
}

@Suite("Notification helpers")
struct NotificationHelperTests {

    @Test func presentationOptionsStayQuietWhenAppFrontmostUnlessTimeSensitive() {
        XCTAssertEqual(
            Notifier.presentationOptions(appIsActive: true, interruptionLevel: .active),
            [.list])
        XCTAssertEqual(
            Notifier.presentationOptions(appIsActive: true, interruptionLevel: .timeSensitive),
            [.banner, .sound])
        XCTAssertEqual(
            Notifier.presentationOptions(appIsActive: false, interruptionLevel: .passive),
            [.banner, .sound])
    }

    @Test func vinFromThreadIgnoresAccountLevelThreads() {
        XCTAssertEqual(Notifier.vin(fromThread: "hisingen.charging.YSMVSEDE6PL147228"), "YSMVSEDE6PL147228")
        XCTAssertEqual(Notifier.vin(fromThread: "hisingen.notices"), "")
        XCTAssertEqual(Notifier.vin(fromThread: "hisingen.account.volvo"), "")
        XCTAssertEqual(Notifier.vin(fromThread: ""), "")
    }

    @Test func quietHourWindowHandlesMidnightWrapAndDisabled() {
        let calendar = Calendar.current
        func date(hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        XCTAssertTrue(Notifier.isQuietHour(now: date(hour: 23), startHour: 22, endHour: 7))
        XCTAssertTrue(Notifier.isQuietHour(now: date(hour: 5), startHour: 22, endHour: 7))
        XCTAssertFalse(Notifier.isQuietHour(now: date(hour: 12), startHour: 22, endHour: 7))
        XCTAssertTrue(Notifier.isQuietHour(now: date(hour: 13), startHour: 9, endHour: 17))
        XCTAssertFalse(Notifier.isQuietHour(now: date(hour: 8), startHour: 9, endHour: 17))
        XCTAssertFalse(Notifier.isQuietHour(now: date(hour: 12), startHour: 12, endHour: 12),
                       "equal hours must disable the window, not silence all day")
    }
}

@Suite("Charging baseline fingerprint history")
struct ChargingBaselineFingerprintTests {

    private func state(vin: String, charging: Bool, battery: Double, reportedAt: Date) -> VehicleState {
        VehicleState(
            batteryPercentage: battery, rangeKm: 300,
            chargingState: charging ? .charging : .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: charging ? 7_000 : nil, chargingCurrentAmps: nil,
            chargingVoltageVolts: nil, chargingType: charging ? .ac : .none,
            chargerConnection: charging ? .connected : .disconnected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: nil, vin: vin, ownerFirstName: nil, odometerKm: nil,
            daysToService: nil, distanceToServiceKm: nil, serviceWarning: false,
            fluidWarnings: [], powertrain: .bev, reportedBatteryCapacityKwh: nil,
            imageData: nil, fetchedAt: reportedAt, vehicleReportedAt: reportedAt,
            dataWarnings: []
        )
    }

    @Test func bothEventsInOneEvaluationAreRememberedForDedup() {
        let vin = "YSMVSEDE6PL147228"
        let detector = ChargingTransitionDetector()
        let t0 = Date(timeIntervalSinceNow: -600)
        let previous = detector.evaluate(
            previous: nil, current: state(vin: vin, charging: false, battery: 50, reportedAt: t0),
            lowBatteryThreshold: 20)
        // Fault AND low-battery land in the same sample. (Started + low battery can
        // never co-occur: actively charging resets the low-battery latch first.)
        var faulty = state(vin: vin, charging: false, battery: 15, reportedAt: t0.addingTimeInterval(60))
        faulty.chargingState = .fault
        faulty.chargerConnection = .fault
        let result = detector.evaluate(
            previous: previous.baseline,
            current: faulty,
            lowBatteryThreshold: 20)

        XCTAssertTrue(result.events.contains(ChargingEvent.fault))
        XCTAssertTrue(result.events.contains(ChargingEvent.lowBattery(threshold: 20)))
        // Both fingerprints persist — the old single-slot baseline forgot the first.
        XCTAssertEqual(result.baseline.recentEventFingerprints.count, 2)
    }

    @Test func legacySingleFingerprintDecodesIntoHistory() throws {
        // Produce a structurally valid pre-upgrade record by encoding today's model
        // and swapping the new history array back to the legacy single slot.
        let modern = ChargingBaseline(
            vin: "VIN123", state: .idle, connection: .disconnected,
            batteryPercentage: 40, targetPercentage: 80, vehicleReportedAt: nil,
            sampledAt: nil, chargingSessionActive: false, interruptionSamples: 0,
            lowBatteryNotified: false)
        let legacyJSON = String(data: try JSONEncoder().encode(modern), encoding: .utf8)!
            .replacingOccurrences(of: "\"recentEventFingerprints\":[]",
                                  with: "\"lastEventFingerprint\":\"VIN123|started|1700000000\"")
        let baseline = try JSONDecoder().decode(
            ChargingBaseline.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(baseline.recentEventFingerprints, ["VIN123|started|1700000000"])
    }
}
