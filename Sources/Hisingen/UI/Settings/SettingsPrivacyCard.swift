import SwiftUI

@MainActor
struct SettingsPrivacyCard: View {
    @Binding var persistLocationHistory: Bool
    let binder: PreferenceBinder

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "hand.raised.fill", title: L10n.text("Privacy Dashboard"), color: .purple)
                Text(L10n.text("Hisingen keeps account secrets in the macOS Keychain and vehicle history in a local SQLite database."))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                KVRow(L10n.text("Account secrets"), L10n.text("macOS Keychain"), symbol: "key.fill")
                KVRow(L10n.text("Vehicle history"), L10n.text("Stored locally on this Mac"), symbol: "internaldrive.fill")
                KVRow(
                    L10n.text("Precise location retention"),
                    persistLocationHistory ? L10n.text("Enabled") : L10n.text("Off (recommended)"),
                    symbol: persistLocationHistory ? "location.fill" : "location.slash.fill"
                )
                KVRow(
                    L10n.text("Screenshot redaction"),
                    preferences.privacyRedactionEnabled ? L10n.text("Enabled") : L10n.text("Disabled"),
                    symbol: "eye.slash.fill"
                )
                KVRow(
                    L10n.text("Remote-command authentication"),
                    preferences.requireBiometricsForRemoteControls ? L10n.text("Required") : L10n.text("Not required"),
                    symbol: "person.badge.key.fill"
                )

                Text(L10n.text("Exports may contain vehicle identifiers and telemetry. Review files before sharing them."))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(HisingenTheme.semanticWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
