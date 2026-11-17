import SwiftUI

@MainActor
struct AccessControlsCard: View {
    let state: VehicleState
    let gate: ControlsCommandGate

    private var profile: VehicleCapabilityProfile { state.capabilityProfile }
    private var features: Set<AppFeature> { gate.features }

    var body: some View {
        let isLocked = state.exteriorStatus?.isLocked
        let lockCommand: RemoteCommand = isLocked == true ? .unlock : .lock
        let lockAvailability = gate.liveAvailability([lockCommand])
        Card(compact: true) {
            VStack(alignment: .leading, spacing: 10) {
                CardHeaderWithAccessory(
                    heading: CardHeader(symbol: "lock", title: L10n.text("Locks & Security"), color: HisingenTheme.semanticActive)
                ) {
                    lockStatus(isLocked)
                }
                gate.dimReason(lockAvailability)

                VehicleCommandRow {
                    if profile.permits(.locks) && features.contains(.remoteLocks) {
                        VehicleCommandButton(
                            title: isLocked == true ? L10n.text("Unlock") : L10n.text("Lock"),
                            symbol: isLocked == true ? "lock.open" : "lock",
                            command: lockCommand, gate: gate, isPrimary: true
                        )
                        .help(lockAvailability.shortReason ?? lockHelp(isLocked))
                    }

                    if state.model.brand == .volvo,
                       isLocked == false,
                       profile.permits(.reducedGuardLock),
                       features.contains(.remoteLocks) {
                        VehicleCommandButton(
                            title: L10n.text("Reduced Guard"), symbol: "lock.shield",
                            command: .lockReducedGuard, gate: gate
                        )
                        .help(L10n.text("Locks the vehicle with reduced alarm guard sensitivity, when supported."))
                    }

                    if features.contains(.remoteLocks) {
                        let capabilities = state.otaCapabilities
                        let showTrunkUnlock = profile.permits(.trunk)
                            && (capabilities?.supportsTrunkUnlock ?? profile.permits(.trunk))

                        if showTrunkUnlock {
                            VehicleCommandButton(
                                title: L10n.text("Unlock Trunk"), symbol: "lock.open",
                                command: .unlockTrunk, gate: gate
                            )
                        }

                        if capabilities?.supportsTrunkControl == true {
                            let tailgateIsOpen = state.exteriorStatus?.isTailgateOpen ?? false
                            VehicleCommandButton(
                                title: tailgateIsOpen ? L10n.text("Close Tailgate") : L10n.text("Open Tailgate"),
                                symbol: tailgateIsOpen ? "car.side" : "car.side.rear.open",
                                command: tailgateIsOpen ? .closeTailgate : .openTailgate, gate: gate
                            )
                        }
                    }
                }
                .hisAnimation(Motion.cardChange, value: [
                    state.model.brand == .volvo,
                    isLocked == false,
                    profile.permits(.reducedGuardLock),
                    features.contains(.remoteLocks)
                ])
                .hisAnimation(Motion.cardChange, value: state.otaCapabilities?.supportsTrunkControl)
                .hisAnimation(Motion.cardChange, value: state.otaCapabilities?.supportsTrunkUnlock)
            }
        }
    }

    private func lockStatus(_ isLocked: Bool?) -> some View {
        let text: String
        let symbol: String
        let color: Color
        switch isLocked {
        case true?:
            text = L10n.text("Locked")
            symbol = "lock"
            color = HisingenTheme.ink
        case false?:
            text = L10n.text("Unlocked")
            symbol = "lock.open"
            color = HisingenTheme.semanticWarning
        case nil:
            text = L10n.text("Lock State Not Reported")
            symbol = "questionmark.circle"
            color = HisingenTheme.inkMuted
        }
        return Label(text, systemImage: symbol)
            .hisType(.body)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func lockHelp(_ isLocked: Bool?) -> String {
        switch isLocked {
        case true?: return L10n.text("Unlocks the vehicle.")
        case false?: return L10n.text("Locks the vehicle.")
        case nil: return L10n.text("The vehicle has not reported a lock state yet, so this sends Lock.")
        }
    }
}
