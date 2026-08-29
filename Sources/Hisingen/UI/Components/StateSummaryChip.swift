import SwiftUI

@MainActor
struct StateSummaryChip: View {
    let message: String
    let severity: VehicleStateSeverity

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

    private var chipRadius: CGFloat { HisingenTheme.cornerRadius == 0 ? 0 : 9 }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: HisingenTheme.headingWeight))
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}
