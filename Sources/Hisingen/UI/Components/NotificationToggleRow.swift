import SwiftUI

/// Shared settings row scaffolding: icon, title, detail and a trailing switch.
/// Generalized from SettingsNotificationsCard's notificationRow so other
/// settings cards reuse one layout and one accessibility treatment
/// (label + hint on the toggle) instead of hand-rolling rows.
struct NotificationToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    let isOn: Binding<Bool>

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title))
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.text(detail))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.text(title))
                .accessibilityHint(L10n.text(detail))
        }
        .padding(.vertical, 3)
    }
}
