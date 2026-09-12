import SwiftUI

@MainActor
struct ControlsTabView: View {
    let state: VehicleState
    let remoteCommandInProgress: Bool
    var inFlightCommandID: String? = nil
    var feedback: RemoteCommandFeedback? = nil
    let onRemoteCommand: (RemoteCommand) -> Void
    var onRefresh: () -> Void = {}

    @Environment(\.preferencesStore) private var preferences
    @State private var showScheduleEditor = false
    @State private var scheduleEditorKind: ScheduleKind = .climate

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { preferences.features.enabled }
    private var isBrandVolvo: Bool { preferences.activeBrand == .volvo }

    private var commandGate: ControlsCommandGate {
        ControlsCommandGate(
            state: state,
            preferences: preferences,
            remoteCommandInProgress: remoteCommandInProgress,
            inFlightCommandID: inFlightCommandID,
            onRemoteCommand: onRemoteCommand
        )
    }

    private struct CardEntry: Identifiable {
        let id: String
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
                id: "climate",
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
                id: "engine",
                isVisible: state.powertrain.hasCombustionEngine && isBrandVolvo && engineStartPermitted,
                view: { AnyView(EngineControlsCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: "charging",
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
                id: "access",
                isVisible: features.contains(.remoteLocks),
                view: { AnyView(AccessControlsCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: "windows-locate",
                isVisible: (features.contains(.remoteWindows) && profile.permits(.windows))
                    || features.contains(.remoteHonkFlash),
                view: { AnyView(WindowsLocateCard(state: state, gate: gate)) }
            ),
            CardEntry(
                id: "ota",
                isVisible: features.contains(.remoteOTA) && profile.permits(.softwareInstallControl),
                view: { AnyView(OTAControlsCard(state: state, gate: gate)) }
            )
        ]
    }

    private var visibleCards: [CardEntry] { cards.filter(\.isVisible) }

    private var engineStartPermitted: Bool {
        profile.hasEngineStart || profile.permits(.engineStart)
    }

    var body: some View {
        VStack(spacing: HisingenTheme.sectionSpacing) {
            ControlsBanners(
                state: state,
                feedback: feedback,
                features: features,
                isBrandVolvo: isBrandVolvo,
                showRestrictedNotice: !visibleCards.isEmpty
            )

            if !visibleCards.isEmpty {
                ForEach(visibleCards) { entry in entry.view() }
                if anyCardDimmed || state.probedCapabilities == nil {
                    ControlsReprobeButton(onRefresh: onRefresh)
                }
            } else {
                noControlsEnabledCard
            }
        }
        .sheet(isPresented: $showScheduleEditor) {
            ScheduleEditorSheet(
                state: state,
                initialKind: scheduleEditorKind,
                onRemoteCommand: onRemoteCommand
            )
        }
    }

    private func showScheduleEditor(for kind: ScheduleKind) {
        scheduleEditorKind = kind
        showScheduleEditor = true
    }

    private var anyCardDimmed: Bool {
        let gate = commandGate
        return visibleCards.contains { entry in
            switch entry.id {
            case "climate":
                return gate.cardOpacity([ClimateControlCard.probe, .startPreCleaning]) < 1
            case "engine":
                return gate.cardOpacity([
                    .startEngine(runtimeMinutes: preferences.remoteEngineRuntimeMinutes)
                ]) < 1
            case "charging":
                return gate.cardOpacity([.setChargeTarget(80), .setAmpLimit(16), .startChargingOverride]) < 1
            case "access":
                return gate.cardOpacity([.lock, .unlock]) < 1
            case "windows-locate":
                return gate.cardOpacity([.closeWindows, .honkAndFlash, .flashLights]) < 1
            case "ota":
                return gate.cardOpacity([.installOTANow]) < 1
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
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.text("Enable remote controls in Settings under Telemetry & Features to display controls here."))
                    .font(.system(size: 11))
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
