import Foundation

/// How often a report is produced. The cadence owns both the reporting window and the words the
/// reader sees for it, so a weekly report and a weekly summary notification cannot disagree about
/// which seven days they cover.
enum ReportCadence: String, Codable, CaseIterable, Identifiable, Sendable {
    case weekly
    case monthly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return L10n.text("Weekly")
        case .monthly: return L10n.text("Monthly")
        }
    }

    /// The window `date` falls in, in the reader's own calendar (so a week starts where their
    /// locale says it does).
    func period(containing date: Date, calendar: Calendar = .current) -> ReportPeriod {
        let component: Calendar.Component = self == .weekly ? .weekOfYear : .month
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            let start = calendar.startOfDay(for: date)
            return ReportPeriod(cadence: self, start: start,
                                end: calendar.date(byAdding: .day, value: 1, to: start) ?? start)
        }
        return ReportPeriod(cadence: self, start: interval.start, end: interval.end)
    }

    /// The window that ended the moment the window containing `date` began: the report a
    /// recurring schedule produces when a new week or month starts.
    func completedPeriod(endingAt date: Date, calendar: Calendar = .current) -> ReportPeriod {
        // One second before the *window's* first instant, not one second before `date`: a report
        // asked for at 09:00 on the 1st is about the month that ended, not the one that began.
        let current = period(containing: date, calendar: calendar)
        return period(containing: current.start.addingTimeInterval(-1), calendar: calendar)
    }
}

/// One reporting window, half-open: `start` is included, `end` is not. Half-open is what keeps a
/// trip at midnight from being counted in two weeks at once.
struct ReportPeriod: Equatable, Sendable {
    let cadence: ReportCadence
    let start: Date
    let end: Date

    var duration: TimeInterval { end.timeIntervalSince(start) }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }

    /// Stable identity for the "this period was already reported" ledger.
    var key: String {
        "\(cadence.rawValue)|\(Int(start.timeIntervalSince1970))"
    }

    /// The window as the reader reads it: "11 Nov – 17 Nov 2026" for a week, "November 2026"
    /// for a month. Both are calendar arithmetic on the same dates the totals used.
    func titleText(calendar: Calendar = .current) -> String {
        switch cadence {
        case .weekly:
            let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? start
            let startText = Format.shortDate(date: start)
            let endText = Format.shortDate(date: lastDay)
            return L10n.format("%@ – %@", startText, endText)
        case .monthly:
            let formatter = DateFormatter()
            formatter.locale = L10n.displayLocale
            formatter.calendar = calendar
            formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
            return formatter.string(from: start)
        }
    }
}
