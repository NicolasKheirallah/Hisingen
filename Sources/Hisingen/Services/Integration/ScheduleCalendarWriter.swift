import EventKit
import Foundation

/// Pure event content for the calendar write-back, so tests can pin the title, the
/// note that carries the dedupe key, and the start/end derivation without EventKit.
///
/// One event stands for one schedule: it is placed on the schedule's next start, and
/// the note carries a stable key so a second add to the same calendar does nothing.
/// Hisingen never deletes events it created; a schedule can also disappear on the
/// vehicle's side without any local signal to hook, so removal is left to the reader
/// (the key line makes the event easy to find in Calendar).
enum ScheduleEventComposer {
    struct Draft: Equatable {
        let title: String
        let notes: String
        let startDate: Date
        let endDate: Date
        let dedupeKey: String
    }

    static let keyLinePrefix = "Hisingen schedule key: "

    static func keyLine(_ key: String) -> String {
        keyLinePrefix + key
    }

    /// True when the notes carry this exact key line.
    static func notes(_ notes: String?, containKey key: String) -> Bool {
        notes?.components(separatedBy: "\n").contains(keyLine(key)) == true
    }

    /// The event spans the schedule's reported window: a charging window that ends
    /// after midnight gets an end on the next day. A schedule with no end time
    /// becomes a 30-minute event, the shortest span Calendar renders usefully.
    /// `nil` when there is no upcoming start to place the event on.
    static func compose(
        schedule: VehicleSchedule,
        nextStart: Date?,
        vehicleName: String,
        dedupeKey: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Draft? {
        guard let start = nextStart, start > now else { return nil }
        let end: Date
        if let endHour = schedule.endHour {
            var parts = calendar.dateComponents([.year, .month, .day], from: start)
            parts.hour = endHour
            parts.minute = schedule.endMinute ?? 0
            let sameDay = calendar.date(from: parts) ?? start
            end = sameDay > start
                ? sameDay
                : calendar.date(byAdding: .day, value: 1, to: sameDay) ?? start.addingTimeInterval(30 * 60)
        } else {
            end = start.addingTimeInterval(30 * 60)
        }
        let body = L10n.text("Created by Hisingen from a vehicle schedule.")
        return Draft(
            title: L10n.format("%@ (%@)", schedule.kind.title, vehicleName),
            notes: body + "\n" + keyLine(dedupeKey),
            startDate: start,
            endDate: end,
            dedupeKey: dedupeKey
        )
    }
}

/// EventKit seam in the shape of `NotificationDispatching`: the production conformant
/// wraps one long-lived `EKEventStore`, tests inject an in-memory fake.
@MainActor
protocol CalendarWritingSession: AnyObject {
    func authorizationStatus() -> EKAuthorizationStatus
    func requestFullAccessToEvents() async throws -> Bool
    /// Calendars the reader can write to; the destination picker offers only these.
    func writableCalendars() -> [EKCalendar]
    func newEvent() -> EKEvent
    func save(_ event: EKEvent) throws
    /// Events in the window on the given calendars; the writer filters by note key.
    func events(between start: Date, and end: Date, calendars: [EKCalendar]) -> [EKEvent]
}

@MainActor
final class EventKitCalendarSession: CalendarWritingSession {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestFullAccessToEvents() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func writableCalendars() -> [EKCalendar] {
        store.calendars(for: .event).filter { $0.allowsContentModifications }
    }

    func newEvent() -> EKEvent {
        EKEvent(eventStore: store)
    }

    func save(_ event: EKEvent) throws {
        try store.save(event, span: .thisEvent, commit: true)
    }

    func events(between start: Date, and end: Date, calendars: [EKCalendar]) -> [EKEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate)
    }
}

/// Creates calendar events from vehicle schedules. Reads and writes share the one
/// EventKit grant the calendar-preconditioning feature already requests; nothing here
/// sends data anywhere, the event stays in the reader's own calendar store.
@MainActor
final class ScheduleCalendarWriter {
    enum Outcome: Equatable {
        case created
        case duplicate
        /// The schedule has no upcoming start to place an event on.
        case noUpcomingStart
        /// EventKit refused the save (access revoked mid-session, calendar removed).
        case saveFailed
    }

    /// A previous event for a recurring schedule can sit weeks back, so the dedupe
    /// look-back covers two months on both sides of the occurrence.
    private static let dedupeLookback: TimeInterval = 60 * 86_400

    private let session: any CalendarWritingSession

    init(session: (any CalendarWritingSession)? = nil) {
        self.session = session ?? EventKitCalendarSession()
    }

    func requestEventAccessIfNeeded() async -> Bool {
        switch session.authorizationStatus() {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            return (try? await session.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    func writableCalendars() -> [EKCalendar] {
        session.writableCalendars().sorted { $0.title < $1.title }
    }

    /// Adds the schedule's next occurrence to the chosen calendar, or reports
    /// `.duplicate` when an event with the same schedule key is already there.
    func add(
        schedule: VehicleSchedule,
        nextStart: Date?,
        vehicleName: String,
        dedupeKey: String,
        to calendar: EKCalendar,
        now: Date = Date()
    ) -> Outcome {
        guard let draft = ScheduleEventComposer.compose(
            schedule: schedule, nextStart: nextStart, vehicleName: vehicleName,
            dedupeKey: dedupeKey, now: now
        ) else { return .noUpcomingStart }
        let windowStart = draft.startDate.addingTimeInterval(-Self.dedupeLookback)
        let windowEnd = draft.endDate.addingTimeInterval(Self.dedupeLookback)
        let existing = session.events(between: windowStart, and: windowEnd, calendars: [calendar])
        if existing.contains(where: {
            $0.calendar?.calendarIdentifier == calendar.calendarIdentifier
                && ScheduleEventComposer.notes($0.notes, containKey: draft.dedupeKey)
        }) {
            return .duplicate
        }
        let event = session.newEvent()
        event.title = draft.title
        event.notes = draft.notes
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        event.isAllDay = false
        event.calendar = calendar
        do {
            try session.save(event)
            return .created
        } catch {
            return .saveFailed
        }
    }
}
