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

    func add(_ request: UNNotificationRequest) async throws {
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
        defaults = try #require(UserDefaults(suiteName: suiteName))
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

    /// Notifier posts through `Task { @MainActor … try await dispatcher.add(request) }`
    /// (RT-05), so tests must drain those hops before asserting on `added` — otherwise a
    /// pass may just mean "not scheduled yet". Waits until the posted count is stable.
    func drainNotificationHops() async {
        await awaitStable { [dispatcher] in dispatcher.added.count }
    }

    func makeState(
        battery: Double = 50,
        chargingState: ChargingState = .idle,
        chargerConnection: ChargerConnection = .disconnected,
        powerWatts: Int? = nil,
        serviceWarning: Bool = false,
        reportedAt: Date = Date()
    ) -> VehicleState {
        var state = vehicle(
            vin: Self.vin, battery: battery, rangeKm: 350,
            state: chargingState,
            connection: chargerConnection,
            chargingType: chargingState == .idle ? .none : .ac,
            powerWatts: powerWatts,
            currentAmps: 16,
            modelYear: "2024",
            registrationNo: "TEST123",
            odometerKm: 25_000,
            daysToService: 120,
            distanceToServiceKm: 5_000,
            serviceWarning: serviceWarning,
            reportedBatteryCapacityKwh: 75.0,
            fetchedAt: reportedAt, reportedAt: reportedAt
        )
        let sensorDate = min(reportedAt, Date())
        state.freshness.readingDates = [.battery: sensorDate, .charging: sensorDate, .health: sensorDate]
        return state
    }
}

@Suite("Notification posting")
@MainActor
struct NotificationPostingTests {

    private func climateState(
        _ harness: NotificationTestHarness,
        activity: ClimateActivity,
        reportedAt: Date
    ) -> VehicleState {
        var state = harness.makeState(reportedAt: reportedAt)
        state.climateStatus = VehicleClimateStatus(
            activity: activity,
            timeRemainingMinutes: activity == .idle ? nil : 30,
            timerTriggered: false,
            interiorTemperatureCelsius: nil,
            requestedTemperatureCelsius: 22
        )
        state.freshness.readingDates[.climateStatus] = reportedAt
        return state
    }

    @Test func transientInactiveClimateReadingDoesNotPostFalseTransitions() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -180)

        notifier.vehicleStateDidUpdate(climateState(harness, activity: .ventilating, reportedAt: base))
        harness.dispatcher.added.removeAll()
        notifier.vehicleStateDidUpdate(climateState(harness, activity: .idle,
                                                     reportedAt: base.addingTimeInterval(3)))
        notifier.vehicleStateDidUpdate(climateState(harness, activity: .ventilating,
                                                     reportedAt: base.addingTimeInterval(6)))
        await harness.drainNotificationHops()

        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("climate-") })
    }

    @Test func pendingClimateStartNeverProducesStoppedNotificationWhileBackendCatchesUp() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -180)
        let command = RemoteCommand.startClimate(
            temperatureCelsius: 0,
            frontLeftSeat: .off,
            frontRightSeat: .off,
            rearLeftSeat: .off,
            rearRightSeat: .off,
            steeringWheel: .off
        )

        notifier.vehicleStateDidUpdate(climateState(harness, activity: .ventilating, reportedAt: base))
        harness.dispatcher.added.removeAll()
        for offset in [3.0, 6.0] {
            var inactive = climateState(harness, activity: .idle,
                                        reportedAt: base.addingTimeInterval(offset))
            inactive.commandState.receipt = CommandReceipt(
                commandIdentifier: command.identifier,
                issuedAt: base,
                command: command
            )
            notifier.vehicleStateDidUpdate(inactive)
        }
        await harness.drainNotificationHops()

        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("climate-stopped") })
    }

    @Test func repeatedInactiveClimateReadingPostsOneStoppedNotification() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyClimateChanges = true
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -180)

        notifier.vehicleStateDidUpdate(climateState(harness, activity: .ventilating, reportedAt: base))
        harness.dispatcher.added.removeAll()
        notifier.vehicleStateDidUpdate(climateState(harness, activity: .idle,
                                                     reportedAt: base.addingTimeInterval(3)))
        notifier.vehicleStateDidUpdate(climateState(harness, activity: .idle,
                                                     reportedAt: base.addingTimeInterval(6)))
        notifier.vehicleStateDidUpdate(climateState(harness, activity: .idle,
                                                     reportedAt: base.addingTimeInterval(9)))
        await harness.drainNotificationHops()

        #expect(harness.dispatcher.added.filter { $0.identifier.contains("climate-stopped") }.count == 1)
    }

    @Test func freshSnapshotDoesNotMakeOldChargingAndHealthReadingsNotify() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: Date().addingTimeInterval(-60)))
        harness.dispatcher.added.removeAll()
        var current = harness.makeState(chargingState: .charging, chargerConnection: .connected,
                                        serviceWarning: true)
        current.freshness.readingDates[.charging] = Date().addingTimeInterval(-3600)
        current.freshness.readingDates[.health] = Date().addingTimeInterval(-3600)
        notifier.vehicleStateDidUpdate(current)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.isEmpty)
    }

    @Test func unknownConnectionDoesNotProduceDisconnectedNotification() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.notifyChargerConnection = true
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(harness.makeState(chargerConnection: .connected,
                                                         reportedAt: Date().addingTimeInterval(-60)))
        harness.dispatcher.added.removeAll()
        notifier.vehicleStateDidUpdate(harness.makeState(chargerConnection: .unknown))
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("cable-disconnected") })
    }

    @Test func chargingStartIncludesVehicleSubtitle() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.privateNotificationDetails = false
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))
        await harness.drainNotificationHops()

        let posted = try #require(harness.dispatcher.added.first { $0.identifier.contains(".started") })
        #expect(posted.content.title == L10n.text("Charging started"))
        #expect(posted.content.subtitle == "Polestar")
        #expect(posted.content.userInfo["vin"] as? String == NotificationTestHarness.vin)
    }

    @Test func privateModeKeepsBodiesAnonymousButSubtitleIdentifiesCar() async throws {
        let harness = try NotificationTestHarness()
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        // Fresh defaults: privacy mode ON. The body stays anonymous; the subtitle
        // still says which car the alert is about.
        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))
        await harness.drainNotificationHops()

        let posted = try #require(harness.dispatcher.added.first { $0.identifier.contains(".started") })
        #expect(posted.content.body == L10n.text("Started charging."))
        #expect(posted.content.subtitle == "Polestar")
    }

    @Test func serviceDueDoesNotRefireAfterRelaunchWhileStillDue() async throws {
        let harness = try NotificationTestHarness()
        let first = harness.makeNotifier()

        first.vehicleStateDidUpdate(harness.makeState(reportedAt: Date(timeIntervalSinceNow: -120)))
        first.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date()))
        await harness.drainNotificationHops()
        let countAfterFirstFire = harness.dispatcher.added.count
        #expect(countAfterFirstFire > 0)

        // "Relaunch": a brand-new notifier over the same persisted defaults, still due.
        let second = harness.makeNotifier()
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date().addingTimeInterval(60)))
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.count == countAfterFirstFire, "service-due banner refired after relaunch while already due")

        // Clearing and re-raising must notify again.
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: false, reportedAt: Date().addingTimeInterval(120)))
        second.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: Date().addingTimeInterval(180)))
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.count > countAfterFirstFire)
    }

    @Test func sustainedDeduplicationSurvivesRelaunch() async throws {
        let harness = try NotificationTestHarness()
        // Seed the persisted started-at so the 1-second stale condition is already
        // satisfied at launch — exactly the mid-condition relaunch scenario.
        let staleSince = Date().addingTimeInterval(-10).timeIntervalSince1970
        harness.defaults.set([("\(NotificationTestHarness.vin).stale"): staleSince],
                             forKey: "notifier_sustained_starts_v1")
        let staleReport = Date(timeIntervalSinceNow: -3 * 3_600)

        let first = harness.makeNotifier()
        first.vehicleStateDidUpdate(harness.makeState(reportedAt: staleReport))
        await harness.drainNotificationHops()
        let countAfterFirstNotice = harness.dispatcher.added.count
        #expect(countAfterFirstNotice > 0, "stale-telemetry banner should fire")

        // Relaunch during the same stale window: the delivered latch persists.
        let second = harness.makeNotifier()
        second.vehicleStateDidUpdate(harness.makeState(reportedAt: staleReport.addingTimeInterval(-30)))
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.count == countAfterFirstNotice, "stale-telemetry banner refired after relaunch during the same condition")
    }

    @Test func mutedVehiclePostsNothingWhileBaselinesKeepAdvancing() async throws {
        let harness = try NotificationTestHarness()
        harness.preferences.setMuted(true, for: NotificationTestHarness.vin)
        let notifier = harness.makeNotifier()
        let base = Date(timeIntervalSinceNow: -600)

        notifier.vehicleStateDidUpdate(harness.makeState(reportedAt: base))
        notifier.vehicleStateDidUpdate(harness.makeState(
            chargingState: .charging, chargerConnection: .connected, powerWatts: 7_000,
            reportedAt: base.addingTimeInterval(60)))
        await harness.drainNotificationHops()

        #expect(harness.dispatcher.added.isEmpty, "muted vehicle produced a banner")
        let baseline = harness.store.baseline(for: NotificationTestHarness.vin)
        #expect(baseline?.chargingSessionActive == true, "baseline did not advance while muted")
    }

    @Test func quietHoursDeferNonUrgentButUrgentBreaksThrough() async throws {
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
        await harness.drainNotificationHops()
        let deferred = try #require(harness.dispatcher.added.first { $0.identifier.contains(".started") })
        #expect(deferred.trigger != nil, "quiet-hours notice was posted immediately")

        // Urgent class (vehicle warning) must bypass the window entirely.
        notifier.vehicleStateDidUpdate(harness.makeState(serviceWarning: true, reportedAt: base.addingTimeInterval(90)))
        await harness.drainNotificationHops()
        let urgent = harness.dispatcher.added.first { $0.identifier.contains("vehicle-warnings") }
        #expect(urgent != nil, "urgent warning was not delivered")
        #expect(urgent?.trigger == nil, "urgent warning did not bypass quiet hours")
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

        #expect(counts == [1, 0])
    }
}

@Suite("Notification helpers")
struct NotificationHelperTests {

    @Test func presentationOptionsStayQuietWhenAppFrontmostUnlessTimeSensitive() {
        #expect(Notifier.presentationOptions(appIsActive: true, interruptionLevel: .active) == [.list])
        #expect(Notifier.presentationOptions(appIsActive: true, interruptionLevel: .timeSensitive) == [.banner, .sound])
        #expect(Notifier.presentationOptions(appIsActive: false, interruptionLevel: .passive) == [.banner, .sound])
    }

    @Test func vinFromThreadIgnoresAccountLevelThreads() {
        #expect(Notifier.vin(fromThread: "hisingen.charging.YSMVSEDE6PL147228") == "YSMVSEDE6PL147228")
        #expect(Notifier.vin(fromThread: "hisingen.notices") == "")
        #expect(Notifier.vin(fromThread: "hisingen.account.volvo") == "")
        #expect(Notifier.vin(fromThread: "") == "")
    }

    @Test func quietHourWindowHandlesMidnightWrapAndDisabled() {
        let calendar = Calendar.current
        func date(hour: Int) -> Date {
            calendar.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
        }
        #expect(Notifier.isQuietHour(now: date(hour: 23), startHour: 22, endHour: 7))
        #expect(Notifier.isQuietHour(now: date(hour: 5), startHour: 22, endHour: 7))
        #expect(!(Notifier.isQuietHour(now: date(hour: 12), startHour: 22, endHour: 7)))
        #expect(Notifier.isQuietHour(now: date(hour: 13), startHour: 9, endHour: 17))
        #expect(!(Notifier.isQuietHour(now: date(hour: 8), startHour: 9, endHour: 17)))
        #expect(!(Notifier.isQuietHour(now: date(hour: 12), startHour: 12, endHour: 12)), "equal hours must disable the window, not silence all day")
    }
}

@Suite("Charging baseline fingerprint history")
struct ChargingBaselineFingerprintTests {

    private func state(vin: String, charging: Bool, battery: Double, reportedAt: Date) -> VehicleState {
        // TESTS-12: thin wrapper over the shared TestSupport fixture builder.
        vehicle(
            vin: vin, battery: battery, rangeKm: 300,
            state: charging ? .charging : .idle,
            connection: charging ? .connected : .disconnected,
            chargingType: charging ? .ac : .none,
            powerWatts: charging ? 7_000 : nil,
            modelYear: "2024",
            fetchedAt: reportedAt, reportedAt: reportedAt
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
        faulty.energy.chargingState = .fault
        faulty.energy.connection = .fault
        let result = detector.evaluate(
            previous: previous.baseline,
            current: faulty,
            lowBatteryThreshold: 20)

        #expect(result.events.contains(ChargingEvent.fault))
        #expect(result.events.contains(ChargingEvent.lowBattery(threshold: 20)))
        // Both fingerprints persist — the old single-slot baseline forgot the first.
        #expect(result.baseline.recentEventFingerprints.count == 2)
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
        #expect(baseline.recentEventFingerprints == ["VIN123|started|1700000000"])
    }
}
