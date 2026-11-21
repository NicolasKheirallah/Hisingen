import EventKit
import Foundation

/// Pure reminder content so tests can pin titles, notes, default due dates and the
/// dedupe keys without an EventKit store. The keys ride in the reminder's notes as
/// one whole line, which is what the writer matches when it decides a reminder for
/// the same thing already exists.
enum ReminderComposer {
    struct Draft: Equatable {
        let title: String
        let notes: String
        let dueDate: Date
        let dedupeKey: String
    }

    static let keyLinePrefix = "Hisingen reminder key: "

    /// The whole key line, matched line-by-line so `service-Name` can never match
    /// `service-Name 2`.
    static func keyLine(_ key: String) -> String {
        keyLinePrefix + key
    }

    /// True when the notes carry this exact key line.
    static func notes(_ notes: String?, containKey key: String) -> Bool {
        notes?.components(separatedBy: "\n").contains(keyLine(key)) == true
    }

    static func dayStamp(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// "Plug in at 20 %": due half an hour from the moment the battery crossed the
    /// threshold, so it lands in Reminders' today view as an upcoming item instead of
    /// an already-overdue one. One reminder per vehicle per day, because the alert
    /// re-fires after a relaunch.
    static func plugIn(
        vehicleName: String, batteryPercent: Double?, now: Date, calendar: Calendar = .current
    ) -> Draft {
        let body = batteryPercent.map {
            L10n.format("Battery at %.0f%% and unplugged when Hisingen created this reminder.", $0)
        } ?? L10n.text("Battery below the plug-in threshold and unplugged when Hisingen created this reminder.")
        let key = "plugin-\(vehicleName)-\(dayStamp(now, calendar: calendar))"
        return Draft(
            title: L10n.format("Plug in %@", vehicleName),
            notes: body + "\n" + keyLine(key),
            dueDate: now.addingTimeInterval(30 * 60),
            dedupeKey: key
        )
    }

    /// Due at 09:00 on the day the vehicle says service is due, so the reminder arrives
    /// when booking is still possible. A day count already elapsed, or none reported at
    /// all, falls back to tomorrow 09:00 rather than a due date in the past.
    static func serviceDue(
        vehicleName: String, service: ServiceSnapshot, now: Date, calendar: Calendar = .current
    ) -> Draft {
        var details: [String] = []
        if service.serviceWarning {
            details.append(L10n.text("The vehicle reported a service inspection warning."))
        }
        if let days = service.daysToService { details.append(L10n.format("%d days", days)) }
        if let km = service.distanceToServiceKm { details.append(L10n.format("%d km", km)) }
        let body = details.isEmpty ? L10n.text("Service inspection due.") : details.joined(separator: " · ")
        let key = "service-\(vehicleName)"
        return Draft(
            title: L10n.format("Book service for %@", vehicleName),
            notes: body + "\n" + keyLine(key),
            dueDate: morningDate(daysFrom: service.daysToService ?? 1, now: now, calendar: calendar),
            dedupeKey: key
        )
    }

    /// Tyre pressures are checked in daylight, so the reminder is due tomorrow at 09:00.
    /// The note lists only the tyres the vehicle flagged.
    static func tyres(
        vehicleName: String, tyres: [TyrePressure], now: Date, calendar: Calendar = .current
    ) -> Draft {
        let flagged = tyres.filter { $0.warning.needsAttention }
        let body = flagged.map { "\($0.position.displayName): \($0.warning.displayName)" }
            .joined(separator: ", ")
        let key = "tyres-\(vehicleName)"
        return Draft(
            title: L10n.format("Check tyre pressures on %@", vehicleName),
            notes: body + "\n" + keyLine(key),
            dueDate: morningDate(daysFrom: 1, now: now, calendar: calendar),
            dedupeKey: key
        )
    }

    /// 09:00 `days` days from now; if that moment has already passed, the next day.
    private static func morningDate(daysFrom days: Int, now: Date, calendar: Calendar) -> Date {
        let day = calendar.date(byAdding: .day, value: max(0, days), to: calendar.startOfDay(for: now))
            ?? calendar.startOfDay(for: now)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = 9
        parts.minute = 0
        let due = calendar.date(from: parts) ?? now
        return due > now ? due : calendar.date(byAdding: .day, value: 1, to: due) ?? due
    }
}

/// EventKit seam in the shape of `NotificationDispatching`: the production conformant
/// wraps one long-lived `EKEventStore`, tests inject an in-memory fake.
@MainActor
protocol ReminderStoreSession: AnyObject {
    func authorizationStatus() -> EKAuthorizationStatus
    func requestFullAccess() async throws -> Bool
    var defaultCalendarForNewReminders: EKCalendar? { get }
    func newReminder() -> EKReminder
    func save(_ reminder: EKReminder) throws
    /// The notes of every reminder in every list, used only for dedupe key matching.
    /// EventKit's fetch is completion-based and answers off-main; returning plain
    /// strings keeps the hand-off to the main actor Sendable, which an array of
    /// EKReminder objects would not be.
    func allReminderNotes() async -> [String]
}

@MainActor
final class EventKitReminderSession: ReminderStoreSession {
    private let store: EKEventStore

    init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .reminder)
    }

    func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccessToReminders()
    }

    var defaultCalendarForNewReminders: EKCalendar? {
        store.defaultCalendarForNewReminders()
    }

    func newReminder() -> EKReminder {
        EKReminder(eventStore: store)
    }

    func save(_ reminder: EKReminder) throws {
        try store.save(reminder, commit: true)
    }

    func allReminderNotes() async -> [String] {
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                // Reads on the callback queue are safe: EventKit objects allow
                // concurrent reads, and only the resulting strings cross back.
                continuation.resume(returning: (reminders ?? []).compactMap(\.notes))
            }
        }
    }
}

/// Creates Reminders from vehicle states. Writes only on an explicit tap, plus one
/// opt-in automated path that never raises the Reminders permission prompt: a
/// background alert must not put a system dialog on screen with nobody watching.
@MainActor
final class ReminderWriter {
    enum Outcome: Equatable {
        case created
        case duplicate
        /// The user denied or restricted Reminders access.
        case denied
        /// The automated path ran without access already granted; nothing was written.
        case noAccess
        /// The automated path is switched off.
        case disabled
        /// No default Reminders list exists to write to.
        case noDefaultList
        /// EventKit refused the save (access revoked mid-session, list removed).
        case saveFailed
    }

    /// Opt-in for the automated plug-in reminder. Owned here rather than in
    /// `PreferencesStore` only because the persistence layer is being refactored in
    /// another session; the key and its default (off) follow the same UserDefaults
    /// pattern and should move to `PreferencesStore+Notifications` with the rest.
    static let pluginAutomationDefaultsKey = "reminders_plugin_automation_v1"

    static func pluginAutomationEnabled(in defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: pluginAutomationDefaultsKey)
    }

    static func setPluginAutomation(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: pluginAutomationDefaultsKey)
    }

    /// The instance the automated path uses; manual actions build one around the
    /// caller's own event store.
    static let shared = ReminderWriter()

    private let session: any ReminderStoreSession
    private let defaults: UserDefaults

    init(session: (any ReminderStoreSession)? = nil, defaults: UserDefaults = .standard) {
        self.session = session ?? EventKitReminderSession()
        self.defaults = defaults
    }

    /// Requests Reminders access when it was never asked for. Used from user gestures
    /// (an Add Reminder tap, the Settings toggle); the automated path never calls it.
    func requestAccessIfNeeded() async -> Bool {
        switch session.authorizationStatus() {
        case .fullAccess, .authorized:
            return true
        case .notDetermined:
            return (try? await session.requestFullAccess()) ?? false
        default:
            return false
        }
    }

    func addPlugInReminder(
        vehicleName: String, batteryPercent: Double?, now: Date = Date()
    ) async -> Outcome {
        guard await requestAccessIfNeeded() else { return .denied }
        return await create(
            ReminderComposer.plugIn(vehicleName: vehicleName, batteryPercent: batteryPercent, now: now)
        )
    }

    func addServiceReminder(
        vehicleName: String, service: ServiceSnapshot, now: Date = Date()
    ) async -> Outcome {
        guard await requestAccessIfNeeded() else { return .denied }
        return await create(
            ReminderComposer.serviceDue(vehicleName: vehicleName, service: service, now: now)
        )
    }

    func addTyreReminder(
        vehicleName: String, tyres: [TyrePressure], now: Date = Date()
    ) async -> Outcome {
        guard await requestAccessIfNeeded() else { return .denied }
        return await create(ReminderComposer.tyres(vehicleName: vehicleName, tyres: tyres, now: now))
    }

    /// The automated "plug in at the threshold" trigger, called from the plug-in alert.
    /// Runs only when the reader switched it on and access was already granted; a
    /// permission prompt from a background notification is never acceptable.
    func addPlugInReminderAutomatically(
        vehicleName: String, batteryPercent: Double?, now: Date = Date()
    ) async -> Outcome {
        guard Self.pluginAutomationEnabled(in: defaults) else { return .disabled }
        switch session.authorizationStatus() {
        case .fullAccess, .authorized:
            return await create(
                ReminderComposer.plugIn(vehicleName: vehicleName, batteryPercent: batteryPercent, now: now)
            )
        default:
            return .noAccess
        }
    }

    private func create(_ draft: ReminderComposer.Draft) async -> Outcome {
        let existingNotes = await session.allReminderNotes()
        if existingNotes.contains(where: { ReminderComposer.notes($0, containKey: draft.dedupeKey) }) {
            return .duplicate
        }
        guard let list = session.defaultCalendarForNewReminders else { return .noDefaultList }
        let reminder = session.newReminder()
        reminder.title = draft.title
        reminder.notes = draft.notes
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: draft.dueDate
        )
        reminder.dueDateComponents = components
        reminder.calendar = list
        do {
            try session.save(reminder)
            return .created
        } catch {
            return .saveFailed
        }
    }
}
