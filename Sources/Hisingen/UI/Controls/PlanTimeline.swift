import SwiftUI

@MainActor
struct PlanTimeline: View {
    let state: VehicleState

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.preferencesStore) private var preferences

    struct Entry: Identifiable {
        let id: String
        let schedule: VehicleSchedule
        let next: Date?
    }

    static func entries(for state: VehicleState, now: Date = Date(), calendar: Calendar = .current) -> [Entry] {
        (state.energy.schedules + state.climateTimers)
            .filter { $0.isActive && ($0.oneShotDate.map { $0 > now } ?? true) }
            .map {
                Entry(id: "\($0.kind.rawValue)-\($0.rowIdentity)", schedule: $0,
                      next: nextStart(of: $0, after: now, calendar: calendar))
            }
            .sorted { lhs, rhs in
                switch (lhs.next, rhs.next) {
                case let (l?, r?) where l != r: return l < r
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
        let stale = state.freshness.isCached || state.hasOldData() || state.freshness.retainedDataCategories.contains {
            $0 == .chargingSchedule || $0 == .climateStatus
        }
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text(stale && !entries.isEmpty ? "Last reported schedules" : "Upcoming"))
                .hisType(.displaySmall, weight: .semibold)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
                .padding(.bottom, 10)
            if entries.isEmpty {
                rule
                Text(L10n.text("No upcoming schedules reported"))
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            } else {
                ForEach(entries) { entry in
                    rule
                    row(entry, leads: entry.id == entries.first?.id && entry.next != nil)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HisingenTheme.cardPadding)
        .padding(.top, 10)
        .accessibilityElement(children: .contain)
    }

    private var rule: some View {
        Rectangle().fill(HisingenTheme.hairline).frame(height: 1)
            .accessibilityHidden(true)
    }

    private func row(_ entry: Entry, leads: Bool) -> some View {
        let schedule = entry.schedule
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 14))
        let detail = detailText(entry)
        return layout {
            Text(timeText(entry))
                .hisType(leads ? .display : .displaySmall, weight: leads ? .light : .regular)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: typeSize.isAccessibilitySize ? nil : 140, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.kind.title)
                    .hisType(.body, weight: .semibold)
                    .foregroundStyle(HisingenTheme.ink)
                if !detail.isEmpty {
                    Text(detail)
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                if schedule.syncNeedsAttention {
                    Label(L10n.text("Timer Sync"), systemImage: "clock.badge.exclamationmark")
                        .hisType(.label, weight: .semibold)
                        .foregroundStyle(HisingenTheme.semanticWarning)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, leads ? 12 : 8)
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

    private func timeText(_ entry: Entry) -> String {
        let schedule = entry.schedule
        let start = entry.next.map { Format.timeFormatter.string(from: $0) }
            ?? clock(schedule.startHour, schedule.startMinute)
            ?? L10n.text("Unavailable")
        guard let end = clock(schedule.endHour, schedule.endMinute) else { return start }
        return L10n.format("%@–%@", start, end)
    }

    private func detailText(_ entry: Entry) -> String {
        var parts: [String] = []
        if let next = entry.next {
            let calendar = Calendar.current
            if calendar.isDateInToday(next) {
                parts.append(L10n.text("Today"))
            } else if calendar.isDateInTomorrow(next) {
                parts.append(L10n.text("Tomorrow"))
            } else {
                parts.append(Format.dateFormatter.string(from: next))
            }
        } else if !entry.schedule.weekdays.isEmpty {
            parts.append(entry.schedule.weekdays.map(\.shortName).joined(separator: " "))
        }
        if !preferences.privacyRedactionEnabled, let place = entry.schedule.locationName, !place.isEmpty {
            parts.append(place)
        }
        return parts.joined(separator: " · ")
    }
}
