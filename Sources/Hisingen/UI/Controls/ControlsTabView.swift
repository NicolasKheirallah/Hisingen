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
    var initialSection: TabItemID? = nil
    var initialChargeLocationID: String? = nil
    var onNavigateToSettings: ((SettingsDestination) -> Void)? = nil
    var onNavigateToHistory: (() -> Void)? = nil
    var onSettingsChanged: ((SettingsChange) -> Void)? = nil
    var fleet = FleetSnapshot()

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    @Environment(\.preferencesStore) private var preferences
    @Environment(\.homeCharging) private var homeCharging
    @State private var preferencesRevision = 0
    @State private var selectedChargeLocationID: String?
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
        .controlsBanners, .controlsCharging, .vehicleHomeCharger, .vehicleReceipts, .controlsChargingPlanner,
        .controlsClimate, .controlsEngine, .controlsRoutines
    ]

    private var hasAnyVisibleChargingControls: Bool {
        guard state.powertrain.hasElectricRange else { return false }
        return (profile.permits(.chargeTarget) && features.contains(.remoteCharging))
            || (profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging))
            || (profile.permits(.chargingScheduleOverride)
                && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)))
            || (features.contains(.chargeLocations) &&
                (!state.savedChargeLocations.isEmpty
                 || (profile.permits(.chargeLocations) && features.contains(.remoteCharging))))
            || (profile.permits(.chargingSchedule)
                && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)))
    }

    private var canShowHomeCharger: Bool {
        homeCharging?.shouldShow(for: state) == true
    }

    private var automationAvailable: Bool {
        canSetPlannerAutoStart || canSetCalendarPreconditioning
            || !features.isDisjoint(with: AppFeature.remoteFeatures)
    }

    private var canSetPlannerAutoStart: Bool {
        preferences.smartChargingPlannerAvailable || preferences.plannerAutoStartEnabled
    }

    private var canSetCalendarPreconditioning: Bool {
        features.contains(.remoteClimate) || preferences.calendarPreconditioningEnabled
    }

    private var preferenceBinder: PreferenceBinder {
        PreferenceBinder(preferences: preferences,
                         notify: { onSettingsChanged?($0) },
                         bump: { preferencesRevision &+= 1 })
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
                        state: state, gate: gate,
                        selectedLocationID: selectedChargeLocationID ?? initialChargeLocationID
                    ))
                }
            ),
            CardEntry(
                item: .vehicleHomeCharger,
                isVisible: canShowHomeCharger,
                view: { AnyView(HomeChargerCard(state: state)) }
            ),
            CardEntry(
                item: .controlsChargingPlanner,
                isVisible: ChargingPlannerCard.isAvailable(state: state, preferences: preferences),
                view: { AnyView(planner) }
            ),
            CardEntry(
                item: .controlsRoutines,
                isVisible: automationAvailable,
                view: { AnyView(automation) }
            )
        ]
    }

    private var visibleCards: [CardEntry] {
        cards.filter { $0.isVisible && draws($0.item) }
    }

    static func orderedCardItems(layout: TabLayout, controls: Set<TabItemID>, hasReceipts: Bool) -> [TabItemID] {
        let items = renderedItems.filter { item in
            layout.draws(item) && (item == .vehicleReceipts ? hasReceipts : controls.contains(item))
        }
        return layout.ordered(items, by: { $0 })
    }

    @ViewBuilder
    private func planCard(_ item: TabItemID, controls: [CardEntry]) -> some View {
        if item == .vehicleReceipts {
            CommandReceiptsView(state: state, onDismiss: onDismissCommandReceipt,
                                onVerify: { _ in onRefresh() })
        } else if let entry = controls.first(where: { $0.item == item }) {
            entry.view()
        }
    }

    private var engineStartPermitted: Bool {
        profile.hasEngineStart || profile.permits(.engineStart)
    }

    var body: some View {
        let _ = preferencesRevision
        let controls = visibleCards
        let items = Self.orderedCardItems(
            layout: layout, controls: Set(controls.map(\.item)), hasReceipts: !state.commandState.receipts.isEmpty
        )
        let receiptsLead = !layout.includesNewItems && items.first == .vehicleReceipts
        return ScrollViewReader { proxy in
            planContent(controls: controls, items: items, receiptsLead: receiptsLead)
                .onChange(of: initialSection, initial: true) { _, section in
                    guard let section else { return }
                    Task { @MainActor in
                        await Task.yield()
                        if section == .controlsCharging, let initialChargeLocationID {
                            proxy.scrollTo(ChargingControlsCard.locationAnchor(initialChargeLocationID), anchor: .top)
                        } else {
                            proxy.scrollTo(section, anchor: .top)
                        }
                    }
                }
        }
    }

    private func planContent(controls: [CardEntry], items: [TabItemID], receiptsLead: Bool) -> some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            if layout.includesNewItems { scheduleOverview }

            if draws(.controlsBanners) {
                ControlsBanners(
                    state: state,
                    feedback: feedback,
                    features: features,
                    isBrandVolvo: isBrandVolvo,
                    showRestrictedNotice: !controls.isEmpty,
                    showsCommandReceipts: draws(.vehicleReceipts),
                    onAuthorizeRemoteCommands: onAuthorizeRemoteCommands,
                    onFollowUp: onRemoteCommand
                )
            }

            if receiptsLead {
                planCard(.vehicleReceipts, controls: controls)
            }

            if !layout.includesNewItems { scheduleOverview }

            ForEach(items.dropFirst(receiptsLead ? 1 : 0), id: \.self) { item in
                planCard(item, controls: controls)
                    .id(item)
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
            scheduleEditor
        }
    }

    private var scheduleOverview: some View {
        VStack(alignment: .leading, spacing: 20) {
            if state.powertrain.hasElectricRange {
                PlanDeparture(state: state)
            }
            PlanDayTimeline(state: state)
            PlanTimeline(
                state: state, canEdit: canEdit, onEdit: editSchedule,
                onAdd: addScheduleAction, canDelete: canDelete, onDelete: deleteSchedule,
                onOpenLocation: chargeLocationAction, homeCharging: homeCharging,
                offersHomePlan: features.contains(.smartChargingPlanner)
            )
        }
        .id(TabItemID.vehicleReadiness)
        .padding(.horizontal, HisingenTheme.cardPadding)
        .padding(.top, 4)
    }

    private var scheduleEditor: ScheduleEditorSheet {
        let gate = commandGate
        return ScheduleEditorSheet(
            state: state,
            initialKind: scheduleEditorKind,
            initialSchedule: scheduleToEdit,
            onRemoteCommand: { gate.send($0) },
            isBusy: remoteCommandInProgress,
            availableKinds: scheduleKinds,
            availability: { gate.availability($0) }
        )
    }

    private var addScheduleAction: (() -> Void)? {
        guard let kind = scheduleKinds.first else { return nil }
        return { showScheduleEditor(for: kind) }
    }

    private var chargeLocationAction: ((String) -> Void)? {
        guard draws(.controlsCharging), features.contains(.chargeLocations),
              hasAnyVisibleChargingControls else { return nil }
        return { reveal($0) }
    }

    private var scheduleKinds: [ScheduleKind] {
        let climate = VehicleSchedule(kind: .climate, startHour: 7, startMinute: 30,
                                      endHour: nil, endMinute: nil, weekdays: [.monday],
                                      isActive: true)
        let charging = VehicleSchedule(kind: .globalCharging, startHour: 0, startMinute: 0,
                                        endHour: 6, endMinute: 0, isActive: true)
        return [(ScheduleKind.climate, RemoteCommand.setClimateTimer(climate)),
                (.globalCharging, .setGlobalChargeTimer(charging))].compactMap { kind, command in
            commandGate.availability(command, ignoreBusy: true).isAvailable ? kind : nil
        }
    }

    private var planner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ChargingPlannerCard(state: state, showsHomePlan: false)
            if let onNavigateToSettings {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { plannerLinks(navigate: onNavigateToSettings) }
                    VStack(alignment: .leading, spacing: 6) { plannerLinks(navigate: onNavigateToSettings) }
                }
                .buttonStyle(.hisSecondary)
                .controlSize(.small)
                .padding(.horizontal, HisingenTheme.cardPadding)
            }
        }
    }

    @ViewBuilder
    private func plannerLinks(navigate: @escaping (SettingsDestination) -> Void) -> some View {
        Button(L10n.text("Planner Settings")) { navigate(.plannerSettings) }
        Button(L10n.text("Charging Alerts")) { navigate(.plannerAlerts) }
    }

    private var automation: some View {
        VStack(alignment: .leading, spacing: HisingenTheme.sectionSpacing) {
            Text(L10n.text("Automation"))
                .hisType(.displaySmall)
                .accessibilityAddTraits(.isHeader)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HisingenTheme.cardPadding)
            if onSettingsChanged != nil {
                if canSetCalendarPreconditioning {
                    CalendarPreconditioningSettingsCard(binder: preferenceBinder, fleet: fleet)
                }
                if canSetPlannerAutoStart {
                    Card {
                        PlannerAutoStartControl(binder: preferenceBinder)
                    }
                }
            }
            if !features.isDisjoint(with: AppFeature.remoteFeatures) {
                RoutinesCard(state: state, gate: commandGate, isBusy: remoteCommandInProgress)
            }
            if let onNavigateToHistory {
                NavigationRow(title: L10n.text("Open in Log"), action: onNavigateToHistory)
                    .padding(.horizontal, HisingenTheme.cardPadding)
            }
        }
    }

    @Environment(\.scrollRevealAction) private var revealSection

    private func reveal(_ location: String) {
        selectedChargeLocationID = location
        Task { @MainActor in
            await Task.yield()
            revealSection(ChargingControlsCard.locationAnchor(location))
        }
    }

    private func canDelete(_ schedule: VehicleSchedule) -> Bool {
        guard schedule.kind == .climate, let id = schedule.backendID else { return false }
        return commandGate.availability(.deleteClimateTimer(id: id)).isAvailable
    }

    private func deleteSchedule(_ schedule: VehicleSchedule) {
        guard schedule.kind == .climate, let id = schedule.backendID else { return }
        commandGate.send(.deleteClimateTimer(id: id))
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
