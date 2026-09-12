import SwiftUI

@MainActor
struct CommandReceiptChip: View {
    let receipt: CommandReceipt
    let onDismiss: (UUID) -> Void

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
            return L10n.text("Command sent — waiting for the vehicle")
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: appearance.symbol)
                .foregroundStyle(appearance.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(confirmationLabel)
                    .font(.system(size: 11, weight: .semibold))
                Text(receipt.command?.title ?? L10n.text("Values below may update once the car reports in."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            Button {
                onDismiss(receipt.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Dismiss command status"))
        }
        .padding(9)
        .background(appearance.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(appearance.color.opacity(0.25), lineWidth: 0.5)
        )
    }
}
