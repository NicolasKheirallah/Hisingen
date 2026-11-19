import SwiftUI

@MainActor
struct SettingsPrivacyCard: View {
    let binder: PreferenceBinder

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "hand.raised", title: L10n.text("Privacy"), color: HisingenTheme.chartInfo)
                Text(L10n.text("Hisingen keeps account secrets in the macOS Keychain and vehicle history in a local SQLite database."))
                    .hisType(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                privacyToggle(
                    "Screenshot Privacy Mode",
                    detail: "Blurs VIN, plate and coordinates across the app for safe sharing.",
                    isOn: binder.toggle(\.privacyRedactionEnabled, .presentation)
                )
                privacyToggle(
                    "Require device-owner authentication",
                    detail: "Authenticate before running remote commands",
                    isOn: binder.toggle(\.requireBiometricsForRemoteControls)
                )
            }
        }
    }

    private func privacyToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title)).hisType(.label, weight: .semibold)
                Text(L10n.text(detail))
                    .hisType(.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
