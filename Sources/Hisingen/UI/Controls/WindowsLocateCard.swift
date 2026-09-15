import SwiftUI

@MainActor
struct WindowsLocateCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }

    /// What the vehicle reports about the windows, resolved for display.
    private struct WindowStatus {
        let text: String
        let color: Color
        let symbol: String
    }

    var body: some View {
        let showWindows = profile.permits(.windows) && features.contains(.remoteWindows)
        let showLocate = profile.permits(.honkAndFlash) && features.contains(.remoteHonkFlash)
        let mode = state.otaCapabilities?.honkFlashMode
        let headerTitle = showWindows && showLocate
            ? L10n.text("Windows & Locate Vehicle")
            : (showWindows ? L10n.text("Windows Control") : L10n.text("Locate Vehicle"))
        let headerSymbol = showWindows ? "rectangle.arrowtriangle.2.outward" : "flashlight.on.fill"

        // A header with nothing under it renders when no permitted sub-command is left, which
        // happens for a vehicle whose honk/flash mode allows none of the three.
        let anyLocateControl = showLocate && [
            mode?.permits(.flashLights) ?? true,
            mode?.permits(.honkAndFlash) ?? true,
            mode?.permits(.honkHorn) ?? true
        ].contains(true)
        let hasControls = showWindows || anyLocateControl
        if hasControls {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: headerSymbol, title: headerTitle, color: .indigo)
                    Spacer()
                    if showWindows {
                        windowStatusPill
                    }
                }
                gate.dimReason(gate.liveAvailability([.closeWindows, .honkAndFlash, .flashLights]))

                HStack(spacing: 8) {
                    if showWindows {
                        windowButton(
                            command: .closeWindows,
                            symbol: "rectangle.arrowtriangle.2.inward",
                            title: L10n.text("Close Windows")
                        )
                        windowButton(
                            command: .openWindows,
                            symbol: "rectangle.arrowtriangle.2.outward",
                            title: L10n.text("Vent Windows")
                        )
                    }

                    if showLocate {
                        if mode?.permits(.flashLights) ?? true {
                            windowButton(
                                command: .flashLights,
                                symbol: "flashlight.on.fill",
                                title: L10n.text("Flash Lights")
                            )
                        }
                        if mode?.permits(.honkAndFlash) ?? true {
                            windowButton(
                                command: .honkAndFlash,
                                symbol: "light.beacon.max.fill",
                                title: L10n.text("Honk & Flash")
                            )
                        }
                        if mode?.permits(.honkHorn) ?? true {
                            windowButton(
                                command: .honkHorn,
                                symbol: "speaker.wave.2.fill",
                                title: L10n.text("Honk Horn")
                            )
                        }
                    }
                }
            }
            // Keyed on every condition that adds/removes a button so the row
            // reflows when feature flags or honk/flash permissions change.
            .hisAnimation(Motion.cardChange, value: [
                showWindows,
                showLocate,
                mode?.permits(.flashLights) ?? true,
                mode?.permits(.honkAndFlash) ?? true,
                mode?.permits(.honkHorn) ?? true
            ])
        }
        .opacity(gate.liveOpacity([.closeWindows, .honkAndFlash, .flashLights]))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability([.closeWindows, .honkAndFlash, .flashLights]))
        }
    }

    /// The window state as a pill, or nothing when the vehicle has reported no window position.
    @ViewBuilder
    private var windowStatusPill: some View {
        if let status = windowStatus {
            Pill(text: status.text, color: status.color, symbol: status.symbol)
        }
    }

    /// What the vehicle reports about the windows, or nil when it has reported none of them.
    ///
    /// "Vent Windows" and "Close Windows" are physical actions the user cannot verify from the
    /// card, and every neighbouring card states its subject's state (Locked/Unlocked, Engine
    /// Running, climate active), so this was an inconsistency rather than a house style. The
    /// reading is the same one `CapabilityGate` uses to prove the command landed.
    private var windowStatus: WindowStatus? {
        let states = state.exteriorStatus?.windowStates ?? []
        guard !states.isEmpty else { return nil }
        let open = states.filter { $0 == .open || $0 == .ajar }.count
        if open == 0 {
            return WindowStatus(
                text: L10n.text("Windows Closed"),
                color: HisingenTheme.semanticGood,
                symbol: "rectangle.arrowtriangle.2.inward"
            )
        }
        if open == states.count {
            return WindowStatus(
                text: L10n.text("Windows Open"),
                color: HisingenTheme.semanticWarning,
                symbol: "rectangle.arrowtriangle.2.outward"
            )
        }
        return WindowStatus(
            text: L10n.format("%1$d of %2$d windows open", open, states.count),
            color: HisingenTheme.semanticWarning,
            symbol: "rectangle.arrowtriangle.2.outward"
        )
    }

    private func windowButton(command: RemoteCommand, symbol: String, title: String) -> some View {
        Button {
            gate.send(command)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).hisType(.heading)
                Text(title).hisType(.caption, weight: .medium)
                gate.sendingOverlay(command)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .disabled(gate.isDisabled(command))
        .transition(.opacity)
    }
}
