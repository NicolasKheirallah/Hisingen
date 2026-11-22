import EventKit
import Foundation
import Testing
@testable import Hisingen

/// F-59 / F-61: the Reminders write-back and the calendar write-back. Composer tests
/// pin titles, notes, default due dates and dedupe keys without EventKit; writer
/// tests run against in-memory store fakes, so nothing here touches a real
/// Reminders or Calendar database.
@MainActor
@Suite("EventKit reminders and calendar write-back")
struct EventKitRemindersAndCalendarTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - ReminderComposer

    @Test
    func pluginDraft() {
        let now = utcDate(2026, 11, 21, 14)
        let draft = ReminderComposer.plugIn(
            vehicleName: "Polestar 2", batteryPercent: 20, now: now, calendar: utc
        )
        #expect(draft.title == L10n.format("Plug in %@", "Polestar 2"))
        // Due half an hour out, so it reads as upcoming rather than overdue.
        #expect(draft.dueDate == now.addingTimeInterval(30 * 60))
        // Keyed per day: the alert re-fires after a relaunch without piling up.
        #expect(draft.dedupeKey == "plugin-Polestar 2-2026-11-21")
        #expect(draft.notes.contains(ReminderComposer.keyLine(draft.dedupeKey)))
        #expect(draft.notes.contains(L10n.format(
            "Battery at %.0f%% and unplugged when Hisingen created this reminder.", 20.0
        )))
        // The automated path passes no battery figure when private banners are on.
        let privateDraft = ReminderComposer.plugIn(vehicleName: "Polestar 2", batteryPercent: nil, now: now)
        #expect(privateDraft.notes.contains(L10n.text(
            "Battery below the plug-in threshold and unplugged when Hisingen created this reminder."
        )))
    }

    @Test
    func serviceDraftDueOnTheReportedDay() {
        let now = utcDate(2026, 11, 21, 14)
        let service = ServiceSnapshot(daysToService: 30, distanceToServiceKm: 800, serviceWarning: true)
        let draft = ReminderComposer.serviceDue(vehicleName: "Volvo", service: service, now: now, calendar: utc)
        #expect(draft.title == L10n.format("Book service for %@", "Volvo"))
        #expect(draft.dedupeKey == "service-Volvo")
        #expect(draft.dueDate == utcDate(2026, 12, 21, 9))
        #expect(draft.notes.contains(L10n.text("The vehicle reported a service inspection warning.")))
        #expect(draft.notes.contains(L10n.format("%d days", 30)))
        #expect(draft.notes.contains(L10n.format("%d km", 800)))
    }

    @Test
    func serviceDraftNeverDueInThePast() {
        // Service already due today, and 09:00 has passed.
        let now = utcDate(2026, 11, 21, 11)
        let overdue = ServiceSnapshot(daysToService: 0, serviceWarning: true)
        let overdueDraft = ReminderComposer.serviceDue(vehicleName: "Volvo", service: overdue, now: now, calendar: utc)
        #expect(overdueDraft.dueDate == utcDate(2026, 11, 22, 9))

        // No day count reported at all: tomorrow morning rather than a stale moment.
        let bare = ServiceSnapshot(serviceWarning: true)
        let bareDraft = ReminderComposer.serviceDue(vehicleName: "Volvo", service: bare, now: now, calendar: utc)
        #expect(bareDraft.dueDate == utcDate(2026, 11, 22, 9))
    }

    @Test
    func tyreDraftListsOnlyFlaggedTyres() {
        let now = utcDate(2026, 11, 21, 20)
        let tyres = [
            TyrePressure(position: .frontLeft, kilopascals: 220, warning: .none),
            TyrePressure(position: .frontRight, kilopascals: nil, warning: .low),
            TyrePressure(position: .rearLeft, kilopascals: 230, warning: .none),
            TyrePressure(position: .rearRight, kilopascals: nil, warning: .veryLow)
        ]
        let draft = ReminderComposer.tyres(vehicleName: "Polestar 2", tyres: tyres, now: now, calendar: utc)
        #expect(draft.title == L10n.format("Check tyre pressures on %@", "Polestar 2"))
        #expect(draft.dedupeKey == "tyres-Polestar 2")
        #expect(draft.notes.contains("\(TyrePosition.frontRight.displayName): \(TyrePressureWarning.low.displayName)"))
        #expect(draft.notes.contains("\(TyrePosition.rearRight.displayName): \(TyrePressureWarning.veryLow.displayName)"))
        #expect(!draft.notes.contains(TyrePosition.frontLeft.displayName))
        #expect(draft.dueDate == utcDate(2026, 11, 22, 9))
    }

    @Test
    func keyMatchingIsLineExact() {
        #expect(ReminderComposer.notes("line\nHisingen reminder key: service-Volvo", containKey: "service-Volvo"))
        #expect(!ReminderComposer.notes("Hisingen reminder key: service-Volvo 2", containKey: "service-Volvo"))
        #expect(!ReminderComposer.notes(nil, containKey: "service-Volvo"))
    }

    // MARK: - ReminderWriter

    @Test
    func writerCreatesReminderInDefaultList() async throws {
        let now = Date()
        let session = FakeReminderSession()
        let writer = ReminderWriter(session: session)
        let outcome = await writer.addServiceReminder(
            vehicleName: "Volvo",
            service: ServiceSnapshot(daysToService: 30, serviceWarning: true),
            now: now
        )
        #expect(outcome == .created)
        #expect(session.saved.count == 1)
        let saved = try #require(session.saved.first)
        #expect(saved.title == L10n.format("Book service for %@", "Volvo"))
        #expect(saved.notes?.contains(ReminderComposer.keyLine("service-Volvo")) == true)
        #expect(saved.calendar === session.defaultList)
        // The due date survives the components round-trip through EventKit.
        let expected = ReminderComposer.serviceDue(
            vehicleName: "Volvo",
            service: ServiceSnapshot(daysToService: 30, serviceWarning: true),
            now: now,
            calendar: .current
        )
        let components = try #require(saved.dueDateComponents)
        #expect(Calendar.current.date(from: components) == expected.dueDate)
    }

    @Test
    func writerSkipsAnExistingReminder() async {
        let session = FakeReminderSession()
        session.seedReminder(notes: "old\nHisingen reminder key: service-Volvo")
        let writer = ReminderWriter(session: session)
        let outcome = await writer.addServiceReminder(
            vehicleName: "Volvo", service: ServiceSnapshot(serviceWarning: true)
        )
        #expect(outcome == .duplicate)
        #expect(session.saved.isEmpty)
    }

    @Test
    func writerReportsDeniedAccess() async {
        let session = FakeReminderSession(status: .denied)
        let writer = ReminderWriter(session: session)
        let outcome = await writer.addTyreReminder(
            vehicleName: "Volvo", tyres: [TyrePressure(position: .frontLeft, kilopascals: nil, warning: .low)]
        )
        #expect(outcome == .denied)
        #expect(session.saved.isEmpty)
        #expect(session.accessRequests == 0)
    }

    @Test
    func writerNeedsADefaultList() async {
        let session = FakeReminderSession(status: .fullAccess)
        // The fake fabricates a default list unless one is cleared explicitly; no default
        // list is the state the writer must refuse.
        session.defaultList = nil
        let writer = ReminderWriter(session: session)
        let outcome = await writer.addTyreReminder(
            vehicleName: "Volvo", tyres: [TyrePressure(position: .frontLeft, kilopascals: nil, warning: .low)]
        )
        #expect(outcome == .noDefaultList)
    }

    @Test
    func automationStaysOffByDefaultAndNeverPrompts() async {
        let scoped = ScopedDefaults()
        let defaults = scoped.defaults
        let session = FakeReminderSession(status: .notDetermined)
        let writer = ReminderWriter(session: session, defaults: defaults)
        let outcome = await writer.addPlugInReminderAutomatically(vehicleName: "Volvo", batteryPercent: 20)
        #expect(outcome == .disabled)
        #expect(session.accessRequests == 0)
        #expect(session.saved.isEmpty)
    }

    @Test
    func automationRequiresAccessAlreadyGranted() async {
        let scoped = ScopedDefaults()
        let defaults = scoped.defaults
        ReminderWriter.setPluginAutomation(true, in: defaults)
        let session = FakeReminderSession(status: .notDetermined)
        let writer = ReminderWriter(session: session, defaults: defaults)
        let outcome = await writer.addPlugInReminderAutomatically(vehicleName: "Volvo", batteryPercent: 20)
        // The background path must never raise the permission prompt.
        #expect(outcome == .noAccess)
        #expect(session.accessRequests == 0)
        #expect(session.saved.isEmpty)
    }

    @Test
    func automationWritesOncePerDay() async {
        let scoped = ScopedDefaults()
        let defaults = scoped.defaults
        ReminderWriter.setPluginAutomation(true, in: defaults)
        let session = FakeReminderSession(status: .fullAccess)
        let writer = ReminderWriter(session: session, defaults: defaults)
        let first = await writer.addPlugInReminderAutomatically(vehicleName: "Volvo", batteryPercent: 20)
        let second = await writer.addPlugInReminderAutomatically(vehicleName: "Volvo", batteryPercent: 20)
        #expect(first == .created)
        #expect(second == .duplicate)
        #expect(session.saved.count == 1)
    }

    // MARK: - ScheduleEventComposer

    @Test
    func chargingWindowSpansPastMidnight() throws {
        let now = utcDate(2026, 11, 21, 14)
        let start = utcDate(2026, 11, 22, 23, 30)
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 23, startMinute: 30,
            endHour: 7, endMinute: 30, weekdays: [], isActive: true
        )
        let draft = try #require(ScheduleEventComposer.compose(
            schedule: schedule, nextStart: start, vehicleName: "Polestar 2",
            dedupeKey: "charging|backend-1", now: now, calendar: utc
        ))
        #expect(draft.title == L10n.format("%@ (%@)", schedule.kind.title, "Polestar 2"))
        #expect(draft.startDate == start)
        #expect(draft.endDate == utcDate(2026, 11, 23, 7, 30))
        #expect(draft.notes == L10n.text("Created by Hisingen from a vehicle schedule.")
            + "\n" + ScheduleEventComposer.keyLine("charging|backend-1"))
    }

    @Test
    func scheduleWithoutEndBecomesThirtyMinutes() {
        let now = utcDate(2026, 11, 21, 14)
        let start = now.addingTimeInterval(3_600)
        let schedule = VehicleSchedule(
            kind: .departure, startHour: 7, startMinute: 30,
            endHour: nil, endMinute: nil, weekdays: [], isActive: true
        )
        let draft = ScheduleEventComposer.compose(
            schedule: schedule, nextStart: start, vehicleName: "Volvo",
            dedupeKey: "departure|backend-2", now: now, calendar: utc
        )
        #expect(draft?.startDate == start)
        #expect(draft?.endDate == start.addingTimeInterval(30 * 60))
    }

    @Test
    func composerRejectsStartsNotUpcoming() {
        let now = utcDate(2026, 11, 21, 14)
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 1, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [], isActive: true
        )
        #expect(ScheduleEventComposer.compose(
            schedule: schedule, nextStart: nil, vehicleName: "Volvo",
            dedupeKey: "k", now: now, calendar: utc
        ) == nil)
        #expect(ScheduleEventComposer.compose(
            schedule: schedule, nextStart: now.addingTimeInterval(-60), vehicleName: "Volvo",
            dedupeKey: "k", now: now, calendar: utc
        ) == nil)
    }

    // MARK: - ScheduleCalendarWriter

    @Test
    func calendarWriterCreatesTheEvent() throws {
        let session = FakeCalendarSession()
        let calendar = session.calendars[0]
        let writer = ScheduleCalendarWriter(session: session)
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 23, startMinute: 30,
            endHour: 7, endMinute: 30, weekdays: [], isActive: true
        )
        // EventKit stores dates at whole-second granularity, so the expected value is built
        // the same way; a sub-second Date would compare unequal after the round trip.
        let start = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded() + 3_600)
        let outcome = writer.add(
            schedule: schedule, nextStart: start, vehicleName: "Polestar 2",
            dedupeKey: "charging|backend-1", to: calendar
        )
        #expect(outcome == .created)
        #expect(session.savedEvents.count == 1)
        let event = try #require(session.savedEvents.first)
        #expect(event.calendar === calendar)
        #expect(event.isAllDay == false)
        #expect(event.startDate == start)
        #expect(event.endDate > event.startDate)
        #expect(event.notes?.contains(ScheduleEventComposer.keyLine("charging|backend-1")) == true)
    }

    @Test
    func calendarWriterRefusesASecondCopy() {
        let session = FakeCalendarSession()
        let calendar = session.calendars[0]
        session.seedEvent(calendar: calendar, notes: ScheduleEventComposer.keyLine("charging|backend-1"))
        let writer = ScheduleCalendarWriter(session: session)
        let schedule = VehicleSchedule(
            kind: .globalCharging, startHour: 23, startMinute: 30,
            endHour: 7, endMinute: 30, weekdays: [], isActive: true
        )
        let outcome = writer.add(
            schedule: schedule, nextStart: Date().addingTimeInterval(3_600), vehicleName: "Polestar 2",
            dedupeKey: "charging|backend-1", to: calendar
        )
        #expect(outcome == .duplicate)
        #expect(session.savedEvents.isEmpty)
    }

    @Test
    func calendarWriterWithoutAnUpcomingStart() {
        let session = FakeCalendarSession()
        let writer = ScheduleCalendarWriter(session: session)
        let schedule = VehicleSchedule(
            kind: .departure, startHour: 7, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [], isActive: true
        )
        let outcome = writer.add(
            schedule: schedule, nextStart: nil, vehicleName: "Polestar 2",
            dedupeKey: "departure|backend-2", to: session.calendars[0]
        )
        #expect(outcome == .noUpcomingStart)
    }

    @Test
    func calendarWriterReportsSaveFailure() {
        let session = FakeCalendarSession()
        session.saveShouldThrow = true
        let writer = ScheduleCalendarWriter(session: session)
        let schedule = VehicleSchedule(
            kind: .departure, startHour: 7, startMinute: 0,
            endHour: nil, endMinute: nil, weekdays: [], isActive: true
        )
        let outcome = writer.add(
            schedule: schedule, nextStart: Date().addingTimeInterval(3_600), vehicleName: "Polestar 2",
            dedupeKey: "departure|backend-2", to: session.calendars[0]
        )
        #expect(outcome == .saveFailed)
    }

    @Test
    func calendarAccessDeniedIsReported() async {
        let session = FakeCalendarSession(status: .denied)
        let writer = ScheduleCalendarWriter(session: session)
        #expect(await writer.requestEventAccessIfNeeded() == false)
    }

    // MARK: - Helpers

    /// A UUID-scoped defaults suite that removes itself when the test ends. The previous
    /// helper registered suites in the process-global defaults and swept them on the next
    /// call, which made cleanup depend on another test (or the next run) happening at all.
    private final class ScopedDefaults {
        nonisolated(unsafe) let defaults: UserDefaults
        private let suiteName: String

        init() {
            suiteName = "eventkit-tests-\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suiteName)!
        }

        deinit { defaults.removePersistentDomain(forName: suiteName) }
    }
}

/// In-memory ReminderStoreSession. Creates real EKReminder objects against a scratch
/// store (no permission needed until a save, which the fake never performs) so the
/// writer's field writes are exercised exactly as EventKit will see them.
@MainActor
private final class FakeReminderSession: ReminderStoreSession {
    var status: EKAuthorizationStatus
    var defaultList: EKCalendar?
    private(set) var saved: [EKReminder] = []
    private(set) var accessRequests = 0
    private var seeded: [EKReminder] = []
    private let scratch = EKEventStore()

    init(status: EKAuthorizationStatus = .fullAccess, defaultList: EKCalendar? = nil) {
        self.status = status
        if let defaultList {
            self.defaultList = defaultList
        } else if status == .fullAccess {
            let list = EKCalendar(for: .reminder, eventStore: scratch)
            list.title = "Hisingen Test List"
            self.defaultList = list
        }
    }

    func seedReminder(notes: String) {
        let reminder = EKReminder(eventStore: scratch)
        reminder.title = "seed"
        reminder.notes = notes
        seeded.append(reminder)
    }

    func authorizationStatus() -> EKAuthorizationStatus { status }

    func requestFullAccess() async throws -> Bool {
        accessRequests += 1
        return true
    }

    var defaultCalendarForNewReminders: EKCalendar? { defaultList }

    func newReminder() -> EKReminder { EKReminder(eventStore: scratch) }

    func save(_ reminder: EKReminder) throws { saved.append(reminder) }

    func allReminderNotes() async -> [String] {
        (saved + seeded).compactMap(\.notes)
    }
}

/// In-memory CalendarWritingSession with one writable calendar.
@MainActor
private final class FakeCalendarSession: CalendarWritingSession {
    var status: EKAuthorizationStatus
    var saveShouldThrow = false
    private(set) var savedEvents: [EKEvent] = []
    private var seededEvents: [EKEvent] = []
    let calendars: [EKCalendar]
    private let scratch = EKEventStore()

    init(status: EKAuthorizationStatus = .fullAccess) {
        self.status = status
        let calendar = EKCalendar(for: .event, eventStore: scratch)
        calendar.title = "Hisingen Test Calendar"
        self.calendars = status == .fullAccess ? [calendar] : []
    }

    func seedEvent(calendar: EKCalendar, notes: String) {
        let event = EKEvent(eventStore: scratch)
        event.title = "seed"
        event.notes = notes
        event.startDate = Date().addingTimeInterval(-3_600)
        event.endDate = event.startDate.addingTimeInterval(3_600)
        event.calendar = calendar
        seededEvents.append(event)
    }

    func authorizationStatus() -> EKAuthorizationStatus { status }

    func requestFullAccessToEvents() async throws -> Bool { true }

    func writableCalendars() -> [EKCalendar] { calendars }

    func newEvent() -> EKEvent { EKEvent(eventStore: scratch) }

    func save(_ event: EKEvent) throws {
        if saveShouldThrow { throw NSError(domain: "test", code: 1) }
        savedEvents.append(event)
    }

    func events(between start: Date, and end: Date, calendars: [EKCalendar]) -> [EKEvent] {
        savedEvents + seededEvents
    }
}
