import SwiftUI

/// Plan (2026-11-16 redesign) opens on time, not on a second copy of the car: what the car is set
/// to do next, in the order it will happen. Charging windows, departure times and climate timers
/// come from the car's own schedules; nothing is projected beyond what they say. The controls
/// that edit them follow underneath.
@MainActor
struct PlanTimeline: View {
    let state: VehicleState

    @Environment(\.preferencesStore) private var preferences

    private var condensed: Bool { HisingenTheme.layoutWidth < 600 }

    struct Entry: Identifiable {
        let id: String
        let schedule: VehicleSchedule
        /// The next start the schedule itself implies, when it carries enough to say.
        let next: Date?
    }

    /// Active schedules, soonest first. A schedule without a computable next start (no weekdays,
    /// no one-shot date) still appears, after the dated ones, with its time alone.
    static func entries(for state: VehicleState, now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        (state.energy.schedules + state.climateTimers)
            .filter(\.isActive)
            .map { Entry(id: $0.rowIdentity, schedule: $0, next: nextStart(of: $0, after: now, calendar: calendar)) }
            .sorted { lhs, rhs in
                switch (lhs.next, rhs.next) {
                case let (l?, r?): return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.id < rhs.id
                }
            }
    }

    static func nextStart(of schedule: VehicleSchedule, after now: Date, calendar: Calendar) -> Date? {
        if let once = schedule.oneShotDate { return once > now ? once : nil }
        guard let hour = schedule.startHour, !schedule.weekdays.isEmpty else { return nil }
        let minute = schedule.startMinute ?? 0
        let wanted = Set(schedule.weekdays.map { ($0.rawValue % 7) + 1 })
        for offset in 0..<8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  wanted.contains(calendar.component(.weekday, from: day)),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  candidate > now else { continue }
            return candidate
        }
        return nil
    }

    var body: some View {
        let entries = Self.entries(for: state)
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text("Upcoming"))
                .hisType(size: condensed ? 18 : 21, relativeTo: .title2, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 12)
            if entries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("Nothing scheduled"))
                        .hisType(.body, weight: .semibold)
                        .foregroundStyle(HisingenTheme.ink)
                    Text(L10n.text("Charging windows, departure times and climate timers set on the car appear here."))
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .overlay(alignment: .top) { rule }
            } else {
                VStack(spacing: 0) {
                    ForEach(entries) { entry in
                        row(entry)
                        rule
                    }
                }
                .overlay(alignment: .top) { rule }
            }
        }
        .padding(.horizontal, condensed ? 16 : 24)
        .padding(.top, condensed ? 14 : 20)
        .padding(.bottom, 6)
        .accessibilityElement(children: .contain)
    }

    private var rule: some View {
        Rectangle().fill(HisingenTheme.hairline).frame(height: 1)
    }

    private func row(_ entry: Entry) -> some View {
        let schedule = entry.schedule
        return HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(timeText(schedule))
                .hisType(size: condensed ? 18 : 20, relativeTo: .title3, weight: .light)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.ink)
                .frame(minWidth: condensed ? 104 : 128, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(schedule.kind.title)
                    .hisType(.body, weight: .semibold)
                    .foregroundStyle(HisingenTheme.ink)
                Text(detailText(entry))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if schedule.syncNeedsAttention {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(HisingenTheme.semanticWarning)
                    .help(L10n.text("Timer Sync"))
                    .accessibilityLabel(L10n.text("Timer Sync"))
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func clock(_ hour: Int?, _ minute: Int?) -> String? {
        guard let hour else { return nil }
        var components = DateComponents()
        components.hour = hour
        components.minute = minute ?? 0
        guard let date = Calendar.current.date(from: components) else { return nil }
        return Format.timeFormatter.string(from: date)
    }

    private func timeText(_ schedule: VehicleSchedule) -> String {
        let start = clock(schedule.startHour, schedule.startMinute)
            ?? schedule.oneShotDate.map { Format.timeFormatter.string(from: $0) }
            ?? "–"
        guard let end = clock(schedule.endHour, schedule.endMinute) else { return start }
        return L10n.format("%@–%@", start, end)
    }

    private func detailText(_ entry: Entry) -> String {
        var parts: [String] = []
        if let next = entry.next {
            parts.append(Format.dateFormatter.string(from: next))
        }
        if entry.schedule.oneShotDate == nil, !entry.schedule.weekdays.isEmpty {
            parts.append(entry.schedule.weekdays.map(\.shortName).joined(separator: " "))
        }
        if let place = entry.schedule.locationName, !place.isEmpty {
            parts.append(place)
        }
        return parts.joined(separator: " · ")
    }
}
