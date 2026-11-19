import SwiftUI

@MainActor
struct PlanTimeline: View {
    let state: VehicleState
    var canEdit: (VehicleSchedule) -> Bool = { _ in false }
    var onEdit: (VehicleSchedule) -> Void = { _ in }
    /// Opens the schedule editor for a new timer. Nil when the reader cannot create one.
    var onAdd: (() -> Void)? = nil
    var canDelete: (VehicleSchedule) -> Bool = { _ in false }
    var onDelete: (VehicleSchedule) -> Void = { _ in }
    var onOpenLocation: ((String) -> Void)? = nil
    var homeCharging: HomeChargingModel? = nil
    var offersHomePlan = false

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.preferencesStore) private var preferences
    @State private var inspectedEntry: Entry?
    @State private var pendingDelete: Entry?

    struct Entry: Identifiable {
        let id: String
        let schedule: VehicleSchedule
        let next: Date?
        var locationID: String? = nil
    }

    static func entries(
        for state: VehicleState, now: Date = Date(), calendar: Calendar = .current,
        includeInactive: Bool = false
    ) -> [Entry] {
        let locationEntries = state.savedChargeLocations.flatMap { location in
            let timers = location.chargeTimers.map {
                locationSchedule($0, kind: .locationCharging, location: location)
            }
            let departures = location.departureTimes.map {
                locationSchedule($0, kind: .departure, location: location)
            }
            return (timers + departures).map { schedule in
                Entry(id: "\(location.id)|\(scheduleIdentity(schedule))", schedule: schedule,
                      next: nextStart(of: schedule, after: now, calendar: calendar), locationID: location.id)
            }
        }
        let locatedScheduleIDs = Set(locationEntries.map { scheduleIdentity($0.schedule) })
        let reported = (state.energy.schedules + state.climateTimers).compactMap { schedule -> Entry? in
            let id = scheduleIdentity(schedule)
            guard !locatedScheduleIDs.contains(id) else { return nil }
            return Entry(id: id, schedule: schedule, next: nextStart(of: schedule, after: now, calendar: calendar))
        }
        var seenIDs: Set<String> = []
        return (reported + locationEntries)
            .filter { includeInactive || ($0.schedule.isActive && ($0.schedule.oneShotDate.map { $0 > now } ?? true)) }
            .filter { seenIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                switch (lhs.next, rhs.next) {
                case let (l?, r?) where l != r: return l < r
                case (.some, nil): return true
                case (nil, .some): return false
                default: return lhs.id < rhs.id
                }
            }
    }

    private static func locationSchedule(
        _ schedule: VehicleSchedule, kind: ScheduleKind, location: ChargeLocationSnapshot
    ) -> VehicleSchedule {
        VehicleSchedule(
            backendID: schedule.backendID, index: schedule.index, kind: kind,
            startHour: schedule.startHour, startMinute: schedule.startMinute,
            endHour: schedule.endHour, endMinute: schedule.endMinute, weekdays: schedule.weekdays,
            isActive: schedule.isActive, locationName: schedule.locationName ?? (location.alias.isEmpty ? nil : location.alias),
            oneShotDate: schedule.oneShotDate, syncStatus: schedule.syncStatus, repeatsWeekly: schedule.repeatsWeekly
        )
    }

    private static func scheduleIdentity(_ schedule: VehicleSchedule) -> String {
        let kind = schedule.kind.rawValue
        if let backendID = schedule.backendID, !backendID.isEmpty { return "\(kind)|\(backendID)" }
        let start = schedule.rowIdentity
        let end = "\(schedule.endHour ?? -1):\(schedule.endMinute ?? -1)"
        let occurrence = schedule.oneShotDate.map { String($0.timeIntervalSince1970) } ?? ""
        return [kind, start, end, occurrence, schedule.locationName ?? ""].joined(separator: "|")
    }

    static func nextStart(of schedule: VehicleSchedule, after now: Date, calendar: Calendar) -> Date? {
        guard schedule.isActive else { return nil }
        if let once = schedule.oneShotDate { return once > now ? once : nil }
        guard let hour = schedule.startHour else { return nil }
        let minute = schedule.startMinute ?? 0
        if schedule.kind == .globalCharging, schedule.weekdays.isEmpty {
            return calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: minute),
                                     matchingPolicy: .nextTime)
        }
        guard !schedule.weekdays.isEmpty else { return nil }
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
        let entries = Self.entries(for: state, includeInactive: true)
        let stale = state.freshness.isCached || state.hasOldData() || state.freshness.retainedDataCategories.contains {
            $0 == .chargingSchedule || $0 == .climateStatus
        }
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.text(stale && !entries.isEmpty ? "Last reported schedules" : "Schedules"))
                .hisType(.displaySmall)
                .foregroundStyle(HisingenTheme.ink)
                .accessibilityAddTraits(.isHeader)
            .padding(.bottom, 12)
            if entries.isEmpty {
                PanelRule()
                Text(L10n.text("No upcoming schedules reported"))
                    .hisType(.body)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 10)
            } else {
                ForEach(entries) { entry in
                    PanelRule()
                    timelineRow(entry, leads: false)
                }
            }
            if let homeCharging {
                ChargerScheduleRows(state: state, model: homeCharging, offersHomePlan: offersHomePlan)
            }
            if state.energy.pendingGlobalChargeTimer == true
                || (state.energy.pendingClimateTimerCount ?? 0) > 0
                || (state.energy.pendingClimateTimerDeletionCount ?? 0) > 0
                || state.energy.pendingTimerSettings == true {
                PanelRule()
                Label(L10n.text("Timer update queued · applies when the car wakes"), systemImage: "clock.badge.clock")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                    .padding(.vertical, 8)
            }
            if let onAdd {
                PanelRule()
                Button(action: onAdd) {
                    HStack(spacing: 6) {
                        Text(L10n.text("Add Schedule"))
                            .hisType(.subhead)
                        Image(systemName: "arrow.right")
                            .hisSymbolSize(11)
                            .accessibilityHidden(true)
                        Spacer()
                    }
                    .foregroundStyle(HisingenTheme.ink)
                    .frame(minHeight: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .confirmationDialog(
            L10n.text("Delete climate timer"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { entry in
            Button(L10n.text("Delete"), role: .destructive) {
                onDelete(entry.schedule)
                pendingDelete = nil
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingDelete = nil }
        }
        .sheet(item: $inspectedEntry) { entry in
            VStack(alignment: .leading, spacing: 10) {
                row(entry, leads: entry.next != nil)
                Label(L10n.text("View only"), systemImage: "lock")
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
                if let locationID = entry.locationID, let onOpenLocation {
                    NavigationRow(title: L10n.text("Open Charge Location")) {
                        inspectedEntry = nil
                        onOpenLocation(locationID)
                    }
                }
                HStack {
                    Spacer()
                    Button(L10n.text("Done")) { inspectedEntry = nil }
                        .buttonStyle(.hisSecondary)
                        .keyboardShortcut(.cancelAction)
                }
            }
            .padding(16)
            .frame(width: 340)
            .background(HisingenTheme.canvas)
        }
    }

    private func timelineRow(_ entry: Entry, leads: Bool) -> some View {
        let editable = entry.locationID == nil && canEdit(entry.schedule)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 8))
        return layout {
            row(entry, leads: leads)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                if editable { onEdit(entry.schedule) }
                else { inspectedEntry = entry }
            } label: {
                HStack(spacing: 5) {
                    Text(L10n.text(editable ? "Edit" : "Details"))
                        .hisType(.body)
                    Image(systemName: "arrow.right")
                        .hisSymbolSize(10)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(HisingenTheme.ink)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.format(editable ? "Edit %@" : "Details for %@", entry.schedule.kind.title))
            .padding(.bottom, typeSize.isAccessibilitySize ? 10 : 0)
            if entry.locationID == nil, canDelete(entry.schedule) {
                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                        .frame(minWidth: 32, minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(L10n.text("Delete climate timer"))
                .help(L10n.text("Delete climate timer"))
            }
        }
        .contextMenu {
            Button(L10n.text(editable ? "Edit" : "Details")) {
                if editable { onEdit(entry.schedule) }
                else { inspectedEntry = entry }
            }
            if entry.locationID == nil, canDelete(entry.schedule) {
                Button(L10n.text("Delete climate timer"), role: .destructive) { pendingDelete = entry }
            }
        }
    }

    private func row(_ entry: Entry, leads: Bool) -> some View {
        let schedule = entry.schedule
        let layout = typeSize.isAccessibilitySize || HisingenTheme.layoutWidth < 510
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 20))
        let detail = detailText(entry)
        return layout {
            Text(timeText(entry))
                .hisType(size: leads ? 37 : 22, relativeTo: .title)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: typeSize.isAccessibilitySize ? nil : 132, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(schedule.kind.title)
                    .hisType(.subhead)
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
        .padding(.vertical, leads ? 15 : 10)
        .accessibilityElement(children: .combine)
    }

    private func clock(_ hour: Int?, _ minute: Int?) -> String? {
        guard let hour else { return nil }
        return Format.clockTime(hour: hour, minute: minute ?? 0)
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
        var parts = [L10n.text("Vehicle")]
        if !entry.schedule.isActive { parts.append(L10n.text("Off")) }
        if entry.schedule.kind == .globalCharging && entry.schedule.weekdays.isEmpty {
            parts.append(L10n.text("Daily"))
        }
        if let next = entry.next {
            let calendar = Calendar.current
            if calendar.isDateInToday(next) {
                parts.append(L10n.text("Today"))
            } else if calendar.isDateInTomorrow(next) {
                parts.append(L10n.text("Tomorrow"))
            } else {
                parts.append(Format.dateFormatter.string(from: next))
            }
        } else if let once = entry.schedule.oneShotDate {
            parts.append(Format.dateFormatter.string(from: once))
        } else if !entry.schedule.weekdays.isEmpty {
            parts.append(entry.schedule.weekdays.map(\.shortName).joined(separator: " "))
        }
        if !preferences.privacyRedactionEnabled, let place = entry.schedule.locationName, !place.isEmpty {
            parts.append(place)
        }
        return parts.joined(separator: " · ")
    }
}
