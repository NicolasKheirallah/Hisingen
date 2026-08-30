import SwiftUI

/// One row in Settings → Features / Remote Controls: an icon, a title (with an optional
/// "not supported here" badge), a description, and a switch bound to one `AppFeature` in
/// `preferences.features`. Shared by `SettingsVehicleDataCard` and
/// `SettingsRemoteControlsCard`; reads/writes the feature set live through `PreferenceBinder`.
@MainActor
struct SettingsFeatureToggleRow: View {
    let binder: PreferenceBinder
    let feature: AppFeature
    let symbol: String
    let title: String
    let detail: String
    var isSupported: Bool = true
    var badgeText: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSupported ? .secondary : .tertiary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(L10n.text(title))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSupported ? .primary : .secondary)
                    if let badgeText {
                        Text(L10n.text(badgeText))
                            .font(.system(size: 8, weight: .semibold))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(L10n.text(detail))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary.opacity(isSupported ? 1.0 : 0.7))
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { isSupported && binder.preferences.features.contains(feature) },
                set: { enabled in
                    guard isSupported else { return }
                    var updated = binder.preferences.features
                    updated.set(feature, enabled: enabled)
                    binder.preferences.features = updated
                    binder.bump()
                    binder.notify(.features)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .disabled(!isSupported)
            .accessibilityLabel(L10n.text(title))
            .accessibilityHint(L10n.text(detail))
        }
        .padding(.vertical, 3)
        .opacity(isSupported ? 1.0 : 0.55)
    }
}
