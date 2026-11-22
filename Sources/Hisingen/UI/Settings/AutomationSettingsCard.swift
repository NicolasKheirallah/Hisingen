import SwiftUI

/// The reader's unattended actions: what runs at a time, what runs when the car arrives or
/// leaves a saved charge location, and one command sent to every vehicle at once.
///
/// Everything here is opt-in and empty by default. Each row's action is limited to the commands
/// that need no confirmation (`AutomationCommandPolicy`), because these fire with nobody at the
/// Mac to answer a sheet.
@MainActor
struct AutomationSettingsCards: View {
    let binder: PreferenceBinder
    var state: VehicleState? = nil

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            ScheduledActionsCard(binder: binder)
            LocationTriggersCard(binder: binder, locations: savedLocations)
            FleetBroadcastCard(binder: binder)
            RecurringReportCard(binder: binder)
        }
    }

    private var savedLocations: [ChargeLocationSnapshot] {
        (state?.energy.locations ?? []).filter(\.isSavedLocation)
    }
}

// MARK: - Scheduled actions

@MainActor
private struct ScheduledActionsCard: View {
    let binder: PreferenceBinder

    private var preferences: PreferencesStore { binder.preferences }
    private var schedules: [ScheduledCommand] { preferences.scheduledCommands }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeaderWithAccessory(
                    heading: CardHeader(
                        symbol: "clock.badge.checkmark",
                        title: L10n.text("Scheduled Actions"),
                        color: HisingenTheme.chartAttention)
                ) {
                    Button(L10n.text("Add")) {
                        var updated = schedules
                        updated.append(ScheduledCommand(hour: 7, minute: 30, command: .lock))
                        write(updated)
                    }
                    .buttonStyle(.pressable)
                    .hisType(.caption, weight: .medium)
                    .help(L10n.text("Add scheduled action"))
                    .accessibilityLabel(L10n.text("Add scheduled action"))
                }
                Text(L10n.text("Runs one action at the time and days you choose, against the vehicle that is active then. Only actions that need no confirmation can be scheduled."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)

                if schedules.isEmpty {
                    Text(L10n.text("No scheduled actions yet."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(schedules.enumerated()), id: \.element.id) { index, schedule in
                        if index > 0 { Divider().opacity(HisingenTheme.dividerOpacity) }
                        row(index: index, schedule: schedule)
                    }
                }
            }
        }
    }

    private func row(index: Int, schedule: ScheduledCommand) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { schedule.isEnabled },
                    set: { enabled in mutate(index) { $0.isEnabled = enabled } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(L10n.format("Enable %@", schedule.command.title))

                commandMenu(command: schedule.command) { command in
                    mutate(index) { $0.command = command }
                }

                Spacer(minLength: 0)

                Button {
                    var updated = schedules
                    updated.remove(at: index)
                    write(updated)
                } label: {
                    Image(systemName: "trash")
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Delete"))
                .accessibilityLabel(L10n.text("Delete"))
            }
            HStack(spacing: 10) {
                DatePicker("", selection: Binding(
                    get: { Format.clockDate(hour: schedule.hour, minute: schedule.minute) },
                    set: { date in
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                        mutate(index) {
                            $0.hour = parts.hour ?? $0.hour
                            $0.minute = parts.minute ?? $0.minute
                        }
                    }
                ), displayedComponents: .hourAndMinute)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 82)
                .accessibilityLabel(L10n.text("Time"))

                weekdayChips(schedule: schedule, index: index)
                Spacer(minLength: 0)
            }
        }
    }

    private func weekdayChips(schedule: ScheduledCommand, index: Int) -> some View {
        let symbols = Self.weekdaySymbols()
        return HStack(spacing: 2) {
            ForEach(1...7, id: \.self) { day in
                weekdayChip(day: day, schedule: schedule, index: index, symbols: symbols)
            }
        }
    }

    private func weekdayChip(day: Int, schedule: ScheduledCommand, index: Int,
                             symbols: (mark: [String], name: [String])) -> some View {
        let isOn = schedule.weekdays.contains(day)
        let mark = Self.symbol(symbols.mark, at: day)
        let name = Self.symbol(symbols.name, at: day)
        return Button {
            toggle(day: day, index: index)
        } label: {
            Text(mark)
                .hisType(.micro, weight: isOn ? .semibold : .regular)
                .foregroundStyle(isOn ? HisingenTheme.ink : HisingenTheme.inkMuted)
                .frame(minWidth: 16, minHeight: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func toggle(day: Int, index: Int) {
        mutate(index) { value in
            // Toggling the first day off "every day" must not be read as a filter of one: start
            // from the full set so the reader's click means what it shows.
            var days = value.weekdays.isEmpty ? Set(1...7) : value.weekdays
            if days.contains(day) { days.remove(day) } else { days.insert(day) }
            value.weekdays = days.count == 7 ? [] : days
        }
    }

    private static func weekdaySymbols() -> (mark: [String], name: [String]) {
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        return (formatter.veryShortWeekdaySymbols, formatter.shortWeekdaySymbols)
    }

    /// Sunday-first symbol arrays, indexed by a calendar weekday number (1 = Sunday).
    private static func symbol(_ symbols: [String], at day: Int) -> String {
        symbols.indices.contains(day - 1) ? symbols[day - 1] : "\(day)"
    }

    private func mutate(_ index: Int, _ change: (inout ScheduledCommand) -> Void) {
        var updated = schedules
        guard updated.indices.contains(index) else { return }
        change(&updated[index])
        write(updated)
    }

    private func write(_ updated: [ScheduledCommand]) {
        preferences.scheduledCommands = updated
        binder.bump()
        binder.notify(.automation)
    }
}

// MARK: - Arrival and departure triggers

@MainActor
private struct LocationTriggersCard: View {
    let binder: PreferenceBinder
    let locations: [ChargeLocationSnapshot]

    private var preferences: PreferencesStore { binder.preferences }
    private var triggers: [LocationTrigger] { preferences.locationTriggers }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeaderWithAccessory(
                    heading: CardHeader(
                        symbol: "location.circle",
                        title: L10n.text("Arrival & Departure"),
                        color: HisingenTheme.chartAttention)
                ) {
                    Button(L10n.text("Add")) {
                        var updated = triggers
                        updated.append(LocationTrigger(event: .arrival, command: .startChargingOverride))
                        write(updated)
                    }
                    .buttonStyle(.pressable)
                    .hisType(.caption, weight: .medium)
                    .help(L10n.text("Add location trigger"))
                    .accessibilityLabel(L10n.text("Add location trigger"))
                }
                Text(L10n.text("Compares the position Hisingen already reads from the car with the charge locations you saved. No Location Services permission is asked for, and triggers only fire while Hisingen is running."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)

                if triggers.isEmpty {
                    Text(L10n.text("No arrival or departure triggers yet."))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(triggers.enumerated()), id: \.element.id) { index, trigger in
                        if index > 0 { Divider().opacity(HisingenTheme.dividerOpacity) }
                        row(index: index, trigger: trigger)
                    }
                }
            }
        }
    }

    private func row(index: Int, trigger: LocationTrigger) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { trigger.isEnabled },
                    set: { enabled in mutate(index) { $0.isEnabled = enabled } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(L10n.format("Enable %@", trigger.command.title))

                Picker("", selection: Binding(
                    get: { trigger.event },
                    set: { event in mutate(index) { $0.event = event } }
                )) {
                    Text(L10n.text("Arrive")).tag(LocationTrigger.Event.arrival)
                    Text(L10n.text("Leave")).tag(LocationTrigger.Event.departure)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)

                locationMenu(trigger: trigger) { locationID in
                    mutate(index) { $0.locationID = locationID }
                }

                Spacer(minLength: 0)

                Button {
                    var updated = triggers
                    updated.remove(at: index)
                    write(updated)
                } label: {
                    Image(systemName: "trash")
                        .hisType(.caption)
                        .foregroundStyle(HisingenTheme.inkMuted)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Delete"))
                .accessibilityLabel(L10n.text("Delete"))
            }
            commandMenu(command: trigger.command) { command in
                mutate(index) { $0.command = command }
            }
        }
    }

    private func locationMenu(trigger: LocationTrigger, select: @escaping (String?) -> Void) -> some View {
        let selectedAlias = locations.first { $0.id == trigger.locationID }?.alias
        return Menu {
            Button(L10n.text("Any saved charge location")) { select(nil) }
            ForEach(locations) { location in
                Button(location.alias.isEmpty ? L10n.text("Saved charge location") : location.alias) {
                    select(location.id)
                }
            }
        } label: {
            Text(selectedAlias ?? L10n.text("Any saved charge location"))
                .hisType(.caption)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
        .frame(maxWidth: 170)
        .help(L10n.text("Saved charge location"))
    }

    private func mutate(_ index: Int, _ change: (inout LocationTrigger) -> Void) {
        var updated = triggers
        guard updated.indices.contains(index) else { return }
        change(&updated[index])
        write(updated)
    }

    private func write(_ updated: [LocationTrigger]) {
        preferences.locationTriggers = updated
        binder.bump()
        binder.notify(.automation)
    }
}

// MARK: - Fleet broadcast

@MainActor
private struct FleetBroadcastCard: View {
    let binder: PreferenceBinder

    @State private var command: RemoteCommand = .lock

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "car.2", title: L10n.text("Send to Every Vehicle"),
                           color: HisingenTheme.chartAttention)
                HStack(spacing: 10) {
                    commandMenu(command: command) { command = $0 }
                    Spacer(minLength: 0)
                    Button(L10n.text("Send now")) {
                        binder.notify(.broadcastCommand(command))
                    }
                    .buttonStyle(.pressable)
                    .hisType(.caption, weight: .medium)
                }
            }
        }
    }
}

// MARK: - Recurring report

/// The weekly or monthly report banner. It is configured here, beside the other things that run
/// without the reader present, and it reports on the vehicle that is active when the window ends.
@MainActor
private struct RecurringReportCard: View {
    let binder: PreferenceBinder

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeaderWithAccessory(
                    heading: CardHeader(
                        symbol: "doc.text",
                        title: L10n.text("Recurring Report"),
                        color: HisingenTheme.chartAttention)
                ) {
                    Toggle("", isOn: Binding(
                        get: { preferences.recurringReportEnabled },
                        set: { enabled in
                            preferences.recurringReportEnabled = enabled
                            binder.bump()
                            binder.notify(.reporting)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(L10n.text("Recurring report"))
                }
                Text(L10n.text("Posts one banner when a week or month ends, summarising distance, energy and cost. The full report is on the History tab, and every figure comes from data already on this Mac."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                if preferences.recurringReportEnabled {
                    Picker("", selection: Binding(
                        get: { preferences.recurringReportCadence },
                        set: { cadence in
                            preferences.recurringReportCadence = cadence
                            binder.bump()
                            binder.notify(.reporting)
                        }
                    )) {
                        ForEach(ReportCadence.allCases) { cadence in
                            Text(cadence.title).tag(cadence)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                    .accessibilityLabel(L10n.text("Report period"))
                }
            }
        }
    }
}

// MARK: - Shared menu

/// The action menu a schedule and a trigger share. It lists only what
/// `AutomationCommandPolicy` allows, so the reader cannot build a row that would be refused
/// silently at its firing moment.
@MainActor
private func commandMenu(command: RemoteCommand, select: @escaping (RemoteCommand) -> Void) -> some View {
    Menu {
        ForEach(Array(AutomationCommandPolicy.choices().enumerated()), id: \.offset) { _, choice in
            Button(choice.title) { select(choice) }
        }
    } label: {
        HStack(spacing: 4) {
            Text(command.title)
                .hisType(.caption)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .hisType(.micro)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
    }
    .menuStyle(.borderlessButton)
    .controlSize(.small)
    .frame(maxWidth: 190)
    .accessibilityLabel(command.title)
}
