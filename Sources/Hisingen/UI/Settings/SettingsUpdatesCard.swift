import SwiftUI

/// The "Hisingen Updates" card in Settings → Updates: manual check plus the two Sparkle
/// auto-update toggles (disabling checks cascades to disabling downloads). Extracted from
/// `SettingsView`; binds through `PreferenceBinder`.
@MainActor
struct SettingsUpdatesCard: View {
    let binder: PreferenceBinder

    private var prefs: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(symbol: "arrow.down.circle.fill", title: L10n.text("Hisingen Updates"), color: .blue)
                Text(L10n.text("Updates are downloaded from Hisingen’s signed update feed and verified before installation."))
                    .hisType(.caption)
                    .hisCaptionLeading()
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.secondary)

                HStack {
                    Label(L10n.text("Stable channel"), systemImage: "checkmark.seal.fill")
                        .hisType(.caption, weight: .medium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        binder.notify(.checkForUpdates)
                    } label: {
                        Label(L10n.text("Check Now"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Automatically check for updates"))
                            .hisType(.body, weight: .medium)
                        Text(L10n.text("Check quietly in the background while Hisingen is running"))
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { prefs.automaticallyChecksForUpdates },
                        set: { value in
                            prefs.automaticallyChecksForUpdates = value
                            // Disabling checks also disables downloads – a download with no
                            // preceding check can never happen.
                            if !value { prefs.automaticallyDownloadsUpdates = false }
                            binder.bump()
                            binder.notify(.updater)
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel(L10n.text("Automatically check for updates"))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Check frequency"))
                            .hisType(.body, weight: .medium)
                        Text(L10n.text("How often Hisingen looks for new versions"))
                            .hisType(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binder(\.updateCheckInterval, .updater)) {
                        ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                            Text(interval.title).tag(interval)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 160)
                    .accessibilityLabel(L10n.text("Check frequency"))
                    .disabled(!prefs.automaticallyChecksForUpdates)
                }

                Divider().opacity(HisingenTheme.dividerOpacity)

                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Automatically download updates"))
                            .hisType(.body, weight: .medium)
                        Text(L10n.text("Download verified updates in the background; installation still uses macOS confirmation."))
                            .hisType(.caption)
                            .hisCaptionLeading()
                            .fixedSize(horizontal: false, vertical: true)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: binder(\.automaticallyDownloadsUpdates, .updater))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("Automatically download updates"))
                        .disabled(!prefs.automaticallyChecksForUpdates)
                }
            }
        }
    }
}
