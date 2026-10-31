import Foundation
import Testing
@testable import Hisingen

@Suite("Usage mode and daily summary notifications")
@MainActor
struct NotificationUsageDigestTests {
    private let vin = NotificationTestHarness.vin

    private func localDate(dayOffset: Int = 0, hour: Int, minute: Int = 0) throws -> Date {
        let day = try #require(Calendar.current.date(byAdding: .day, value: dayOffset, to: Date()))
        return try #require(Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: day))
    }

    private func enabledHarness() throws -> NotificationTestHarness {
        let harness = try NotificationTestHarness()
        harness.preferences.features = FeatureSelection(enabled: [.notifications])
        return harness
    }

    /// A state whose battery, health and availability readings are all taken at `at`, so
    /// freshness is judged against the injected clock rather than the wall clock.
    private func reportedState(_ harness: NotificationTestHarness, at: Date,
                               battery: Double = 50, usageMode: String? = nil,
                               serviceWarning: Bool = false) -> VehicleState {
        var state = harness.makeState(battery: battery, serviceWarning: serviceWarning, reportedAt: at)
        state.freshness.readingDates[.battery] = at
        state.freshness.readingDates[.health] = at
        state.freshness.readingDates[.availability] = at
        state.identity.usageMode = usageMode
        return state
    }

    private func seedSustainedStart(_ harness: NotificationTestHarness, key: String, minutesAgo: Double) {
        let starts: [String: Double] = [key: Date().addingTimeInterval(-minutesAgo * 60).timeIntervalSince1970]
        harness.defaults.set(starts, forKey: "notifier_sustained_starts_v1")
    }

    // MARK: - Usage mode

    @Test func onlyTheConvenienceTokenSatisfiesTheCondition() throws {
        let harness = try NotificationTestHarness()
        let now = Date()
        let cases: [(String?, Bool)] = [
            ("CONVENIENCE", true), ("USAGE_MODE_CONVENIENCE", true), (" convenience ", true),
            ("INACTIVE", false), ("USAGE_MODE_DRIVING", false), ("", false), (nil, false)
        ]
        for (raw, expected) in cases {
            let state = reportedState(harness, at: now, usageMode: raw)
            #expect(Notifier.convenienceModeCondition(state) == expected, "usage mode \(raw ?? "nil")")
        }
    }

    @Test func staleAvailabilityDoesNotCountAsConvenience() throws {
        let harness = try NotificationTestHarness()
        var state = reportedState(harness, at: Date(), usageMode: "CONVENIENCE")
        state.freshness.readingDates[.availability] = Date().addingTimeInterval(-2 * 3_600)
        #expect(!Notifier.convenienceModeCondition(state))
    }

    @Test func convenienceAlertIsOffByDefault() async throws {
        let harness = try enabledHarness()
        seedSustainedStart(harness, key: "\(vin).usage-convenience", minutesAgo: 31)
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(reportedState(harness, at: Date(), usageMode: "CONVENIENCE"))
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("usage-convenience") })
    }

    @Test func convenienceAlertWaitsForThirtyMinutes() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyUsageModeConvenience = true
        seedSustainedStart(harness, key: "\(vin).usage-convenience", minutesAgo: 10)
        let notifier = harness.makeNotifier()
        notifier.vehicleStateDidUpdate(reportedState(harness, at: Date(), usageMode: "CONVENIENCE"))
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("usage-convenience") })
    }

    @Test func convenienceAlertFiresOnceAfterThirtyMinutes() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyUsageModeConvenience = true
        seedSustainedStart(harness, key: "\(vin).usage-convenience", minutesAgo: 31)
        let notifier = harness.makeNotifier()
        let identifier = "hisingen.\(vin).usage-convenience"

        notifier.vehicleStateDidUpdate(reportedState(harness, at: Date(), usageMode: "CONVENIENCE"))
        await harness.drainNotificationHops()
        let alerts = harness.dispatcher.added.filter { $0.identifier == identifier }
        #expect(alerts.count == 1)
        #expect(alerts.first?.content.categoryIdentifier == Notifier.vehicleAlertCategoryID)
        #expect(alerts.first?.content.threadIdentifier == "hisingen.usage.\(vin)")

        notifier.vehicleStateDidUpdate(reportedState(harness, at: Date(), usageMode: "CONVENIENCE"))
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.filter { $0.identifier == identifier }.count == 1)
    }

    // MARK: - Mute action

    @Test func muteSilencesTheVehicleThroughThePreferenceOnly() async throws {
        let harness = try enabledHarness()
        let notifier = harness.makeNotifier()
        notifier.muteVehicle(vin: "")
        #expect(!harness.preferences.isMuted(vin: ""))

        notifier.muteVehicle(vin: vin)
        #expect(harness.preferences.isMuted(vin: vin))

        notifier.vehicleStateDidUpdate(reportedState(harness, at: Date(), serviceWarning: true))
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier.contains("service-due") })
    }

    // MARK: - Daily summary scheduling

    @Test func summaryDefaultsOffAtEight() throws {
        let harness = try NotificationTestHarness()
        #expect(!harness.preferences.notifyDailySummary)
        #expect(!harness.preferences.notifyUsageModeConvenience)
        #expect(harness.preferences.dailySummaryHour == 8)
        harness.preferences.dailySummaryHour = 30
        #expect(harness.preferences.dailySummaryHour == 23)
    }

    @Test func summarySendsOncePerDayAtTheChosenHour() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyDailySummary = true
        harness.preferences.dailySummaryHour = 8
        let notifier = harness.makeNotifier()
        let identifier = "hisingen.daily-summary"

        let early = try localDate(hour: 7, minute: 59)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: early))
        notifier.dailySummaryTick(now: early)
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier == identifier })

        let onTheHour = try localDate(hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: onTheHour))
        notifier.dailySummaryTick(now: onTheHour)
        let later = try localDate(hour: 8, minute: 5)
        notifier.dailySummaryTick(now: later)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.filter { $0.identifier == identifier }.count == 1)

        let nextDay = try localDate(dayOffset: 1, hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: nextDay))
        notifier.dailySummaryTick(now: nextDay)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.filter { $0.identifier == identifier }.count == 2)
    }

    @Test func summaryHeldByQuietHoursIsDeliveredWhenTheyEnd() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyDailySummary = true
        harness.preferences.dailySummaryHour = 8
        harness.preferences.quietHoursEnabled = true
        harness.preferences.quietHoursStartHour = 7
        harness.preferences.quietHoursEndHour = 9
        let notifier = harness.makeNotifier()
        let identifier = "hisingen.daily-summary"

        // Priming tick before the hour marks the summary as switched on in time.
        notifier.dailySummaryTick(now: try localDate(hour: 7))
        let duringQuiet = try localDate(hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: duringQuiet))
        notifier.dailySummaryTick(now: duringQuiet)
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier == identifier })

        let afterQuiet = try localDate(hour: 9, minute: 1)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: afterQuiet))
        notifier.dailySummaryTick(now: afterQuiet)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.filter { $0.identifier == identifier }.count == 1)
    }

    @Test func switchingOnAfterTheHourWaitsForTomorrow() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyDailySummary = true
        harness.preferences.dailySummaryHour = 8
        let notifier = harness.makeNotifier()
        let identifier = "hisingen.daily-summary"

        let afternoon = try localDate(hour: 15)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: afternoon))
        notifier.dailySummaryTick(now: afternoon)
        await harness.drainNotificationHops()
        #expect(!harness.dispatcher.added.contains { $0.identifier == identifier })

        let nextMorning = try localDate(dayOffset: 1, hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: nextMorning))
        notifier.dailySummaryTick(now: nextMorning)
        await harness.drainNotificationHops()
        #expect(harness.dispatcher.added.filter { $0.identifier == identifier }.count == 1)
    }

    @Test func summaryContentFollowsPrivacyMode() async throws {
        let harness = try enabledHarness()
        harness.preferences.notifyDailySummary = true
        harness.preferences.dailySummaryHour = 8
        harness.preferences.privateNotificationDetails = false
        let notifier = harness.makeNotifier()
        notifier.dailySummaryTick(now: try localDate(hour: 7))
        let now = try localDate(hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: now, battery: 50))
        notifier.dailySummaryTick(now: now)
        await harness.drainNotificationHops()
        let firstSummary = harness.dispatcher.added.first { $0.identifier == "hisingen.daily-summary" }
        let body = try #require(firstSummary?.content.body)
        #expect(body.contains(L10n.format("%@ battery", Format.percent(50))))

        harness.preferences.privateNotificationDetails = true
        let next = try localDate(dayOffset: 1, hour: 8)
        notifier.vehicleStateDidUpdate(reportedState(harness, at: next, battery: 50))
        notifier.dailySummaryTick(now: next)
        await harness.drainNotificationHops()
        let latestSummary = harness.dispatcher.added.last { $0.identifier == "hisingen.daily-summary" }
        let privateBody = try #require(latestSummary?.content.body)
        #expect(privateBody == L10n.text("Open Hisingen for details."))
    }

    // MARK: - Summary copy

    @Test func unreportedReadingsAreNamedNotZeroed() {
        let vehicle = DailySummaryVehicle(name: "Ana")
        let body = Notifier.dailySummaryBody([vehicle], distanceUnit: .kilometers)
        let expected = [
            L10n.text("Battery not reported"),
            L10n.text("Range not reported"),
            L10n.text("Warnings and service not reported")
        ]
        #expect(body == "Ana: " + expected.joined(separator: " · "))
        #expect(!body.contains("No warnings"))
        #expect(!body.contains("failed"))
    }

    @Test func reportedReadingsAndEstimatesAreStated() {
        let vehicle = DailySummaryVehicle(
            name: "Ana", batteryPercent: 80, rangeKm: 310, chargedKwh: 12.4,
            chargedKwhIsEstimate: true, healthReported: true, warningCount: 0,
            alarmTriggered: false, serviceDueSoon: true, failedCommands: 2
        )
        let body = Notifier.dailySummaryBody([vehicle], distanceUnit: .kilometers)
        let expected = [
            L10n.format("%@ battery", Format.percent(80)),
            L10n.format("%@ range", Format.distance(km: 310, unit: .kilometers)),
            L10n.format("About %@ charged", Format.energyKwh(12.4)),
            L10n.text("No warnings"),
            L10n.text("Service due soon"),
            L10n.format("%d failed commands in 24 h", 2)
        ]
        #expect(body == "Ana: " + expected.joined(separator: " · "))
    }

    @Test func oneVehicleLinePerCar() {
        let body = Notifier.dailySummaryBody([
            DailySummaryVehicle(name: "Ana", batteryPercent: 80, healthReported: true, warningCount: 1),
            DailySummaryVehicle(name: "Bo", batteryPercent: 20, healthReported: true, warningCount: 3, alarmTriggered: true)
        ], distanceUnit: .kilometers)
        let lines = body.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("Ana: "))
        #expect(lines[1].hasPrefix("Bo: "))
        #expect(lines[1].contains(L10n.text("Alarm triggered")))
    }
}
