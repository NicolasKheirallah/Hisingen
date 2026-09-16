import SwiftUI

@MainActor
struct EngineControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    @State private var engineRuntimeMinutes: Int = 15
    /// Drives the "running" status-dot breath (opacity 1.0 ↔ 0.55), CardHeader-style.
    @State private var liveDotPulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let startCommand = RemoteCommand.startEngine(runtimeMinutes: engineRuntimeMinutes)
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardHeader(
                        symbol: "flame.fill",
                        title: L10n.text("Remote Engine Start (RES)"),
                        color: HisingenTheme.semanticWarning
                    )
                    Spacer()
                    engineStatus
                        .hisAnimation(Motion.stateChange, value: state.fuelSystem.isEngineRunning)
                }
                gate.dimReason(gate.liveAvailability([startCommand]))

                Text(L10n.text("Starts combustion engine to precondition cabin temperature before departure."))
                    .hisType(.label)
                    .foregroundStyle(.secondary)

                HStack {
                    Text(L10n.text("Runtime"))
                        .hisType(.label, weight: .medium)
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
                    .disabled(gate.isDisabled(startCommand) || state.fuelSystem.isEngineRunning != false)
                    // The pill above says "Status Unavailable" while this stays armed. Starting is
                    // the safe direction so it stays available, but it says what it does not know
                    // rather than looking as certain as the pill is honest.
                    .help(state.fuelSystem.isEngineRunning == nil
                          ? L10n.text("The vehicle has not reported whether the engine is running.")
                          : L10n.text("Starts the engine."))
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
                                .hisType(.label, weight: .medium)
                            gate.sendingOverlay(startCommand)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(HisingenTheme.semanticWarning)
                    .disabled(gate.isDisabled(startCommand) || state.fuelSystem.isEngineRunning != false)

                    Button {
                        gate.send(.stopEngine)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "stop.fill")
                            Text(L10n.text("Stop Engine")).hisType(.label, weight: .medium)
                            gate.sendingOverlay(.stopEngine)
                        }
                        .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.bordered)
                    .disabled(gate.isDisabled(.stopEngine) || state.fuelSystem.isEngineRunning != true)
                }
            }
        }
        .opacity(gate.liveOpacity([startCommand]))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability([startCommand]))
        .onAppear {
            engineRuntimeMinutes = gate.preferences.remoteEngineRuntimeMinutes
        }
    }

    @ViewBuilder
    private var engineStatus: some View {
        if state.fuelSystem.isEngineRunning == true {
            HStack(spacing: 4) {
                Circle()
                    .fill(HisingenTheme.semanticGood)
                    .frame(width: 6, height: 6)
                    .opacity(liveDotPulse ? 0.55 : 1.0)
                    .animation(Motion.resolve(Motion.livePulse), value: liveDotPulse)
                    .onAppear {
                        if !reduceMotion { liveDotPulse = true }
                    }
                Text(L10n.text("Engine Running"))
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(HisingenTheme.semanticGood)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(HisingenTheme.semanticGood.opacity(0.12), in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
        } else if state.fuelSystem.isEngineRunning == false {
            statusPill(L10n.text("Engine Stopped"))
        } else {
            statusPill(L10n.text("Status Unavailable"))
        }
    }

    private func statusPill(_ text: String) -> some View {
        Text(text)
            .hisType(.caption, weight: .medium)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
