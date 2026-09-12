import SwiftUI

@MainActor
struct AccessControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    CardHeader(symbol: "lock.fill", title: L10n.text("Locks & Security"), color: .blue)
                    Spacer()
                    if let isLocked = state.exteriorStatus?.isLocked {
                        Pill(
                            text: isLocked ? L10n.text("Locked") : L10n.text("Unlocked"),
                            color: isLocked ? HisingenTheme.semanticGood : HisingenTheme.semanticWarning,
                            symbol: isLocked ? "lock.fill" : "lock.open.fill"
                        )
                    }
                }
                gate.dimReason(gate.cardAvailability([.lock, .unlock]))

                HStack(spacing: 8) {
                    let isLocked = state.exteriorStatus?.isLocked == true

                    if profile.permits(.locks) && features.contains(.remoteLocks) {
                        Button {
                            gate.send(isLocked ? .unlock : .lock)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: isLocked ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 18))
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                Text(isLocked ? L10n.text("Unlock") : L10n.text("Lock"))
                                    .font(.system(size: 12, weight: .semibold))
                                gate.sendingOverlay(isLocked ? .unlock : .lock)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .tint(isLocked ? .blue : .green)
                        .disabled(gate.isDisabled(isLocked ? .unlock : .lock))
                    }

                    if state.model.brand == .volvo,
                       !isLocked,
                       profile.permits(.reducedGuardLock),
                       features.contains(.remoteLocks) {
                        Button {
                            gate.send(.lockReducedGuard)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill").font(.system(size: 16))
                                Text(L10n.text("Reduced Guard")).font(.system(size: 11, weight: .medium))
                                gate.sendingOverlay(.lockReducedGuard)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .disabled(gate.isDisabled(.lockReducedGuard))
                        .help(L10n.text("Locks the vehicle with reduced alarm guard sensitivity, when supported."))
                    }

                    if features.contains(.remoteLocks) {
                        let capabilities = state.otaCapabilities
                        let showTrunkUnlock = profile.permits(.trunk)
                            && (capabilities?.supportsTrunkUnlock ?? profile.permits(.trunk))
                        let showTailgateControl = capabilities?.supportsTrunkControl ?? false

                        if showTrunkUnlock {
                            Button {
                                gate.send(.unlockTrunk)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: "car.side.rear.open.fill").font(.system(size: 15))
                                    Text(L10n.text("Unlock Trunk")).font(.system(size: 11, weight: .medium))
                                    gate.sendingOverlay(.unlockTrunk)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .disabled(gate.isDisabled(.unlockTrunk))
                        }

                        if showTailgateControl {
                            let tailgateIsOpen = state.exteriorStatus?.isTailgateOpen ?? false
                            Button {
                                gate.send(tailgateIsOpen ? .closeTailgate : .openTailgate)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tailgateIsOpen
                                          ? "car.side.rear.open.fill" : "car.side.rear.fill")
                                        .font(.system(size: 15))
                                    Text(tailgateIsOpen
                                         ? L10n.text("Close Tailgate") : L10n.text("Open Tailgate"))
                                        .font(.system(size: 11, weight: .medium))
                                    gate.sendingOverlay(tailgateIsOpen ? .closeTailgate : .openTailgate)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .tint(tailgateIsOpen ? .orange : nil)
                            .disabled(gate.isDisabled(tailgateIsOpen ? .closeTailgate : .openTailgate))
                        }
                    }
                }
            }
        }
        .opacity(gate.cardOpacity([.lock, .unlock]))
    }
}
