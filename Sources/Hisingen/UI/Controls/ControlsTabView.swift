import SwiftUI

@MainActor
struct ControlsTabView: View {
    let state: VehicleState
    /// The live session's brand – the gate authority shared with command dispatch.
    let brand: VehicleBrand
    let remoteCommandInProgress: Bool
    var inFlightCommandID: String? = nil
    var feedback: RemoteCommandFeedback? = nil
    var imageCache: CarImageCache = .shared
    let onRemoteCommand: (RemoteCommand) -> Void
    var onRefresh: () -> Void = {}
    /// Receipts for commands that are still awaiting confirmation, timed out, or were confirmed.
    ///
    /// The Vehicle tab has always shown these; the Controls tab did not, so the tab that issues
    /// the commands was the one place their outcome never appeared. Its only feedback was a
    /// green "Command sent" banner that auto-dismisses after six seconds, which is a statement
    /// about the request, not about the car.
    var onDismissCommandReceipt: (UUID) -> Void = { _ in }
    /// Runs the remote-command authorization step when a refused command's banner offers it.
    var onAuthorizeRemoteCommands: (() -> Void)? = nil

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    @Environment(\.preferencesStore) private var preferences
    @State private var showScheduleEditor = false
    @State private var scheduleEditorKind: ScheduleKind = .climate
    @State private var scheduleToEdit: VehicleSchedule?

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { preferences.features.enabled }
    private var isBrandVolvo: Bool { brand == .volvo }

    private var commandGate: ControlsCommandGate {
        ControlsCommandGate(
            state: state,
            brand: brand,
            preferences: preferences,
            remoteCommandInProgress: remoteCommandInProgress,
            inFlightCommandID: inFlightCommandID,
            onRemoteCommand: onRemoteCommand
        )
    }

    private struct CardEntry {
        /// Which catalogued card this is, so the reader's layout can switch it off.
        let item: TabItemID
        let isVisible: Bool
        let view: () -> AnyView
    }

    static let renderedItems: [TabItemID] = [
        .controlsBanners, .controlsReceipts, .controlsCharging, .controlsChargingPlanner,
        .controlsClimate, .controlsEngine, .controlsRoutines
    ]

    private var hasAnyVisibleChargingControls: Bool {
        guard state.powertrain.hasElectricRange else { return false }
        return (profile.permits(.chargeTarget) && features.contains(.remoteCharging))
            || (profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging))
            || (profile.permits(.chargingScheduleOverride)
                && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)))
            || (profile.permits(.chargeLocations) && features.contains(.remoteCharging)
                && features.contains(.chargeLocations))
            || (profile.permits(.chargingSchedule)
                && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)))
    }

    private var cards: [CardEntry] {
        let gate = commandGate
        return [
            CardEntry(
                item: .controlsClimate,
                isVisible: features.contains(.remoteClimate)
                    || (features.contains(.remotePreCleaning) && profile.permits(.preCleaning)),
                view: {
                    AnyView(ClimateControlCard(
                        state: state,
                        gate: gate,
                        onShowSchedule: showScheduleEditor(for:),
                        settingsOnly: true
                    ))
                }
            ),
            CardEntry(
                item: .controlsEngine,
                isVisible: state.powertrain.hasCombustionEngine && isBrandVolvo && engineStartPermitted,
                view: { AnyView(EngineControlsCard(state: state, gate: gate)) }
            ),
            CardEntry(
                item: .controlsCharging,
                isVisible: hasAnyVisibleChargingControls,
                view: {
                    AnyView(ChargingControlsCard(
                        state: state,
                        gate: gate,
                        onShowSchedule: showScheduleEditor(for:)
                    ))
                }
            ),
            CardEntry(
                item: .controlsChargingPlanner,
                // Same gating the Vehicle tab applies: the planner needs the feature switch
                // and a car that can act on it.
                isVisible: preferences.smartChargingPlannerAvailable && state.powertrain.hasElectricRange
                    && state.energy.batteryPercentage != nil && state.energy.targetPercentage != nil,
                view: { AnyView(ChargingPlannerCard(state: state)) }
            ),
            CardEntry(
                item: .controlsRoutines,
                // A routine is a sequence of remote commands. With every remote feature off there
                // is nothing to put in one, so the empty-controls hint is the useful card.
                isVisible: !features.isDisjoint(with: AppFeature.remoteFeatures),
                view: {
                    AnyView(RoutinesCard(state: state, gate: gate, isBusy: remoteCommandInProgress))
                }
            )
        ]
    }

    private var visibleCards: [CardEntry] {
        cards.filter { $0.isVisible && draws($0.item) }
    }

    static func orderedCardItems(layout: TabLayout, controls: Set<TabItemID>, hasReceipts: Bool) -> [TabItemID] {
        let items = renderedItems.filter { item in
            layout.draws(item) && (item == .controlsReceipts ? hasReceipts : controls.contains(item))
        }
        return layout.ordered(items, by: { $0 })
    }

    @ViewBuilder
    private func planCard(_ item: TabItemID, controls: [CardEntry]) -> some View {
        if item == .controlsReceipts {
            ForEach(Array(state.commandState.receipts.reversed()), id: \.id) { receipt in
                CommandReceiptChip(receipt: receipt, onDismiss: onDismissCommandReceipt,
                                   onVerify: { _ in onRefresh() })
            }
        } else if let entry = controls.first(where: { $0.item == item }) {
            entry.view()
        }
    }

    private var engineStartPermitted: Bool {
        profile.hasEngineStart || profile.permits(.engineStart)
    }

    var body: some View {
        let controls = visibleCards
        let items = Self.orderedCardItems(
            layout: layout, controls: Set(controls.map(\.item)), hasReceipts: !state.commandState.receipts.isEmpty
        )
        let receiptsLead = items.first == .controlsReceipts
        VStack(spacing: HisingenTheme.sectionSpacing) {
            if draws(.controlsBanners) {
                ControlsBanners(
                    state: state,
                    feedback: feedback,
                    features: features,
                    isBrandVolvo: isBrandVolvo,
                    showRestrictedNotice: !controls.isEmpty,
                    onAuthorizeRemoteCommands: onAuthorizeRemoteCommands,
                    onFollowUp: onRemoteCommand
                )
            }

            if receiptsLead {
                planCard(.controlsReceipts, controls: controls)
            }

            // When: the departure, the next 24 hours, then every timer.
            VStack(alignment: .leading, spacing: 20) {
                if state.powertrain.hasElectricRange {
                    PlanDeparture(state: state)
                }
                PlanDayTimeline(state: state)
                PlanTimeline(state: state, canEdit: canEdit, onEdit: editSchedule,
                             onAdd: canAddSchedule ? { showScheduleEditor(for: .climate) } : nil)
            }
            .padding(.horizontal, HisingenTheme.cardPadding)
            .padding(.top, 4)

            ForEach(items.dropFirst(receiptsLead ? 1 : 0), id: \.self) { item in
                planCard(item, controls: controls)
            }
            if !controls.isEmpty {
                if anyCardDimmed || state.probedCapabilities == nil {
                    ControlsReprobeButton(onRefresh: onRefresh)
                }
                RemoteControlsFootnote(features: features, isBrandVolvo: isBrandVolvo)
                    .padding(.horizontal, HisingenTheme.cardPadding)
            } else {
                noControlsEnabledCard
            }
        }
        .hisAnimation(Motion.cardChange, value: items)
        .hisAnimation(Motion.cardChange, value: anyCardDimmed)
        .hisAnimation(Motion.cardChange, value: state.probedCapabilities == nil)
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorSheet(
                state: state,
                initialKind: scheduleEditorKind,
                initialSchedule: scheduleToEdit,
                onRemoteCommand: onRemoteCommand,
                isBusy: remoteCommandInProgress
            )
        }
    }

    private var canAddSchedule: Bool {
        features.contains(.remoteSchedules)
            && (profile.permits(.climateTimers) || profile.permits(.chargingSchedule))
    }

    private func showScheduleEditor(for kind: ScheduleKind) {
        scheduleToEdit = nil
        scheduleEditorKind = kind
        showScheduleEditor = true
    }

    private func canEdit(_ schedule: VehicleSchedule) -> Bool {
        switch schedule.kind {
        case .climate:
            guard schedule.backendID != nil, schedule.oneShotDate == nil else { return false }
            return commandGate.availability(.setClimateTimer(schedule), ignoreBusy: true).isAvailable
        case .globalCharging:
            return commandGate.availability(.setGlobalChargeTimer(schedule), ignoreBusy: true).isAvailable
        case .locationCharging, .departure:
            return false
        }
    }

    private func editSchedule(_ schedule: VehicleSchedule) {
        scheduleToEdit = schedule
        scheduleEditorKind = schedule.kind
        showScheduleEditor = true
    }

    /// Whether any visible card is restricted by the vehicle or by settings, which is the
    /// condition a re-probe could change. This asks the capability question on purpose: a card
    /// dimmed because a command is in flight is not a reason to offer a re-probe.
    private var anyCardDimmed: Bool {
        let gate = commandGate
        return visibleCards.contains { entry in
            // Keyed on the catalogued tab item, not the entry's string id: a rename in
            // TabItemID used to silently strand a case on `default` and hide the re-probe.
            switch entry.item {
            case .controlsClimate:
                return gate.capabilityAvailability([ClimateControlCard.probe, .startPreCleaning]) != .available
            case .controlsEngine:
                return gate.capabilityAvailability([
                    .startEngine(runtimeMinutes: preferences.remoteEngineRuntimeMinutes)
                ]) != .available
            case .controlsCharging:
                return gate.capabilityAvailability([.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]) != .available
            default:
                return false
            }
        }
    }

    private var noControlsEnabledCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("No Remote Controls Enabled"))
                    .hisType(.heading, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
                Text(L10n.text("Enable remote controls in Settings → Features."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if state.probedCapabilities == nil {
                    ControlsReprobeButton(onRefresh: onRefresh)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
