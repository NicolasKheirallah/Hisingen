import AppKit
import EventKit
import Foundation

struct CalendarPreconditioningEvent: Equatable, Sendable {
    let identifier: String
    let title: String
    let startDate: Date
    let isAllDay: Bool

    var occurrenceKey: String {
        "\(identifier)|\(Int(startDate.timeIntervalSince1970))"
    }
}

enum CalendarPreconditioningPlanner {
    /// Returns timed, not-yet-fired events whose lead-time threshold has passed but whose
    /// actual start is still in the future. This makes wake-from-sleep useful without firing
    /// climate for an event that has already begun.
    static func dueEvents(
        from events: [CalendarPreconditioningEvent],
        now: Date,
        leadTimeMinutes: Int,
        firedOccurrenceKeys: Set<String>
    ) -> [CalendarPreconditioningEvent] {
        let lead = TimeInterval(max(1, leadTimeMinutes) * 60)
        return events
            .filter { event in
                !event.isAllDay
                    && event.startDate > now
                    && event.startDate.addingTimeInterval(-lead) <= now
                    && !firedOccurrenceKeys.contains(event.occurrenceKey)
            }
            .sorted { $0.startDate < $1.startDate }
    }
}

/// Always-running menu-bar scheduler for calendar-driven climate starts. Rather than polling
/// EventKit on a fixed interval, it looks ahead, arms a single one-shot timer for the next
/// event's lead-time moment, and re-arms on wake and on `.EKEventStoreChanged`. EventKit stays
/// on the main actor; only calendar identifiers and occurrence keys are persisted.
@MainActor
final class CalendarPreconditioningController {
    private let preferences: PreferencesStore
    private let eventStore: EKEventStore
    private let sendClimateStart: () -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var evaluationInProgress = false

    /// Never sleep the scheduler longer than this, so a change notification we somehow miss
    /// still gets caught within a few hours.
    private static let maxIdleInterval: TimeInterval = 6 * 3_600
    private static let lookaheadInterval: TimeInterval = 48 * 3_600

    init(preferences: PreferencesStore, eventStore: EKEventStore = EKEventStore(),
         sendClimateStart: @escaping () -> Void) {
        self.preferences = preferences
        self.eventStore = eventStore
        self.sendClimateStart = sendClimateStart
    }

    func start() {
        guard observers.isEmpty else { reload(); return }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        })
        reload()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }

    /// Called when the feature toggle, lead time, or selected calendars change.
    func reload() {
        timer?.invalidate()
        timer = nil
        guard preferences.calendarPreconditioningEnabled else { return }
        Task { await evaluate() }
    }

    func evaluate(now: Date = Date()) async {
        guard !evaluationInProgress, preferences.calendarPreconditioningEnabled,
              !preferences.calendarPreconditioningCalendarIDs.isEmpty,
              Self.hasCalendarAccess else {
            scheduleNext(now: now)
            return
        }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let stored = preferences.calendarPreconditioningFiredOccurrences
        // Keep a small, bounded dedup ledger; recurring-event keys include occurrence time.
        let cutoff = now.addingTimeInterval(-7 * 86_400).timeIntervalSince1970
        var fired = stored.filter { $0.value >= cutoff }

        let calendars = selectedCalendars()
        guard !calendars.isEmpty else {
            persist(fired, ifDifferentFrom: stored)
            scheduleNext(now: now)
            return
        }
        let lead = preferences.calendarPreconditioningLeadTimeMinutes
        let horizon = now.addingTimeInterval(TimeInterval((lead + 2) * 60))
        let predicate = eventStore.predicateForEvents(withStart: now, end: horizon, calendars: calendars)
        let candidates = eventStore.events(matching: predicate).map {
            CalendarPreconditioningEvent(
                identifier: $0.calendarItemIdentifier,
                title: $0.title ?? L10n.text("Calendar event"),
                startDate: $0.startDate,
                isAllDay: $0.isAllDay
            )
        }
        let due = CalendarPreconditioningPlanner.dueEvents(
            from: candidates, now: now, leadTimeMinutes: lead,
            firedOccurrenceKeys: Set(fired.keys)
        )
        guard let event = due.first else {
            persist(fired, ifDifferentFrom: stored)
            scheduleNext(now: now)
            return
        }

        // One command at a time even when several events share a start. Record every due
        // occurrence in that cluster so the next arming cannot duplicate it.
        for dueEvent in due where abs(dueEvent.startDate.timeIntervalSince(event.startDate)) < 60 {
            fired[dueEvent.occurrenceKey] = now.timeIntervalSince1970
        }
        persist(fired, ifDifferentFrom: stored)
        sendClimateStart()
        scheduleNext(now: now)
    }

    /// The next event whose lead-time moment is still in the future, across the selected
    /// calendars, or `nil` if none within the look-ahead window.
    func nextTrigger(now: Date = Date()) -> (title: String, eventStart: Date, fireAt: Date)? {
        guard preferences.calendarPreconditioningEnabled else { return nil }
        return Self.nextTrigger(eventStore: eventStore, preferences: preferences, now: now)
    }

    /// Standalone form so the Settings card can preview the next trigger with its own store.
    static func nextTrigger(eventStore: EKEventStore, preferences: PreferencesStore,
                            now: Date = Date()) -> (title: String, eventStart: Date, fireAt: Date)? {
        guard hasCalendarAccess, !preferences.calendarPreconditioningCalendarIDs.isEmpty else { return nil }
        let calendars = eventStore.calendars(for: .event).filter {
            preferences.calendarPreconditioningCalendarIDs.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return nil }
        let lead = TimeInterval(preferences.calendarPreconditioningLeadTimeMinutes * 60)
        let fired = Set(preferences.calendarPreconditioningFiredOccurrences.keys)
        let predicate = eventStore.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(lookaheadInterval), calendars: calendars)
        return eventStore.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now }
            .compactMap { event -> (String, Date, Date)? in
                let key = "\(event.calendarItemIdentifier)|\(Int(event.startDate.timeIntervalSince1970))"
                guard !fired.contains(key) else { return nil }
                let fireAt = max(event.startDate.addingTimeInterval(-lead), now)
                return (event.title ?? L10n.text("Calendar event"), event.startDate, fireAt)
            }
            .min { $0.1 < $1.1 }
            .map { (title: $0.0, eventStart: $0.1, fireAt: $0.2) }
    }

    private func selectedCalendars() -> [EKCalendar] {
        eventStore.calendars(for: .event).filter {
            preferences.calendarPreconditioningCalendarIDs.contains($0.calendarIdentifier)
        }
    }

    private func persist(_ fired: [String: Double], ifDifferentFrom previous: [String: Double]) {
        guard fired != previous else { return }
        preferences.calendarPreconditioningFiredOccurrences = fired
    }

    /// Arms a single one-shot timer for the next lead-time moment (or the idle ceiling).
    private func scheduleNext(now: Date) {
        timer?.invalidate()
        timer = nil
        guard preferences.calendarPreconditioningEnabled else { return }
        let fallback = now.addingTimeInterval(Self.maxIdleInterval)
        let fireAt = nextTrigger(now: now).map { max($0.fireAt, now.addingTimeInterval(1)) }
        let target = min(fireAt ?? fallback, fallback)
        let delay = max(1, target.timeIntervalSince(now))
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in await self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    static var hasCalendarAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }
}
