import SwiftUI

@MainActor
struct ChargerScheduleRows: View {
    let state: VehicleState
    @ObservedObject var model: HomeChargingModel
    let offersHomePlan: Bool

    @State private var showsHomePlan = false
    @State private var showsNexBlueTimer = false
    @State private var nexBlueSchedule: NexBlueSchedule?
    @State private var nexBlueReadError = false
    @State private var scheduleRevision = 0

    private var pairedCharger: HomeChargingPairing? {
        guard let pairing = model.pairing, pairing.isPaired(toVehicle: state.identity.vin) else { return nil }
        return pairing
    }

    private var canReadNexBlueSchedule: Bool {
        guard let pairedCharger else { return false }
        return pairedCharger.source == .nexBlue && pairedCharger.canControlSchedule
    }

    private var nexBlueReadKey: String {
        "\(pairedCharger?.chargerID ?? "")|\(canReadNexBlueSchedule)|\(model.link)|\(scheduleRevision)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pairedCharger, pairedCharger.source.supportsPlans {
                let plan = model.planStatus.flatMap { $0.phase.isTerminal ? nil : $0 }
                if offersHomePlan || plan != nil {
                    PanelRule()
                    scheduleSourceRow(
                        title: L10n.text("Home charging plan"),
                        source: "Home Assistant",
                        detail: plan.flatMap { planTime($0, timeZone: pairedCharger.timeZone) },
                        actionTitle: plan == nil ? L10n.text("Set Plan") : L10n.text("Edit Plan")
                    ) { showsHomePlan = true }
                }
            }
            if canReadNexBlueSchedule {
                PanelRule()
                scheduleSourceRow(
                    title: L10n.text("Charger Schedule"),
                    source: "NexBlue",
                    detail: nexBlueStatus,
                    actionTitle: L10n.text("Cheapest overnight charge"),
                    actionDisabled: model.link != .live
                ) { showsNexBlueTimer = true }
                if let schedule = nexBlueSchedule {
                    ForEach(schedule.items.indices, id: \.self) { index in
                        let timer = schedule.items[index]
                        PanelRule()
                        KVRow(
                            L10n.format("Timer %d", index + 1),
                            L10n.format("%@ · %@",
                                       timeRange(timer),
                                       timer.enabled ? L10n.text("On") : L10n.text("Off"))
                        )
                        .padding(.vertical, 3)
                    }
                }
            }
        }
        .task(id: nexBlueReadKey) { await readNexBlueSchedule() }
        .sheet(isPresented: $showsHomePlan) {
            HomeChargingPlanSheet(state: state, model: model)
        }
        .sheet(isPresented: $showsNexBlueTimer, onDismiss: { scheduleRevision &+= 1 }) {
            NexBlueTimerSheet(model: model)
        }
    }

    private var nexBlueStatus: String {
        if model.link != .live { return L10n.text("Charger is offline") }
        if nexBlueReadError { return L10n.text("The charger schedule could not be read.") }
        guard let schedule = nexBlueSchedule else { return L10n.text("Reading charger schedule…") }
        if schedule.items.isEmpty { return L10n.text("No schedules configured.") }
        return schedule.timeZone.identifier
    }

    private func scheduleSourceRow(
        title: String, source: String, detail: String?, actionTitle: String,
        actionDisabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sourceLabel(title, source: source, detail: detail)
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                sourceButton(actionTitle, disabled: actionDisabled, action: action)
            }
            VStack(alignment: .leading, spacing: 6) {
                sourceLabel(title, source: source, detail: detail)
                sourceButton(actionTitle, disabled: actionDisabled, action: action)
            }
        }
        .padding(.vertical, 10)
    }

    private func sourceLabel(_ title: String, source: String, detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).hisType(.subhead)
            Text(detail.map { L10n.format("%@ · %@", source, $0) } ?? source)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func sourceButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.hisSecondary)
            .controlSize(.small)
            .disabled(disabled)
    }

    private func planTime(_ plan: HomeChargingPlanStatus, timeZone: TimeZone) -> String? {
        if plan.isHeld { return L10n.text("On hold") }
        guard let date = plan.windows.first(where: { $0.end > Date() })?.start ?? plan.expectedFinish else {
            return nil
        }
        return HomeChargingTime.dateTime(date, in: timeZone)
    }

    private func timeRange(_ timer: NexBlueScheduleItem) -> String {
        let start = Format.clockTime(hour: timer.startHour, minute: timer.startMinute)
        let stop = Format.clockTime(hour: timer.stopHour, minute: timer.stopMinute)
        return L10n.format("%@–%@", start, stop)
    }

    private func readNexBlueSchedule() async {
        nexBlueSchedule = nil
        nexBlueReadError = false
        guard canReadNexBlueSchedule, model.link == .live else { return }
        do {
            let schedule = try await model.readNexBlueSchedule()
            guard !Task.isCancelled else { return }
            nexBlueSchedule = schedule
        } catch {
            guard !Task.isCancelled else { return }
            nexBlueReadError = true
        }
    }
}
