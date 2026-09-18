import SwiftUI

@MainActor
struct ScheduleEditorSheet: View {
    let state: VehicleState
    /// Which segment the "Add Schedule" form opens on, so the caller's context (a climate card
    /// vs. a charging card) carries through.
    var initialKind: ScheduleKind = .climate
    let onRemoteCommand: (RemoteCommand) -> Void
    /// Whether another remote command is already running.
    ///
    /// The sheet takes a raw command closure rather than a `ControlsCommandGate`, so unlike
    /// every card in the tab it had no busy state at all: a tap while a command was in flight
    /// was refused by the coordinator with nothing visible happening, and the banner that would
    /// have said so renders behind the modal sheet.
    var isBusy: Bool = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedKind: ScheduleKind = .climate
    @State private var startHour: Int = 7
    @State private var startMinute: Int = 30
    @State private var endHour: Int = 6
    @State private var endMinute: Int = 0
    @State private var selectedWeekdays: Set<VehicleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var isEnabled: Bool = true
    @State private var editingScheduleID: String? = nil
    /// Deleting a timer is remote and not undoable locally, so it is confirmed. It was the only
    /// destructive action in the app that fired on a single click.
    @State private var pendingDeletion: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let hours = Array(0...23)
    private let minutes = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]

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
                    existingSchedulesList
                    Divider().opacity(HisingenTheme.dividerOpacity)
                    scheduleConfigSection
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
        .frame(minHeight: 460, maxHeight: dynamicTypeSize.isAccessibilitySize ? 620 : 460)
        .background(HisingenTheme.canvas)
        .onAppear {
            if editingScheduleID == nil { selectedKind = initialKind }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.badge.checkmark.fill")
                .foregroundStyle(HisingenTheme.accent)
                .hisType(.title)
            Text(L10n.text("Manage Schedules"))
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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var existingSchedulesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Active Timers"))
                .hisType(.label, weight: .semibold)
                .foregroundStyle(.secondary)

            let allSchedules = state.energy.schedules
            if allSchedules.isEmpty {
                Text(L10n.text("No schedules configured."))
                    .hisType(.label)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    // Identified by the row itself, not its index. The list animates on
                    // `backendID`, so an index identity made a deletion animate content into the
                    // wrong slot: the row that vanished was the one whose position changed.
                    ForEach(allSchedules, id: \.rowIdentity) { sched in
                        scheduleRow(sched)
                            .transition(.opacity)
                    }
                }
                // Keyed on backend identities so a deleted timer reflows instead
                // of vanishing the moment the command lands.
                .hisAnimation(Motion.cardChange, value: allSchedules.map(\.backendID))
            }
        }
    }

    private func scheduleRow(_ sched: VehicleSchedule) -> some View {
        let isEditable = sched.backendID != nil
        return HStack(spacing: 8) {
            Image(systemName: sched.kind == .climate ? "fan.fill" : "bolt.fill")
                .foregroundStyle(sched.kind == .climate ? HisingenTheme.semanticWarning : HisingenTheme.semanticGood)
                .hisType(.body)
            VStack(alignment: .leading, spacing: 1) {
                let timeStr = String(format: "%02d:%02d", sched.startHour ?? 0, sched.startMinute ?? 0)
                let endStr = sched.endHour.map { String(format: " - %02d:%02d", $0, sched.endMinute ?? 0) } ?? ""
                Text("\(sched.kind.title): \(timeStr)\(endStr)")
                    .hisType(.label, weight: .medium)
                if let oneShot = sched.oneShotDate {
                    // A dated row is a one-shot timer; weekday names would read it as weekly.
                    Text("\(L10n.text("Once on")) \(Format.dateFormatter.string(from: oneShot))")
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                } else if !sched.weekdays.isEmpty {
                    Text(sched.weekdays.map(\.shortName).joined(separator: ", "))
                        .hisType(.micro)
                        .foregroundStyle(.secondary)
                }
                if sched.syncNeedsAttention {
                    Label((sched.syncStatus ?? "").replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "clock.badge.exclamationmark")
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(HisingenTheme.semanticWarning)
                }
                if !isEditable {
                    Label(L10n.text("View only"), systemImage: "lock.fill")
                        .hisType(.micro, weight: .medium)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isEditable {
                Button {
                    beginEditing(sched)
                } label: {
                    Image(systemName: "pencil")
                        .hisType(.label)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
                .help(L10n.text("Edit this timer"))
                .accessibilityLabel(L10n.text("Edit this timer"))
            }
            if let id = sched.backendID {
                Button {
                    pendingDeletion = id
                } label: {
                    Image(systemName: "trash")
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.semanticCritical.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(isBusy)
                .help(L10n.text("Delete climate timer"))
                .accessibilityLabel(L10n.text("Delete climate timer"))
                .confirmationDialog(
                    L10n.text("Delete climate timer"),
                    isPresented: Binding(
                        get: { pendingDeletion == id },
                        set: { if !$0 { pendingDeletion = nil } }
                    ),
                    titleVisibility: .visible
                ) {
                    Button(L10n.text("Delete"), role: .destructive) {
                        onRemoteCommand(.deleteClimateTimer(id: id))
                        if editingScheduleID == id { resetToAddMode() }
                        pendingDeletion = nil
                    }
                    Button(L10n.text("Cancel"), role: .cancel) { pendingDeletion = nil }
                }
            }
        }
        .padding(8)
        .background(
            editingScheduleID == sched.backendID && isEditable
                ? HisingenTheme.accent.opacity(0.12)
                : Color.primary.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(editingScheduleID == sched.backendID && isEditable ? HisingenTheme.accent.opacity(0.4) : .clear, lineWidth: 1)
        )
        .hisAnimation(Motion.selection, value: editingScheduleID)
        .contentShape(Rectangle())
        .onTapGesture { if isEditable { beginEditing(sched) } }
        .accessibilityAddTraits(isEditable ? [.isButton] : [])
        .accessibilityHint(isEditable
                           ? L10n.text("Opens this timer for editing")
                           : L10n.text("This timer is reported by the vehicle and cannot be edited here"))
    }

    /// Loads an existing timer's values into the form and switches it into edit mode. Saving
    /// afterward reuses `sched.backendID` so the backend updates this timer in place instead of
    /// creating a new one – `saveSchedule()` already passes `editingScheduleID` through as
    /// `backendID` for exactly this reason; only entering edit mode was previously missing.
    private func beginEditing(_ sched: VehicleSchedule) {
        editingScheduleID = sched.backendID
        selectedKind = sched.kind
        startHour = sched.startHour ?? 7
        startMinute = sched.startMinute ?? 30
        endHour = sched.endHour ?? 6
        endMinute = sched.endMinute ?? 0
        selectedWeekdays = Set(sched.weekdays)
        isEnabled = sched.isActive
    }

    private func resetToAddMode() {
        editingScheduleID = nil
        selectedKind = .climate
        startHour = 7
        startMinute = 30
        endHour = 6
        endMinute = 0
        selectedWeekdays = [.monday, .tuesday, .wednesday, .thursday, .friday]
        isEnabled = true
    }

    private var scheduleConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(editingScheduleID != nil ? L10n.text("Edit Schedule") : L10n.text("Add Schedule"))
                    .hisType(.label, weight: .semibold)
                    .foregroundStyle(.secondary)
                if editingScheduleID != nil {
                    HStack {
                        Spacer()
                        Button(L10n.text("Cancel Edit")) {
                            resetToAddMode()
                        }
                        .buttonStyle(.pressable)
                        .hisType(.caption, weight: .medium)
                        .foregroundStyle(HisingenTheme.accent)
                    }
                    .transition(.opacity)
                }
            }

            Picker("", selection: $selectedKind) {
                Text(L10n.text("Cabin Preconditioning")).tag(ScheduleKind.climate)
                Text(L10n.text("Charging Window")).tag(ScheduleKind.globalCharging)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedKind == .climate ? L10n.text("Departure Time") : L10n.text("Start Time"))
                        .hisType(.caption, weight: .medium)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Picker("", selection: $startHour) {
                            ForEach(hours, id: \.self) { h in Text(String(format: "%02d", h)).tag(h) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                        Text(":")
                        Picker("", selection: $startMinute) {
                            ForEach(minutes, id: \.self) { m in Text(String(format: "%02d", m)).tag(m) }
                        }
                        .labelsHidden()
                        .controlSize(.small)
                    }
                }

                if selectedKind == .globalCharging {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("End Time"))
                            .hisType(.caption, weight: .medium)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Picker("", selection: $endHour) {
                                ForEach(hours, id: \.self) { h in Text(String(format: "%02d", h)).tag(h) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            Text(":")
                            Picker("", selection: $endMinute) {
                                ForEach(minutes, id: \.self) { m in Text(String(format: "%02d", m)).tag(m) }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                        }
                    }
                    .transition(.opacity)
                }
            }

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
                                .background(selected ? HisingenTheme.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(selected ? HisingenTheme.accentOn : Color.primary)
                                .animation(reduceMotion ? nil : Motion.selection, value: selected)
                        }
                        .buttonStyle(.pressable)
                        .accessibilityLabel(day.shortName)
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button(L10n.text("Save Schedule")) {
                saveSchedule()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .foregroundStyle(HisingenTheme.accentOn)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(chargingWindowInvalid || isBusy)
            .help(isBusy ? L10n.text("Another remote command is still running.") : "")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func saveSchedule() {
        let schedule = VehicleSchedule(
            backendID: editingScheduleID,
            index: nil,
            kind: selectedKind,
            startHour: startHour,
            startMinute: startMinute,
            endHour: selectedKind == .globalCharging ? endHour : nil,
            endMinute: selectedKind == .globalCharging ? endMinute : nil,
            weekdays: Array(selectedWeekdays),
            isActive: isEnabled
        )

        if selectedKind == .climate {
            onRemoteCommand(.setClimateTimer(schedule))
        } else {
            onRemoteCommand(.setGlobalChargeTimer(schedule))
        }
    }
}
