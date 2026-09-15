import SwiftUI

@MainActor
struct StateSummaryChip: View {
    let message: String
    let severity: VehicleStateSeverity

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch severity {
        case .neutral: return .secondary
        case .good: return HisingenTheme.semanticGood
        case .warning: return HisingenTheme.semanticWarning
        case .critical: return HisingenTheme.semanticCritical
        }
    }

    private var symbol: String {
        switch severity {
        case .neutral: return "info.circle.fill"
        case .good: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }

    private var chipRadius: CGFloat { HisingenTheme.statusChipRadius }

    /// The chip's whole job is to encode severity in a colour and a symbol, and neither reached
    /// the accessibility tree, so a critical state and an informational one were announced
    /// identically. Only the two states that carry a warning are prefixed: "Good" on a calm
    /// label would be noise.
    private var severitySpokenLabel: String {
        switch severity {
        case .warning: return L10n.format("%@: %@", L10n.text("Warning"), message)
        case .critical: return L10n.format("%@: %@", L10n.text("Critical"), message)
        case .good, .neutral: return message
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .hisType(.label, weight: HisingenTheme.headingWeight)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(message)
                .hisType(.body, weight: HisingenTheme.valueWeight)
            Spacer()
        }
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: chipRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: chipRadius, style: .continuous)
                .stroke(color.opacity(0.22), lineWidth: 0.5)
        )
        .hisAnimation(Motion.stateChange, value: severity)
        .hisAnimation(Motion.stateChange, value: message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(severitySpokenLabel)
    }
}
