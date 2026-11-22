import SwiftUI

/// The home charger's section: what the charger itself reports, next to what the
/// car reports, with the plan Home Assistant is running and the two actions that matter.
///
/// Design read: a spec-sheet section for a desk instrument, flat and square on the panel, ink for
/// state and one live amber only while energy moves; Energy 2 / Rhythm 3 / Motion 2 as in DESIGN.md.
/// Reasons: the vehicle line is muted because it is context, the session line is the figure because
/// wall power and delivered energy are what a reader checks while charging, and the notice is the
/// only element that takes a colour, because it is the only one that asks for attention.
@MainActor
struct HomeChargerSection: View {
    let state: VehicleState
    @ObservedObject var model: HomeChargingModel
    var showsScheduleActions = true
    var onOpenPlan: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsPlanEditor = false
    @State private var showsNexBlueTimer = false

    var body: some View {
        if let input = model.cardInput(for: state) {
            let card = HomeChargingCardModel.make(input)
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    CardHeader(symbol: "powerplug", title: card.title, color: HisingenTheme.liveSignal,
                               isPulsing: card.tone == .charging)
                    content(card, input: input)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hisAnimation(Motion.stateChange, value: card.tone)
                .accessibilityElement(children: .contain)
            }
            .sheet(isPresented: $showsPlanEditor) {
                HomeChargingPlanSheet(state: state, model: model)
            }
            .sheet(isPresented: $showsNexBlueTimer) {
                NexBlueTimerSheet(model: model)
            }
        }
    }

    @ViewBuilder
    private func content(_ card: HomeChargingCardModel, input: HomeChargingCardInput) -> some View {
        Text(card.vehicleLine)
            .hisType(.body)
            .foregroundStyle(HisingenTheme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .hisTelemetryValue(card.vehicleLine, reduceMotion: reduceMotion)

        if let session = card.sessionLine {
            Text(session)
                .hisType(card.sessionIsLive ? .title : .body, weight: card.sessionIsLive ? .semibold : .regular)
                .monospacedDigit()
                .foregroundStyle(card.sessionIsLive ? HisingenTheme.ink : HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .hisTelemetryValue(session, reduceMotion: reduceMotion)
        }
        if let phases = card.phaseLine {
            Text(phases)
                .hisType(.label)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
                .hisTelemetryValue(phases, reduceMotion: reduceMotion)
        }
        HouseMeterLines(meter: model.houseMeter, tibber: model.tibberLive, carKw: currentCarKw(input))
        if let plan = card.planLine {
            Text(plan)
                .hisType(.label)
                .foregroundStyle(HisingenTheme.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let cost = card.costLine {
            Text(cost)
                .hisType(.label)
                .monospacedDigit()
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        if let notice = card.notice {
            noticeView(notice, command: input.command)
        }
        if let freshness = card.freshnessLine {
            Text(freshness)
                .hisType(.micro)
                .foregroundStyle(HisingenTheme.inkMuted)
        }
        if let limitRow = currentLimitRow(input) {
            limitRow
        }
        // The buttons that act on the charger stay where the reader is, with or without a link to
        // Plan. Editing the plan is a place to go, so it is a row, not another command box.
        let commands = card.actions.filter { $0.kind != .editPlan }
        if !commands.isEmpty {
            HStack(spacing: 8) {
                ForEach(commands) { action in actionButton(action) }
            }
            .padding(.top, 2)
        }
        if showsScheduleActions, card.actions.contains(where: { $0.kind == .editPlan }) {
            NavigationRow(title: L10n.text("Edit plan")) { showsPlanEditor = true }
        }
        if let onOpenPlan {
            NavigationRow(
                title: L10n.text("Open in Plan"),
                accessibilityName: "\(L10n.text("Open in Plan")), \(card.title)",
                action: onOpenPlan
            )
        }
        if showsScheduleActions, input.pairing.source == .nexBlue, input.pairing.canControlSchedule {
            Button(L10n.text("Cheapest overnight charge")) { showsNexBlueTimer = true }
                .buttonStyle(.hisSecondary)
                .disabled(input.link != .live)
        }
        if !card.details.isEmpty {
            DisclosureGroup(L10n.text("Charger Details")) {
                VStack(spacing: 6) {
                    ForEach(card.details) { detail in
                        KVRow(detail.label, detail.value, symbol: "exclamationmark.triangle",
                              warning: detail.needsAttention, info: detail.info)
                    }
                }
                .padding(.top, 6)
            }
            .disclosureGroupStyle(WholeRowDisclosureStyle())
            .hisType(.body, weight: .medium)
        }
    }

    /// Sets the charger's current ceiling through Home Assistant. Shown only when a writable
    /// `number` entity is mapped: every other charger control here needs one, and offering a
    /// stepper that cannot send would repeat the bug this app spent a release fixing.
    @ViewBuilder
    private func currentLimitRow(_ input: HomeChargingCardInput) -> (some View)? {
        if input.pairing.entities.currentLimitNumber != nil {
            let reported = input.telemetry.currentLimitAmps.flatMap { $0.value > 0 ? Int($0.value.rounded()) : nil }
            HomeChargerCurrentLimitRow(
                initialAmps: reported ?? model.currentLimitRange.lowerBound,
                range: model.currentLimitRange,
                apply: { amps in await model.setChargerCurrentLimit(amps) }
            )
        }
    }

    /// The charger's wall power, only while the reading is current: a stale figure would be
    /// subtracted from a live house reading and give a wrong "rest of the house".
    private func currentCarKw(_ input: HomeChargingCardInput) -> Double? {
        input.telemetry.isFresh(input.telemetry.powerKw, now: input.now) ? input.telemetry.powerKw?.value : nil
    }

    private func noticeView(_ notice: HomeChargingCardModel.Notice, command: HomeChargerCommandTracker.Phase) -> some View {
        let tint: Color = {
            switch notice.level {
            case .info: return HisingenTheme.semanticActive
            case .warning: return HisingenTheme.semanticWarning
            case .error: return HisingenTheme.semanticCritical
            }
        }()
        let dismissable: Bool = {
            switch command {
            case .rejected, .unconfirmed: return true
            default: return false
            }
        }()
        return HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.text)
                    .hisType(.body, weight: .medium)
                    .foregroundStyle(HisingenTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = notice.detail {
                    Text(detail)
                        .hisType(.label)
                        .foregroundStyle(HisingenTheme.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if dismissable {
                DismissButton { model.dismissCommandResult() }
            }
        }
        .padding(9)
        .hisNotice(tint)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButton(_ action: HomeChargingCardModel.Action) -> some View {
        let label = action.pendingTitle ?? action.title
        // The style sits directly on the button: the nearest one wins, so the lead action cannot
        // be restyled from outside.
        if action.isProminent {
            Button { perform(action.kind) } label: { Text(label).frame(maxWidth: .infinity, minHeight: 28) }
                .buttonStyle(.hisProminent)
                .disabled(!action.isEnabled)
                .accessibilityLabel(label)
        } else {
            Button { perform(action.kind) } label: { Text(label).frame(maxWidth: .infinity, minHeight: 28) }
                .buttonStyle(.hisSecondary)
                .disabled(!action.isEnabled)
                .accessibilityLabel(label)
        }
    }

    private func perform(_ kind: HomeChargingCardModel.Action.Kind) {
        // The card shows one charger; a second pairing must be commanded on its own reading, not
        // through whichever charger happens to hold the live connection.
        let identity = model.cardInput(for: state)?.pairing.identity
        switch kind {
        case .chargeNow:
            if let identity { Task { await model.send(.start, for: identity) } }
        case .pause:
            if let identity { Task { await model.send(.pause, for: identity) } }
        case .resume:
            if let identity { model.selectCharger(identity: identity) }
            Task { try? await model.resumePlan() }
        case .editPlan:
            if let identity { model.selectCharger(identity: identity) }
            showsPlanEditor = true
        }
    }
}


/// The catalogued Home charger card, so it is placed, ordered and hidden like any other card.
///
/// It draws only for a signed-in, paired charger that belongs on this car (`shouldShow`), so on an
/// install without one it leaves no gap.
@MainActor
struct HomeChargerCard: View {
    let state: VehicleState
    /// Where the schedule actions live. A card that links to Plan leaves them there.
    var onOpenPlan: (() -> Void)? = nil

    @Environment(\.homeCharging) private var homeCharging

    var body: some View {
        if let homeCharging {
            HomeChargerSection(
                state: state, model: homeCharging,
                showsScheduleActions: onOpenPlan == nil, onOpenPlan: onOpenPlan
            )
        }
    }
}


/// A stepper plus Apply for the charger's current ceiling. It reports its own failure text instead
/// of pretending the write landed, because the reading comes back on the next poll and a silent
/// failure would look like "the charger ignored me".
@MainActor
private struct HomeChargerCurrentLimitRow: View {
    let initialAmps: Int
    let range: ClosedRange<Int>
    let apply: (Int) async -> String?

    @State private var amps: Int
    @State private var isSending = false
    @State private var failure: String?

    init(initialAmps: Int, range: ClosedRange<Int>, apply: @escaping (Int) async -> String?) {
        self.initialAmps = initialAmps
        self.range = range
        self.apply = apply
        _amps = State(initialValue: min(max(initialAmps, range.lowerBound), range.upperBound))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(L10n.text("Current limit"))
                    .hisType(.label, weight: .medium)
                    .foregroundStyle(HisingenTheme.inkMuted)
                Spacer()
                Stepper(value: $amps, in: range) {
                    Text(L10n.format("%d A", amps))
                        .hisType(.label, weight: .medium)
                        .monospacedDigit()
                }
                .fixedSize()
                Button(L10n.text("Apply")) {
                    isSending = true
                    failure = nil
                    Task {
                        failure = await apply(amps)
                        isSending = false
                    }
                }
                .buttonStyle(.hisSecondary)
                .disabled(isSending)
            }
            if let failure {
                Text(failure)
                    .hisType(.micro)
                    .foregroundStyle(HisingenTheme.semanticCritical)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
