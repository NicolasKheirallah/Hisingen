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
                .font(.system(size: 11, weight: HisingenTheme.headingWeight))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 12, weight: HisingenTheme.valueWeight))
                .foregroundStyle(.secondary)
            Spacer()
            Text(state.label)
                .font(.system(size: 10.5, weight: HisingenTheme.valueWeight))
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(state.label)")
    }
}
