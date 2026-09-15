import SwiftUI

enum CapabilityState {
    case unsupported
    case unavailable
    case unknown

    var label: String {
        switch self {
        case .unsupported: return L10n.text("Unsupported")
        case .unavailable: return L10n.text("Temporarily unavailable")
        case .unknown: return L10n.text("Not yet checked")
        }
    }

    var symbol: String {
        switch self {
        case .unsupported: return "minus.circle"
        case .unavailable: return "wifi.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct CapabilityBadge: View {
    let title: String
    let state: CapabilityState

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
