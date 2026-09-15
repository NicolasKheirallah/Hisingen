import SwiftUI

@MainActor
struct CommandReceiptChip: View {
    let receipt: CommandReceipt
    let onDismiss: (UUID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appearance: (symbol: String, color: Color) {
        switch receipt.status {
        case .confirmed, .acknowledged:
            return ("checkmark.circle.fill", HisingenTheme.semanticGood)
        case .timedOut:
            return ("exclamationmark.triangle.fill", HisingenTheme.semanticWarning)
        case .awaiting:
            return ("clock.arrow.circlepath", HisingenTheme.accent)
        }
    }

    private var confirmationLabel: String {
        switch receipt.status {
        case .confirmed:
            return L10n.text("Matching vehicle reading observed")
        case .acknowledged:
            return L10n.text("Command acknowledged by the vehicle service")
        case .timedOut:
            return L10n.text("Command outcome not confirmed")
        case .awaiting:
            return L10n.text("Command sent: waiting for the vehicle")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.color)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirmationLabel)
                    .hisType(.label, weight: .semibold)
                Text(receipt.command?.title ?? L10n.text("Values below may update once the car reports in."))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                onDismiss(receipt.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(L10n.text("Dismiss command status"))
        }
        .padding(9)
        .background(
            appearance.color.opacity(0.08),
            in: RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous)
                .stroke(appearance.color.opacity(0.25), lineWidth: 0.5)
        )
        .hisAnimation(Motion.stateChange, value: receipt.status)
        // Declared here so any host stack that animates insertions gets the
        // same drop-in the other vehicle cards use.
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
