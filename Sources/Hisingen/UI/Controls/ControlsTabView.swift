import SwiftUI

@MainActor
struct ControlsTabView: View {
    let state: VehicleState
    /// The live session's brand – the gate authority shared with command dispatch.
    let brand: VehicleBrand
    let remoteCommandInProgress: Bool
    var inFlightCommandID: String? = nil
    var feedback: RemoteCommandFeedback? = nil
    let onRemoteCommand: (RemoteCommand) -> Void
    var onRefresh: () -> Void = {}
    /// Receipts for commands that are still awaiting confirmation, timed out, or were confirmed.
    ///
    /// The Vehicle tab has always shown these; the Controls tab did not, so the tab that issues
    /// the commands was the one place their outcome never appeared. Its only feedback was a
    /// green "Command sent" banner that auto-dismisses after six seconds, which is a statement
    /// about the request, not about the car.
    var onDismissCommandReceipt: (UUID) -> Void = { _ in }

    /// The reader's layout for this tab: what to draw, and in what order. The default draws
    /// everything exactly as designed.
    var layout: TabLayout = .everything

    func draws(_ item: TabItemID) -> Bool { layout.draws(item) }

    func ordered<T>(_ entries: [T], by item: (T) -> TabItemID) -> [T] {
        layout.ordered(entries, by: item)
    }

    @Environment(\.preferencesStore) private var preferences
    @State private var showScheduleEditor = false
    @State private var scheduleEditorKind: ScheduleKind = .climate

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

    private struct CardEntry: Identifiable {
        let id: String
        /// Which catalogued card this is, so the reader's layout can switch it off.
        let item: TabItemID
        let isVisible: Bool
        let view: () -> AnyView
    }

    private var hasAnyVisibleChargingControls: Bool {
        guard state.powertrain.hasElectricRange else { return false }
        return (profile.permits(.chargeTarget) && features.contains(.remoteCharging))
            || (profile.permits(.chargingCurrentLimit) && features.contains(.remoteCharging))
            || (profile.permits(.chargingScheduleOverride)
                && (features.contains(.remoteCharging) || features.contains(.remoteSchedules)))
            || (profile.permits(.chargeLocations) && features.contains(.remoteCharging))
            || (profile.permits(.chargingSchedule)
                && (features.contains(.remoteSchedules) || features.contains(.remoteCharging)))
    }

    private var cards: [CardEntry] {
        let gate = commandGate
        return [
            CardEntry(
                id: TabItemID.controlsClimate.rawValue, item: TabItemID.controlsClimate,
                isVisible: features.contains(.remoteClimate)
                    || (features.contains(.remotePreCleaning) && profile.permits(.preCleaning)),
                view: {
                    AnyView(ClimateControlCard(
                        state: state,
                        gate: gate,
                        onShowSchedule: showScheduleEditor(for:)
                    ))
                }
            ),
            CardEntry(
                id: TabItemID.controlsEngine.rawValue, item: TabItemID.controlsEngine,
                isVisible: state.powertrain.hasCombustionEngine && isBrandVolvo && engineStartPermitted,
                view: { AnyView(EngineControlsCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: TabItemID.controlsCharging.rawValue, item: TabItemID.controlsCharging,
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
                id: TabItemID.controlsAccess.rawValue, item: TabItemID.controlsAccess,
                isVisible: features.contains(.remoteLocks),
                view: { AnyView(AccessControlsCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: TabItemID.controlsWindowsLocate.rawValue, item: TabItemID.controlsWindowsLocate,
                isVisible: (features.contains(.remoteWindows) && profile.permits(.windows))
                    || features.contains(.remoteHonkFlash),
                view: { AnyView(WindowsLocateCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: TabItemID.controlsOTA.rawValue, item: TabItemID.controlsOTA,
                isVisible: features.contains(.remoteOTA) && profile.permits(.softwareInstallControl),
                view: { AnyView(OTAControlsCard(state: state, gate: gate, onRefresh: onRefresh)) }
            )
        ]
    }

    private var visibleCards: [CardEntry] {
        ordered(cards.filter { $0.isVisible && draws($0.item) }, by: { $0.item })
    }

    private var engineStartPermitted: Bool {
        profile.hasEngineStart || profile.permits(.engineStart)
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            if draws(.controlsBanners) {
                ControlsBanners(
                state: state,
                feedback: feedback,
                features: features,
                isBrandVolvo: isBrandVolvo,
                showRestrictedNotice: !visibleCards.isEmpty
                )
            }

            if draws(.controlsReceipts) {
                ForEach(Array(state.commandState.receipts.reversed()), id: \.id) { receipt in
                    CommandReceiptChip(receipt: receipt, onDismiss: onDismissCommandReceipt)
                }
            }

            if !visibleCards.isEmpty {
                ForEach(visibleCards) { entry in entry.view() }
                if anyCardDimmed || state.probedCapabilities == nil {
                    ControlsReprobeButton(onRefresh: onRefresh)
                }
            } else {
                noControlsEnabledCard
            }
        }
        // CardEntry is Identifiable, so feature-flag flips animate insertion,
        // removal and reorder of the stack instead of rebuilding it in place.
        .hisAnimation(Motion.cardChange, value: visibleCards.map(\.id))
        .hisAnimation(Motion.cardChange, value: anyCardDimmed)
        .hisAnimation(Motion.cardChange, value: state.probedCapabilities == nil)
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorSheet(
                state: state,
                initialKind: scheduleEditorKind,
                onRemoteCommand: onRemoteCommand,
                isBusy: remoteCommandInProgress
            )
        }
    }

    private func showScheduleEditor(for kind: ScheduleKind) {
        scheduleEditorKind = kind
        showScheduleEditor = true
    }

    /// Whether any visible card is restricted by the vehicle or by settings, which is the
    /// condition a re-probe could change. This asks the capability question on purpose: a card
    /// dimmed because a command is in flight is not a reason to offer a re-probe.
    private var anyCardDimmed: Bool {
        let gate = commandGate
        return visibleCards.contains { entry in
            switch entry.id {
            case "climate":
                return gate.capabilityAvailability([ClimateControlCard.probe, .startPreCleaning]) != .available
            case "engine":
                return gate.capabilityAvailability([
                    .startEngine(runtimeMinutes: preferences.remoteEngineRuntimeMinutes)
                ]) != .available
            case "charging":
                return gate.capabilityAvailability([.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]) != .available
            case "access":
                return gate.capabilityAvailability([.lock, .unlock]) != .available
            case "windows-locate":
                return gate.capabilityAvailability([.closeWindows, .honkAndFlash, .flashLights]) != .available
            case "ota":
                return gate.capabilityAvailability([.installOTANow]) != .available
            default:
                return false
            }
        }
    }

    private var noControlsEnabledCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "switch.2")
                    .font(.system(size: 24))
                    .foregroundStyle(.secondary)
                Text(L10n.text("No Remote Controls Enabled"))
                    .hisType(.heading, weight: .semibold)
                Text(L10n.text("Enable remote controls in Settings under Telemetry & Features to display controls here."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if state.probedCapabilities == nil {
                    ControlsReprobeButton(onRefresh: onRefresh)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }
    }
}
