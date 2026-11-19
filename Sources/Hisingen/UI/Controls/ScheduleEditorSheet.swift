import SwiftUI

@MainActor
struct ScheduleEditorSheet: View {
    let state: VehicleState
    /// Which segment the "Add Schedule" form opens on, so the caller's context (a climate card
    /// vs. a charging card) carries through.
    var initialKind: ScheduleKind = .climate
    var initialSchedule: VehicleSchedule? = nil
    let onRemoteCommand: (RemoteCommand) -> Void
    /// Whether another remote command is already running.
    ///
    /// The sheet takes a raw command closure rather than a `ControlsCommandGate`, so unlike
    /// every card in the tab it had no busy state at all: a tap while a command was in flight
    /// was refused by the coordinator with nothing visible happening, and the banner that would
    /// have said so renders behind the modal sheet.
    var isBusy: Bool = false
    var availableKinds: [ScheduleKind] = [.climate, .globalCharging]
    var availability: (RemoteCommand) -> CommandAvailability = { _ in .available }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedKind: ScheduleKind = .climate
    @State private var startHour: Int = 7
    @State private var startMinute: Int = 30
    @State private var endHour: Int = 6
    @State private var endMinute: Int = 0
    @State private var selectedWeekdays: Set<VehicleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var isEnabled: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func timePicker(_ title: String, hour: Binding<Int>, minute: Binding<Int>) -> some View {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Format.clockTimeZone
        let time = Binding(
            get: { Format.clockDate(hour: hour.wrappedValue, minute: minute.wrappedValue) },
            set: {
                hour.wrappedValue = calendar.component(.hour, from: $0)
                minute.wrappedValue = calendar.component(.minute, from: $0)
            }
        )
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).hisType(.caption, weight: .medium).foregroundStyle(.secondary)
            DatePicker(title, selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .datePickerStyle(.stepperField)
                .controlSize(.small)
                .environment(\.calendar, calendar)
                .environment(\.timeZone, Format.clockTimeZone)
        }
    }

    private var scheduleKinds: [ScheduleKind] {
        if let initialSchedule { return [initialSchedule.kind] }
        return availableKinds
    }

    private var commandAvailability: CommandAvailability {
        isBusy ? .unavailableWhileBusy : availability(command)
    }

    /// A charging window with identical start and end covers no time; block the save so the
    /// backend never gets a zero-length timer.
    private var chargingWindowInvalid: Bool {
        selectedKind == .globalCharging && startHour == endHour && startMinute == endMinute
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(HisingenTheme.dividerOpacity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    scheduleConfigSection
                    if let reason = commandAvailability.shortReason {
                        Text(reason)
                            .hisType(.label)
                            .foregroundStyle(HisingenTheme.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if chargingWindowInvalid {
                        Label(L10n.text("Start and end time cannot be the same."), systemImage: "exclamationmark.triangle.fill")
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(HisingenTheme.semanticWarning)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(16)
                .hisAnimation(Motion.entrance, value: chargingWindowInvalid)
            }

            Divider().opacity(HisingenTheme.dividerOpacity)
            footerButtons
        }
        .frame(width: 380)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? 520 : 360)
        .background(HisingenTheme.canvas)
        .onAppear {
            if let initialSchedule { beginEditing(initialSchedule) }
            else { selectedKind = scheduleKinds.contains(initialKind) ? initialKind : scheduleKinds.first ?? initialKind }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.badge.checkmark.fill")
                .foregroundStyle(HisingenTheme.accent)
                .hisType(.title)
            Text(L10n.text(initialSchedule == nil ? "Add Schedule" : "Edit Schedule"))
                .hisType(.subhead, weight: .bold)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .hisType(.subhead)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.text("Close"))
            .help(L10n.text("Close"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func beginEditing(_ schedule: VehicleSchedule) {
        selectedKind = schedule.kind
        startHour = schedule.startHour ?? 7
        startMinute = schedule.startMinute ?? 30
        endHour = schedule.endHour ?? 6
        endMinute = schedule.endMinute ?? 0
        selectedWeekdays = Set(schedule.weekdays)
        isEnabled = schedule.isActive
    }

    private var scheduleConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if scheduleKinds.count > 1 {
                Picker(L10n.text("Schedule"), selection: $selectedKind) {
                    ForEach(scheduleKinds, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
            } else {
                Text(selectedKind.title)
                    .hisType(.subhead)
            }

            HStack(spacing: 12) {
                timePicker(selectedKind == .climate ? L10n.text("Departure Time") : L10n.text("Start Time"),
                           hour: $startHour, minute: $startMinute)

                if selectedKind == .globalCharging {
                    timePicker(L10n.text("End Time"), hour: $endHour, minute: $endMinute)
                        .transition(.opacity)
                }
            }

            if selectedKind == .climate {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("Repeat Days"))
                        .hisType(.caption, weight: .medium)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        ForEach([VehicleWeekday.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday], id: \.self) { day in
                            let selected = selectedWeekdays.contains(day)
                            Button {
                                if selected { selectedWeekdays.remove(day) } else { selectedWeekdays.insert(day) }
                            } label: {
                                Text(day.shortName)
                                    .hisType(.micro, weight: selected ? .bold : .regular)
                                    .frame(maxWidth: .infinity, minHeight: 24)
                                    .background {
                                        if selected {
                                            RoundedRectangle(cornerRadius: 0).fill(HisingenTheme.accent)
                                        } else {
                                            HoverChipFill(shape: RoundedRectangle(cornerRadius: 0), resting: 0.06)
                                        }
                                    }
                                    .foregroundStyle(selected ? HisingenTheme.canvas : Color.primary)
                                    .animation(reduceMotion ? nil : Motion.selection, value: selected)
                            }
                            .buttonStyle(.pressable)
                            .accessibilityLabel(day.shortName)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
            } else {
                Text(L10n.text("Daily"))
                    .hisType(.label)
                    .foregroundStyle(HisingenTheme.inkMuted)
            }

            Toggle(L10n.text("Enable this schedule"), isOn: $isEnabled)
                .hisType(.label)
                .toggleStyle(.checkbox)
        }
        .hisAnimation(Motion.layout, value: selectedKind)
    }

    private var footerButtons: some View {
        HStack {
            Button(L10n.text("Cancel")) {
                dismiss()
            }
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(L10n.text("Save Schedule")) {
                guard commandAvailability.isAvailable, !chargingWindowInvalid else { return }
                onRemoteCommand(command)
                dismiss()
            }
            .buttonStyle(.hisProminent(HisingenTheme.accent))
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(chargingWindowInvalid || !commandAvailability.isAvailable)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var command: RemoteCommand {
        let schedule = VehicleSchedule(
            backendID: initialSchedule?.backendID,
            index: initialSchedule?.index,
            kind: selectedKind,
            startHour: startHour,
            startMinute: startMinute,
            endHour: selectedKind == .globalCharging ? endHour : nil,
            endMinute: selectedKind == .globalCharging ? endMinute : nil,
            weekdays: selectedKind == .climate ? selectedWeekdays.sorted { $0.rawValue < $1.rawValue } : [],
            isActive: isEnabled
        )

        return selectedKind == .climate ? .setClimateTimer(schedule) : .setGlobalChargeTimer(schedule)
    }
}
