import SwiftUI

@MainActor
struct StateSummaryChip: View {
    enum Prominence {
        case standard
        case quiet
    }

    let message: String
    let severity: VehicleStateSeverity
    var prominence: Prominence = .standard

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
                .hisType(prominence == .quiet ? .micro : .label, weight: HisingenTheme.headingWeight)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                .accessibilityHidden(true)
            Text(message)
                .hisType(prominence == .quiet ? .label : .body,
                         weight: prominence == .quiet ? .semibold : HisingenTheme.valueWeight)
        }
        .foregroundStyle(color)
        .statusChipSurface(
            tint: color,
            wash: prominence == .quiet ? 0 : 0.12,
            horizontal: prominence == .quiet ? 0 : 10,
            vertical: prominence == .quiet ? 0 : 7
        )
        .hisAnimation(Motion.stateChange, value: severity)
        .hisAnimation(Motion.stateChange, value: message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(severitySpokenLabel)
    }
}
