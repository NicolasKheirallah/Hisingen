import SwiftUI

@MainActor
struct CommandReceiptChip: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let receipt: CommandReceipt
    let onDismiss: (UUID) -> Void
    /// Requests a fresh reading so the receipt can settle against telemetry. Only shown
    /// for acknowledged outcomes: the service accepted the command but no reading proves
    /// the car carried it out, and a refresh is what moves the receipt to confirmed.
    var onVerify: ((UUID) -> Void)? = nil

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
            if case .acknowledged = receipt.status, let onVerify {
                Button(L10n.text("Verify now")) { onVerify(receipt.id) }
                    .buttonStyle(.pressable)
                    .hisType(.micro, weight: .semibold)
                    .foregroundStyle(HisingenTheme.accent)
                    .accessibilityLabel(L10n.text("Verify now"))
                    .help(L10n.text("Verify now"))
            }
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
            appearance.color.opacity(HisingenTheme.tintedWashOpacity(0.12, increasedContrast: contrast == .increased)),
            in: RoundedRectangle(cornerRadius: HisingenTheme.statusChipRadius, style: .continuous)
        )
        .hisAnimation(Motion.stateChange, value: receipt.status)
        .onChange(of: receipt.status) { _, status in
            switch status {
            case .confirmed, .acknowledged:
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            case .timedOut:
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            case .awaiting:
                break
            }
        }
        // Declared here so any host stack that animates insertions gets the
        // same drop-in the other vehicle cards use.
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
