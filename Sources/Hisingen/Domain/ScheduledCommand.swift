import Foundation

/// One action the reader scheduled for a wall-clock time on chosen weekdays.
///
/// `targetVIN` scopes the schedule to one vehicle. A legacy schedule can run without a choice
/// when there is exactly one vehicle in the garage.
struct ScheduledCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    /// Wall-clock hour and minute in the Mac's current time zone.
    var hour: Int
    var minute: Int
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday). Empty means every day.
    var weekdays: Set<Int>
    var command: RemoteCommand
    var isEnabled: Bool
    var targetVIN: String? = nil

    init(id: UUID = UUID(), hour: Int, minute: Int, weekdays: Set<Int> = [],
         command: RemoteCommand, isEnabled: Bool = true, targetVIN: String? = nil) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = Self.sanitized(weekdays)
        self.command = command
        self.isEnabled = isEnabled
        let normalized = targetVIN?.normalizedVIN
        self.targetVIN = (normalized?.isEmpty == false) ? normalized : nil
    }

    private enum CodingKeys: String, CodingKey {
        case id, hour, minute, weekdays, command, isEnabled, targetVIN
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(UUID.self, forKey: .id),
            hour: try c.decode(Int.self, forKey: .hour),
            minute: try c.decode(Int.self, forKey: .minute),
            weekdays: try c.decode(Set<Int>.self, forKey: .weekdays),
            command: try c.decode(RemoteCommand.self, forKey: .command),
            isEnabled: try c.decode(Bool.self, forKey: .isEnabled),
            targetVIN: try c.decodeIfPresent(String.self, forKey: .targetVIN)
        )
    }

    /// A stored entry can carry anything a hand-edited defaults file or an older build wrote;
    /// every reader goes through this rather than trusting the decoded fields.
    var sanitized: ScheduledCommand {
        var copy = self
        copy.hour = min(max(hour, 0), 23)
        copy.minute = min(max(minute, 0), 59)
        copy.weekdays = Self.sanitized(weekdays)
        let normalized = targetVIN?.normalizedVIN
        copy.targetVIN = (normalized?.isEmpty == false) ? normalized : nil
        return copy
    }

    private static func sanitized(_ weekdays: Set<Int>) -> Set<Int> {
        let valid = weekdays.filter { (1...7).contains($0) }
        // Seven days is the same thing as no day filter; storing it as empty keeps one
        // representation for "every day".
        return valid.count == 7 ? [] : valid
    }

    var firesEveryDay: Bool { weekdays.isEmpty }

    /// Whether the schedule's weekday filter admits `date`.
    func matchesWeekday(of date: Date, calendar: Calendar) -> Bool {
        firesEveryDay || weekdays.contains(calendar.component(.weekday, from: date))
    }

    /// The occurrence on `day`, in the calendar's zone, or `nil` when the weekday filter
    /// excludes that day.
    func fireDate(on day: Date, calendar: Calendar) -> Date? {
        guard let candidate = calendar.date(
            bySettingHour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59), second: 0,
            of: day) else { return nil }
        return matchesWeekday(of: candidate, calendar: calendar) ? candidate : nil
    }

    /// The latest occurrence at or before `now`, looking back a week. `nil` when no day in that
    /// window carries the schedule.
    func mostRecentFireDate(atOrBefore now: Date, calendar: Calendar) -> Date? {
        let startOfNow = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfNow),
                  let candidate = fireDate(on: day, calendar: calendar) else { continue }
            if candidate <= now { return candidate }
        }
        return nil
    }

    /// The first occurrence strictly after `now`, looking forward a week.
    func nextFireDate(after now: Date, calendar: Calendar) -> Date? {
        let startOfNow = calendar.startOfDay(for: now)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfNow),
                  let candidate = fireDate(on: day, calendar: calendar) else { continue }
            if candidate > now { return candidate }
        }
        return nil
    }

    /// Whether this schedule should fire now. The catch-up window is deliberate: a Mac that woke
    /// a minute after the scheduled moment still locks the car, while one that wakes at breakfast
    /// does not lock it six hours late.
    func isDue(now: Date, calendar: Calendar, catchUp: TimeInterval = ScheduledCommand.defaultCatchUp)
    -> Date? {
        guard isEnabled, AutomationCommandPolicy.allows(command),
              let recent = mostRecentFireDate(atOrBefore: now, calendar: calendar),
              now.timeIntervalSince(recent) <= catchUp else { return nil }
        return recent
    }

    /// Fifteen minutes: long enough for a wake-from-sleep tick to land after the moment, short
    /// enough that a missed schedule is skipped rather than replayed at a wrong hour.
    static let defaultCatchUp: TimeInterval = 15 * 60

    /// The dedupe key for one occurrence. Built from the calendar day and clock minute so a
    /// daylight-saving shift or a time-zone change cannot make the same run look new.
    static func occurrenceKey(id: UUID, fireDate: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
        return "\(id.uuidString)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            + "-\(parts.hour ?? 0)-\(parts.minute ?? 0)"
    }

    /// "Every day", "Weekdays" or the chosen days' short names, for the settings row.
    func daysSummary(calendar: Calendar = .current) -> String {
        if firesEveryDay { return L10n.text("Every day") }
        if weekdays == Set(2...6) { return L10n.text("Weekdays") }
        return weekdays.sorted().map { day in
            // `veryShortWeekdaySymbols` is Sunday-first; the weekday numbers are 1 = Sunday.
            let symbols = Self.weekdaySymbols(calendar: calendar)
            return symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)"
        }.joined(separator: ", ")
    }

    private static func weekdaySymbols(calendar: Calendar) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.calendar = calendar
        return formatter.veryShortWeekdaySymbols
    }

    /// The wall-clock time as the reader set it, e.g. "07:30" in the app's chosen format.
    func timeText(calendar: Calendar = .current) -> String {
        Format.clockTime(hour: min(max(hour, 0), 23), minute: min(max(minute, 0), 59))
    }
}
