import SwiftUI

/// The home charger's part of the charging card: what the charger itself reports, next to what the
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
        if !card.actions.isEmpty {
            HStack(spacing: 8) {
                ForEach(card.actions) { action in actionButton(action) }
            }
            .padding(.top, 2)
        }
        if input.pairing.source == .nexBlue {
            Button(L10n.text("Cheapest overnight charge")) { showsNexBlueTimer = true }
                .buttonStyle(.hisSecondary)
                .disabled(input.link != .live)
        }
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
                Button { model.dismissCommandResult() } label: {
                    Image(systemName: "xmark")
                        .hisType(.caption, weight: .semibold)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .foregroundStyle(HisingenTheme.inkMuted)
                .accessibilityLabel(L10n.text("Dismiss"))
                .help(L10n.text("Dismiss"))
            }
        }
        .padding(9)
        .hisNotice(tint)
        .accessibilityElement(children: .combine)
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
        switch kind {
        case .chargeNow: Task { await model.send(.start) }
        case .pause: Task { await model.send(.pause) }
        case .resume: Task { try? await model.resumePlan() }
        case .editPlan: showsPlanEditor = true
        }
    }
}
