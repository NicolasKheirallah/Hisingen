import AppKit
import SwiftUI

/// Saved sequences of commands, run against the selected vehicle. Each step goes through the same
/// dispatch as the cards above, so the gate and authorization apply to every step, not only the
/// start.
@MainActor
struct RoutinesCard: View {
    @Environment(\.preferencesStore) private var preferences
    let state: VehicleState
    let gate: ControlsCommandGate
    /// A routine waits for a running command to finish. Its first step would otherwise be refused.
    let isBusy: Bool

    @State private var routines: [CommandRoutine] = []
    @State private var showEditor = false
    @State private var editingRoutine: CommandRoutine?
    @State private var runningRoutineID: UUID?
    @State private var lastReport: CommandRoutineReport?

    /// Commands the vehicle supports right now. Busy is ignored, since a routine is started only
    /// when nothing else is running.
    private var stepChoices: [RemoteCommand] {
        CommandRoutine.stepChoices(engineRuntimeMinutes: preferences.remoteEngineRuntimeMinutes).filter { command in
            switch gate.availability(command, ignoreBusy: true) {
            case .available, .unavailableUntilRefresh: return true
            default: return false
            }
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L10n.text("Routines"))
                        .hisType(.heading, weight: .semibold)
                    Spacer()
                    Button(L10n.text("New Routine")) {
                        editingRoutine = nil
                        showEditor = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(stepChoices.isEmpty)
                }

                if routines.isEmpty {
                    Text(L10n.text("Save a sequence of commands to send in order, such as starting climate, setting a charge target and locking."))
                        .hisType(.label)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(routines) { routine in
                        routineRow(routine)
                    }
                }

                if let report = lastReport {
                    reportText(report)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .onAppear { routines = preferences.commandRoutines }
        .sheet(isPresented: $showEditor) {
            RoutineEditorSheet(
                initial: editingRoutine,
                choices: stepChoices,
                onSave: save,
                onDelete: delete
            )
        }
    }

    private func routineRow(_ routine: CommandRoutine) -> some View {
        let running = runningRoutineID == routine.id
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(routine.name)
                    .hisType(.label, weight: .semibold)
                Text(routine.steps.map(\.title).joined(separator: ", "))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button {
                editingRoutine = routine
                showEditor = true
            } label: {
                Image(systemName: "pencil")
                    .hisType(.label)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.text("Edit routine"))

            Button {
                run(routine)
            } label: {
                if running {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.text("Run"))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(minWidth: 44)
            .disabled(isBusy || runningRoutineID != nil)
            .help(isBusy ? L10n.text("Another remote command is still running.") : "")
        }
    }

    @ViewBuilder
    private func reportText(_ report: CommandRoutineReport) -> some View {
        switch report.outcome {
        case .declined:
            Text(L10n.format("%@ was not started.", report.routineName))
                .hisType(.caption)
                .foregroundStyle(.secondary)
        case .completed:
            Text(L10n.format("%@ finished. %d of %d steps sent.",
                             report.routineName, report.sentSteps.count, report.totalSteps))
                .hisType(.caption, weight: .medium)
                .foregroundStyle(HisingenTheme.semanticGood)
        case .stopped(let stepIndex, let reason):
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("%@ stopped at step %d of %d. %d steps were sent before it.",
                                 report.routineName, stepIndex + 1, report.totalSteps, report.sentSteps.count))
                    .hisType(.caption, weight: .medium)
                    .foregroundStyle(HisingenTheme.semanticWarning)
                Text(reason)
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func run(_ routine: CommandRoutine) {
        let vin = state.identity.vin
        runningRoutineID = routine.id
        lastReport = nil
        Task {
            let executor = CommandRoutineExecutor { command in
                guard let dispatcher = AutomationHandoff.context else {
                    return .refused(reason: RemoteCommandError.missingContext.localizedDescription)
                }
                return await dispatcher.perform(command, targetVIN: vin, origin: .userInitiated)
            }
            lastReport = await executor.run(routine, confirm: Self.confirmStart)
            runningRoutineID = nil
        }
    }

    /// Lists every step, not only the ones that need approval, so the reader sees the whole run
    /// before anything is sent. Each approval-requiring step still asks again on its own turn.
    private static func confirmStart(_ routine: CommandRoutine) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L10n.format("Run %@?", routine.name)
        let steps = routine.steps.enumerated()
            .map { "\($0.offset + 1). \($0.element.title)" }
            .joined(separator: "\n")
        alert.informativeText = L10n.text("These steps are sent to the vehicle in order:") + "\n"
            + steps + "\n\n"
            + L10n.text("A step that unlocks the car, opens windows or the tailgate, or starts the engine asks for approval when its turn comes.")
        alert.addButton(withTitle: L10n.text("Run Routine"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func save(_ routine: CommandRoutine) {
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        preferences.commandRoutines = routines
    }

    private func delete(_ routine: CommandRoutine) {
        routines.removeAll { $0.id == routine.id }
        preferences.commandRoutines = routines
    }
}

/// Name and ordered steps for one routine. Steps are picked from what the vehicle supports, and
/// reordered with the buttons beside each row.
@MainActor
struct RoutineEditorSheet: View {
    let initial: CommandRoutine?
    let choices: [RemoteCommand]
    let onSave: (CommandRoutine) -> Void
    let onDelete: (CommandRoutine) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var steps: [RemoteCommand]

    init(initial: CommandRoutine?, choices: [RemoteCommand],
         onSave: @escaping (CommandRoutine) -> Void,
         onDelete: @escaping (CommandRoutine) -> Void) {
        self.initial = initial
        self.choices = choices
        self.onSave = onSave
        self.onDelete = onDelete
        _name = State(initialValue: initial?.name ?? "")
        _steps = State(initialValue: initial?.steps ?? [])
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !steps.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(HisingenTheme.dividerOpacity)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Name"))
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(.secondary)
                        TextField(L10n.text("Leave work"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.text("Steps"))
                            .hisType(.label, weight: .semibold)
                            .foregroundStyle(.secondary)
                        if steps.isEmpty {
                            Text(L10n.text("No steps yet. Add a step to send it in order."))
                                .hisType(.label)
                                .foregroundStyle(.tertiary)
                        } else {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                stepRow(index: index, step: step)
                            }
                        }
                        addStepMenu
                    }
                }
                .padding(16)
            }

            Divider().opacity(HisingenTheme.dividerOpacity)
            footerButtons
        }
        .frame(width: 380)
        .frame(minHeight: 420, maxHeight: 520)
        .background(HisingenTheme.canvas)
    }

    private var header: some View {
        HStack {
            Image(systemName: "list.number")
                .foregroundStyle(HisingenTheme.accent)
                .hisType(.title)
            Text(initial == nil ? L10n.text("New Routine") : L10n.text("Edit Routine"))
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

    private func stepRow(index: Int, step: RemoteCommand) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1).")
                .hisType(.label, weight: .semibold)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .leading)
            Text(step.title)
                .hisType(.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button {
                steps.swapAt(index, index - 1)
            } label: {
                Image(systemName: "chevron.up").hisType(.label)
            }
            .buttonStyle(.pressable)
            .disabled(index == 0)
            .accessibilityLabel(L10n.text("Move step up"))

            Button {
                steps.swapAt(index, index + 1)
            } label: {
                Image(systemName: "chevron.down").hisType(.label)
            }
            .buttonStyle(.pressable)
            .disabled(index == steps.count - 1)
            .accessibilityLabel(L10n.text("Move step down"))

            Button {
                steps.remove(at: index)
            } label: {
                Image(systemName: "minus.circle").hisType(.label)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.text("Remove step"))
        }
    }

    private var addStepMenu: some View {
        Menu {
            ForEach(choices, id: \.identifier) { choice in
                Button(choice.title) { steps.append(choice) }
            }
        } label: {
            Label(L10n.text("Add Step"), systemImage: "plus")
                .hisType(.label, weight: .medium)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(choices.isEmpty)
    }

    private var footerButtons: some View {
        HStack {
            if let initial {
                Button(L10n.text("Delete Routine"), role: .destructive) {
                    onDelete(initial)
                    dismiss()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            Spacer()
            Button(L10n.text("Cancel")) {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)

            Button(L10n.text("Save Routine")) {
                onSave(CommandRoutine(id: initial?.id ?? UUID(), name: trimmedName, steps: steps))
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .tint(HisingenTheme.accent)
            .foregroundStyle(HisingenTheme.accentOn)
            .controlSize(.small)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
