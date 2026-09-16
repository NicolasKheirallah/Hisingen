import SwiftUI

struct CapabilityBadge: View {
    let title: String
    let state: CapabilitySummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: state.symbol)
                .hisType(.label, weight: HisingenTheme.headingWeight)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .hisType(.body, weight: HisingenTheme.valueWeight)
                .foregroundStyle(.secondary)
            Spacer()
            // All three states rendered in `.tertiary`, so a capability this vehicle will never
            // have and one that is merely unreachable right now looked identical. The permanent
            // one stays quiet; the temporary one is the state a reader can act on.
            Text(state.label)
                .hisType(.caption, weight: HisingenTheme.valueWeight)
                .foregroundStyle(state == .unavailable ? HisingenTheme.semanticWarning : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.label)")
    }
}
