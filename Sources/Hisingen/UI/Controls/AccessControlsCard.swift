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
                    } else {
                        // Silently omitting the state was itself the problem: the card then showed
                        // a definite "Lock" button with nothing to say the vehicle had never
                        // reported a state. The engine card in this same area already states
                        // "Status Unavailable" rather than nothing.
                        Pill(
                            text: L10n.text("Lock State Not Reported"),
                            color: HisingenTheme.semanticWarning,
                            symbol: "questionmark.circle.fill"
                        )
                    }
                }
                gate.dimReason(gate.liveAvailability([.lock, .unlock]))

                // Three states, not two. `nil` used to collapse to `false`, which chose the action,
                // the label, the icon and the tint from a reading the vehicle had not sent. The
                // button still offers Lock, because locking is the safe direction and refusing to
                // act on an unknown state would strand the user; what changes is that the control
                // no longer claims to know, and Reduced Guard waits for a reported state.
                let isLocked = state.exteriorStatus?.isLocked
                let lockCommand: RemoteCommand = isLocked == true ? .unlock : .lock
                HStack(spacing: 8) {
                    if profile.permits(.locks) && features.contains(.remoteLocks) {
                        Button {
                            gate.send(lockCommand)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: lockIcon)
                                    .hisType(.displaySmall)
                                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                Text(isLocked == true ? L10n.text("Unlock") : L10n.text("Lock"))
                                    .hisType(.body, weight: .semibold)
                                gate.sendingOverlay(lockCommand)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .tint(isLocked == true ? .blue : .green)
                        .help(isLocked == nil
                              ? L10n.text("The vehicle has not reported a lock state yet, so this sends Lock.")
                              : (isLocked == true
                                 ? L10n.text("Unlocks the vehicle.")
                                 : L10n.text("Locks the vehicle.")))
                        .disabled(gate.isDisabled(lockCommand))
                        .help(isLocked == nil
                              ? L10n.text("The vehicle has not reported a lock state yet, so this sends Lock.")
                              : (isLocked == true
                                 ? L10n.text("Unlocks the vehicle.")
                                 : L10n.text("Locks the vehicle.")))
                        .hisAnimation(Motion.stateChange, value: isLocked)
                    }

                    if state.model.brand == .volvo,
                       isLocked == false,
                       profile.permits(.reducedGuardLock),
                       features.contains(.remoteLocks) {
                        Button {
                            gate.send(.lockReducedGuard)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "lock.shield.fill").hisType(.title)
                                Text(L10n.text("Reduced Guard")).hisType(.label, weight: .medium)
                                gate.sendingOverlay(.lockReducedGuard)
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                        }
                        .buttonStyle(.bordered)
                        .disabled(gate.isDisabled(.lockReducedGuard))
                        .help(L10n.text("Locks the vehicle with reduced alarm guard sensitivity, when supported."))
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
                                    Image(systemName: "car.side.rear.open.fill").hisType(.title)
                                    Text(L10n.text("Unlock Trunk")).hisType(.label, weight: .medium)
                                    gate.sendingOverlay(.unlockTrunk)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .disabled(gate.isDisabled(.unlockTrunk))
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        }

                        if showTailgateControl {
                            let tailgateIsOpen = state.exteriorStatus?.isTailgateOpen ?? false
                            Button {
                                gate.send(tailgateIsOpen ? .closeTailgate : .openTailgate)
                            } label: {
                                VStack(spacing: 4) {
                                    Image(systemName: tailgateIsOpen
                                          ? "car.side.rear.open.fill" : "car.side.rear.fill")
                                        .hisType(.title)
                                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                    Text(tailgateIsOpen
                                         ? L10n.text("Close Tailgate") : L10n.text("Open Tailgate"))
                                        .hisType(.label, weight: .medium)
                                    gate.sendingOverlay(tailgateIsOpen ? .closeTailgate : .openTailgate)
                                }
                                .frame(maxWidth: .infinity, minHeight: 46)
                            }
                            .buttonStyle(.bordered)
                            .tint(tailgateIsOpen ? .orange : nil)
                            .disabled(gate.isDisabled(tailgateIsOpen ? .closeTailgate : .openTailgate))
                            .hisAnimation(Motion.stateChange, value: tailgateIsOpen)
                        }
                    }
                }
                // Keyed on every condition that adds/removes a button so the row
                // reflows instead of popping (Reduced Guard, trunk, tailgate).
                .hisAnimation(Motion.cardChange, value: [
                    state.model.brand == .volvo,
                    isLocked == true,
                    profile.permits(.reducedGuardLock),
                    features.contains(.remoteLocks)
                ])
                .hisAnimation(Motion.cardChange, value: state.otaCapabilities?.supportsTrunkControl)
                .hisAnimation(Motion.cardChange, value: state.otaCapabilities?.supportsTrunkUnlock)
            }
        }
        .opacity(gate.liveOpacity([.lock, .unlock]))
        .hisAnimation(Motion.stateChange, value: gate.liveAvailability([.lock, .unlock]))
    }

    /// The action's own icon, except when the vehicle has not reported a state: then the icon says
    /// so rather than showing a padlock, which reads as a claim about the car.
    private var lockIcon: String {
        switch state.exteriorStatus?.isLocked {
        case true: return "lock.open.fill"
        case false: return "lock.fill"
        case nil: return "questionmark.circle"
        }
    }
}
