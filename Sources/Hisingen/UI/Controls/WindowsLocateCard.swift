import SwiftUI

@MainActor
struct WindowsLocateCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    private let locateCommands: [RemoteCommand] = [.flashLights, .honkAndFlash, .honkHorn]

    private var showWindows: Bool {
        state.capabilityProfile.permits(.windows) && gate.features.contains(.remoteWindows)
    }

    private var showLocate: Bool {
        state.capabilityProfile.permits(.honkAndFlash)
            && gate.features.contains(.remoteHonkFlash)
            && locateCommands.contains(where: permits)
    }

    var body: some View {
        if showWindows || showLocate {
            let title = showWindows && showLocate
                ? L10n.text("Windows & Locate Vehicle")
                : (showWindows ? L10n.text("Windows Control") : L10n.text("Locate Vehicle"))
            Card(compact: true) {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeaderWithAccessory(
                        heading: CardHeader(symbol: "rectangle.arrowtriangle.2.outward", title: title, color: HisingenTheme.chartInfo)
                    ) {
                        if showWindows { windowStatus }
                    }
                    let commands: [RemoteCommand] = (showWindows ? [.closeWindows, .openWindows] : [])
                        + (showLocate ? locateCommands.filter(permits) : [])
                    gate.dimReason(gate.liveAvailability(commands))

                    if showWindows && showLocate {
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 24) {
                                windowActions
                                    .fixedSize(horizontal: true, vertical: false)
                                locateActions
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            VStack(spacing: 12) {
                                windowActions
                                PanelRule()
                                locateActions
                            }
                        }
                    } else if showWindows {
                        windowActions
                    } else {
                        locateActions
                    }
                }
            }
        }
    }

    private func permits(_ command: RemoteCommand) -> Bool {
        state.otaCapabilities?.honkFlashMode?.permits(command) ?? true
    }

    private var windowActions: some View {
        VehicleCommandRow {
            VehicleCommandButton(
                title: L10n.text("Close Windows"), symbol: "rectangle.arrowtriangle.2.inward",
                command: .closeWindows, gate: gate
            )
            VehicleCommandButton(
                title: L10n.text("Vent Windows"), symbol: "rectangle.arrowtriangle.2.outward",
                command: .openWindows, gate: gate
            )
        }
    }

    private var locateActions: some View {
        VehicleCommandRow {
            if permits(.flashLights) {
                VehicleCommandButton(
                    title: L10n.text("Flash Lights"), symbol: "headlight.high.beam",
                    command: .flashLights, gate: gate
                )
            }
            if permits(.honkAndFlash) {
                VehicleCommandButton(
                    title: L10n.text("Honk & Flash"), symbol: "light.beacon.max",
                    command: .honkAndFlash, gate: gate
                )
            }
            if permits(.honkHorn) {
                VehicleCommandButton(
                    title: L10n.text("Honk Horn"), symbol: "speaker.wave.2",
                    command: .honkHorn, gate: gate
                )
            }
        }
    }

    private var windowStatus: some View {
        let states = state.exteriorStatus?.windowStates ?? []
        let open = states.count { $0 == .open || $0 == .ajar }
        let allReported = states.count == VehicleOpening.sideWindows.count && !states.contains(.unknown)
        let text: String
        let symbol: String
        let color: Color
        if open > 0 {
            text = allReported && open < states.count
                ? L10n.format("%1$d of %2$d windows open", open, states.count)
                : L10n.text("Windows Open")
            symbol = "rectangle.arrowtriangle.2.outward"
            color = HisingenTheme.semanticWarning
        } else if allReported {
            text = L10n.text("Windows Closed")
            symbol = "rectangle.arrowtriangle.2.inward"
            color = HisingenTheme.ink
        } else {
            text = L10n.text("Window State Not Reported")
            symbol = "questionmark.circle"
            color = HisingenTheme.inkMuted
        }
        return Label(text, systemImage: symbol)
            .hisType(.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
