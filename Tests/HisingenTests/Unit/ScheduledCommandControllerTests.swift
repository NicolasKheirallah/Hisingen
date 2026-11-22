import Foundation
import Testing
@testable import Hisingen

/// A scheduled action fires at the time the reader set, once per occurrence, and only for the
/// actions that can run with nobody at the Mac.
@Suite(.serialized)
@MainActor
struct ScheduledCommandControllerTests {
    @Test
    func anActionFiresAtItsTimeAndOnlyOncePerOccurrence() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 30))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        await harness.controller.evaluate()
        #expect(harness.sent == [.lock])

        // The next tick inside the same minute must not send it again.
        await harness.controller.evaluate()
        #expect(harness.sent == [.lock])
    }

    @Test
    func nothingFiresBeforeTheScheduledMinute() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 29))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        await harness.controller.evaluate()

        #expect(harness.sent.isEmpty)
    }

    @Test
    func aTickThatLandsLateInsideTheCatchUpWindowStillFires() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 40))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .closeWindows)
        ]

        await harness.controller.evaluate()

        #expect(harness.sent == [.closeWindows])
    }

    @Test
    func aScheduleMissedByHoursIsSkippedRatherThanReplayed() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 9, 0))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        await harness.controller.evaluate()

        #expect(harness.sent.isEmpty)
    }

    @Test
    func theWeekdayFilterDecidesWhichDaysFire() async {
        // 2026-11-16 is a Monday; 2026-11-17 the Tuesday after it.
        let monday = ScheduleHarness(now: moment(2026, 11, 16, 7, 30))
        monday.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, weekdays: [2], command: .lock)
        ]
        await monday.controller.evaluate()
        #expect(monday.sent == [.lock])

        let tuesday = ScheduleHarness(now: moment(2026, 11, 17, 7, 30))
        tuesday.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, weekdays: [2], command: .lock)
        ]
        await tuesday.controller.evaluate()
        #expect(tuesday.sent.isEmpty)
    }

    @Test
    func aDisabledScheduleNeverFires() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 30))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock, isEnabled: false)
        ]

        await harness.controller.evaluate()

        #expect(harness.sent.isEmpty)
    }

    @Test
    func aStoredNonRoutineActionIsNotSentUnattended() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 30))
        // Written by a hand-edited defaults file or an older build: the editor never offers it,
        // but the scheduler must still refuse it.
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .unlock)
        ]

        await harness.controller.evaluate()

        #expect(harness.sent.isEmpty)
    }

    @Test
    func aDeferredSendLeavesTheOccurrenceOpenForOneRetry() async {
        let harness = ScheduleHarness(
            now: moment(2026, 11, 18, 7, 30),
            outcomes: [.deferred(reason: "Vehicle data is still loading."), .sent])
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        await harness.controller.evaluate()
        await harness.controller.evaluate()

        #expect(harness.sent == [.lock, .lock])
        #expect(harness.controller.nextFire(now: moment(2026, 11, 18, 7, 31)) != nil)
    }

    @Test
    func theNextFireIsTomorrowOnceTodaysMomentHasPassed() {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 8, 0))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        let next = harness.controller.nextFire(now: moment(2026, 11, 18, 8, 0))

        #expect(next.map { stockholmCalendar.isDate($0.date, inSameDayAs: moment(2026, 11, 19, 8, 0)) } == true)
    }

    @Test
    func startArmsATickForTheNextScheduledMoment() async {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 0))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 7, minute: 30, command: .lock)
        ]

        harness.controller.start()
        await settle()

        #expect(harness.controller.isArmed)
        let requested = await harness.timer.firstRequestedDelay()
        #expect(requested != nil)
        if let requested {
            // 07:00 → 07:30, within a second of rounding.
            #expect(abs(requested - 1_800) < 2)
        }
        harness.controller.stop()
        #expect(harness.controller.isArmed == false)
    }

    @Test
    func deletingAScheduleDropsItsFiredLedgerEntry() {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 30))
        let kept = ScheduledCommand(hour: 7, minute: 30, command: .lock)
        let removed = ScheduledCommand(hour: 8, minute: 0, command: .closeWindows)
        harness.preferences.scheduledCommands = [kept, removed]
        harness.preferences.setScheduledCommandFiredOccurrence("occurrence", for: removed.id)

        harness.preferences.scheduledCommands = [kept]
        harness.preferences.pruneScheduledCommandFiredOccurrences(keeping: [kept.id])

        #expect(harness.preferences.scheduledCommandFiredOccurrence(for: removed.id) == nil)
    }

    // MARK: - Domain

    @Test
    func storedSchedulesAreNormalisedOnRead() {
        let harness = ScheduleHarness(now: moment(2026, 11, 18, 7, 30))
        harness.preferences.scheduledCommands = [
            ScheduledCommand(hour: 99, minute: -5, weekdays: [0, 3, 9], command: .lock)
        ]

        let stored = harness.preferences.scheduledCommands.first

        #expect(stored?.hour == 23)
        #expect(stored?.minute == 0)
        #expect(stored?.weekdays == [3])
    }

    @Test
    func sevenChosenDaysReadBackAsEveryDay() {
        let schedule = ScheduledCommand(
            hour: 6, minute: 15, weekdays: Set(1...7), command: .lock)

        #expect(schedule.weekdays.isEmpty)
        #expect(schedule.daysSummary() == L10n.text("Every day"))
        #expect(ScheduledCommand(hour: 6, minute: 15, weekdays: Set(2...6), command: .lock)
            .daysSummary() == L10n.text("Weekdays"))
    }

    @Test
    func theOccurrenceKeyChangesWithTheCalendarDayButNotAcrossARefresh() {
        let schedule = ScheduledCommand(hour: 7, minute: 30, command: .lock)
        let wednesday = moment(2026, 11, 18, 7, 30)
        let nextWednesday = moment(2026, 11, 25, 7, 30)

        let first = ScheduledCommand.occurrenceKey(
            id: schedule.id, fireDate: wednesday, calendar: stockholmCalendar)
        let sameRun = ScheduledCommand.occurrenceKey(
            id: schedule.id, fireDate: wednesday.addingTimeInterval(2), calendar: stockholmCalendar)
        let nextWeek = ScheduledCommand.occurrenceKey(
            id: schedule.id, fireDate: nextWednesday, calendar: stockholmCalendar)

        #expect(first == sameRun)
        #expect(first != nextWeek)
    }
}

// MARK: - Harness

private let stockholmCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .gmt
    return calendar
}()

private func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    stockholmCalendar.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
}

@MainActor
private final class ScheduleHarness {
    let scoped = ScopedPreferences(label: "ScheduledCommands")
    let timer: AutomationTimerProbe
    private let sentBox: SentBox
    let controller: ScheduledCommandController

    var preferences: PreferencesStore { scoped.store }
    var sent: [RemoteCommand] { sentBox.commands }

    init(now: Date, outcomes: [AutomationSendResult] = []) {
        let probe = AutomationTimerProbe()
        let sentBox = SentBox()
        sentBox.outcomes = outcomes
        timer = probe
        self.sentBox = sentBox
        controller = ScheduledCommandController(
            preferences: scoped.store,
            send: { command in
                sentBox.commands.append(command)
                return sentBox.outcomes.isEmpty ? .sent : sentBox.outcomes.removeFirst()
            },
            now: { now },
            calendar: stockholmCalendar,
            wait: { seconds in try await probe.wait(seconds) })
    }
}

@MainActor
private final class SentBox {
    var commands: [RemoteCommand] = []
    var outcomes: [AutomationSendResult] = []
}

/// Stands in for the tick's `Task.sleep`: records the delay it was asked for and then parks
/// until cancelled, so no tick fires on its own during a test.
private actor AutomationTimerProbe {
    private var requested: [TimeInterval] = []
    private var parked: [CheckedContinuation<Void, Error>] = []

    func wait(_ seconds: TimeInterval) async throws {
        requested.append(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { parked.append($0) }
        } onCancel: {
            Task { await self.cancelParked() }
        }
    }

    func firstRequestedDelay() -> TimeInterval? { requested.first }

    private func cancelParked() {
        let waiting = parked
        parked = []
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}

@MainActor
private func settle() async {
    for _ in 0..<20 { await Task.yield() }
}
