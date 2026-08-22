import SwiftUI

@MainActor
struct ScheduleEditorSheet: View {
    let state: VehicleState
    let onRemoteCommand: (RemoteCommand) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var selectedKind: ScheduleKind = .climate
    @State private var startHour: Int = 7
    @State private var startMinute: Int = 30
    @State private var endHour: Int = 6
    @State private var endMinute: Int = 0
    @State private var selectedWeekdays: Set<VehicleWeekday> = [.monday, .tuesday, .wednesday, .thursday, .friday]
    @State private var isEnabled: Bool = true
    @State private var editingScheduleID: String? = nil

    private let hours = Array(0...23)
    private let minutes = [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    existingSchedulesList
                    Divider().opacity(0.4)
                    scheduleConfigSection
                }
                .padding(16)
            }

            Divider().opacity(0.4)
            footerButtons
        }
        .frame(width: 380, height: 460)
        .background(HisingenTheme.canvas)
    }

    private var header: some View {
        HStack {
            Image(systemName: "clock.badge.checkmark.fill")
                .foregroundStyle(HisingenTheme.accent)
                .font(.system(size: 15))
            Text(L10n.text("Manage Schedules"))
                .font(.system(size: 14, weight: .bold))
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var existingSchedulesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Active Timers"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            let allSchedules = state.chargingSchedules
            if allSchedules.isEmpty {
                Text(L10n.text("No schedules configured."))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(allSchedules.indices, id: \.self) { idx in
                        let sched = allSchedules[idx]
                        scheduleRow(sched)
                    }
                }
            }
        }
    }

    private func scheduleRow(_ sched: VehicleSchedule) -> some View {
        HStack(spacing: 8) {
            Image(systemName: sched.kind == .climate ? "fan.fill" : "bolt.fill")
                .foregroundStyle(sched.kind == .climate ? Color.orange : Color.green)
                .font(.system(size: 12))
            VStack(alignment: .leading, spacing: 1) {
                let timeStr = String(format: "%02d:%02d", sched.startHour ?? 0, sched.startMinute ?? 0)
                let endStr = sched.endHour.map { String(format: " - %02d:%02d", $0, sched.endMinute ?? 0) } ?? ""
                Text("\(sched.kind.title): \(timeStr)\(endStr)")
                    .font(.system(size: 11, weight: .medium))
                if !sched.weekdays.isEmpty {
                    Text(sched.weekdays.map(\.shortName).joined(separator: ", "))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let id = sched.backendID {
                Button {
                    onRemoteCommand(.deleteClimateTimer(id: id))
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(.red.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var scheduleConfigSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(editingScheduleID != nil ? L10n.text("Edit Schedule") : L10n.text("Add Schedule"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("", selection: $selectedKind) {
                Text(L10n.text("Cabin Preconditioning")).tag(ScheduleKind.climate)
                Text(L10n.text("Charging Window")).tag(ScheduleKind.globalCharging)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedKind == .climate ? L10n.text("Departure Time") : L10n.text("Start Time"))
                        .font(.system(size: 10, weight: .medium))
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
                            .font(.system(size: 10, weight: .medium))
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
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("Repeat Days"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    ForEach([VehicleWeekday.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday], id: \.self) { day in
                        let selected = selectedWeekdays.contains(day)
                        Button {
                            if selected { selectedWeekdays.remove(day) } else { selectedWeekdays.insert(day) }
                        } label: {
                            Text(day.shortName)
                                .font(.system(size: 9.5, weight: selected ? .bold : .regular))
                                .frame(maxWidth: .infinity, minHeight: 24)
                                .background(selected ? HisingenTheme.accent : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                .foregroundStyle(selected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Toggle(L10n.text("Enable this schedule"), isOn: $isEnabled)
                .font(.system(size: 11))
                .toggleStyle(.checkbox)
        }
    }

    private var footerButtons: some View {
        HStack {
            Button(L10n.text("Cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            Button(L10n.text("Save Schedule")) {
                saveSchedule()
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .controlSize(.small)
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
