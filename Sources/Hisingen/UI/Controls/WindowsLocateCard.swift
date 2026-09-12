import SwiftUI

@MainActor
struct WindowsLocateCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }

    var body: some View {
        let showWindows = profile.permits(.windows) && features.contains(.remoteWindows)
        let showLocate = profile.permits(.honkAndFlash) && features.contains(.remoteHonkFlash)
        let headerTitle = showWindows && showLocate
            ? L10n.text("Windows & Locate Vehicle")
            : (showWindows ? L10n.text("Windows Control") : L10n.text("Locate Vehicle"))
        let headerSymbol = showWindows ? "rectangle.arrowtriangle.2.outward" : "flashlight.on.fill"

        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: headerSymbol, title: headerTitle, color: .indigo)
                gate.dimReason(gate.cardAvailability([.closeWindows, .honkAndFlash, .flashLights]))

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
                        let mode = state.otaCapabilities?.honkFlashMode
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
        }
        .opacity(gate.cardOpacity([.closeWindows, .honkAndFlash, .flashLights]))
    }

    private func windowButton(command: RemoteCommand, symbol: String, title: String) -> some View {
        Button {
            gate.send(command)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13))
                Text(title).font(.system(size: 10, weight: .medium))
                gate.sendingOverlay(command)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.bordered)
        .disabled(gate.isDisabled(command))
    }
}
