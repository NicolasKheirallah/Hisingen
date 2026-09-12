import SwiftUI

@MainActor
struct EngineControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    @State private var engineRuntimeMinutes: Int = 15

    var body: some View {
        let startCommand = RemoteCommand.startEngine(runtimeMinutes: engineRuntimeMinutes)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(
                        symbol: "flame.fill",
                        title: L10n.text("Remote Engine Start (RES)"),
                        color: .orange
                    )
                    Spacer()
                    engineStatus
                }
                gate.dimReason(gate.cardAvailability([startCommand]))

                Text(L10n.text("Starts combustion engine to precondition cabin temperature before departure."))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.text("Runtime"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("", selection: $engineRuntimeMinutes) {
                        Text(L10n.format("%d min", 5)).tag(5)
                        Text(L10n.format("%d min", 10)).tag(10)
                        Text(L10n.format("%d min", 15)).tag(15)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 170)
                    .disabled(gate.isDisabled(startCommand) || state.fuelSystem.isEngineRunning == true)
                    .onChange(of: engineRuntimeMinutes) { _, newValue in
                        gate.preferences.remoteEngineRuntimeMinutes = newValue
                    }
                }

                HStack(spacing: 10) {
                    Button {
                        gate.send(startCommand)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "flame.fill")
                            Text(L10n.format("Start Engine (%d min)", engineRuntimeMinutes))
                                .font(.system(size: 11, weight: .medium))
                            gate.sendingOverlay(startCommand)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(gate.isDisabled(startCommand) || state.fuelSystem.isEngineRunning == true)

                    Button {
                        gate.send(.stopEngine)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                            Text(L10n.text("Stop Engine")).font(.system(size: 11, weight: .medium))
                            gate.sendingOverlay(.stopEngine)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(gate.isDisabled(.stopEngine) || state.fuelSystem.isEngineRunning != true)
                }
            }
        }
        .opacity(gate.cardOpacity([startCommand]))
        .onAppear {
            engineRuntimeMinutes = gate.preferences.remoteEngineRuntimeMinutes
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        if state.fuelSystem.isEngineRunning == true {
            HStack(spacing: 4) {
                Circle().fill(HisingenTheme.semanticGood).frame(width: 6, height: 6)
                Text(L10n.text("Engine Running"))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(HisingenTheme.semanticGood)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(HisingenTheme.semanticGood.opacity(0.12), in: Capsule())
        } else if state.fuelSystem.isEngineRunning == false {
            statusPill(L10n.text("Engine Stopped"))
        } else {
            statusPill(L10n.text("Status Unavailable"))
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
