import AppKit
import SwiftUI

/// App name, version/build, and author links at the foot of the About section.
@MainActor
struct SettingsVersionFooter: View {
    var body: some View {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
        let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "car.fill")
                    .hisType(.caption, weight: .semibold)
                    .foregroundStyle(HisingenTheme.accent)
                Text(L10n.text("Hisingen"))
                    .hisType(.body, weight: .semibold, design: .rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                Text("v\(appVersion)")
                    .hisType(.label, weight: .medium, design: .monospaced)
                    .foregroundStyle(.secondary)
                Text("(\(buildNumber))")
                    .hisType(.micro, weight: .regular, design: .monospaced)
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 3) {
                Text(L10n.text("Created by"))
                    .hisType(.caption)
                    .foregroundStyle(.tertiary)
                Button("Nicolas Kheirallah") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .hisType(.caption, weight: .medium)
                Text("·")
                    .hisType(.caption)
                    .foregroundStyle(.tertiary)
                Button("GitHub") {
                    if let url = URL(string: "https://github.com/NicolasKheirallah/Hisingen") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .hisType(.caption, weight: .medium)
            }
            Label(
                L10n.text("Credentials stay in Keychain. Vehicle history stays on this Mac unless you export it."),
                systemImage: "lock.shield"
            )
            .hisType(.micro)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(HisingenTheme.canvas.opacity(0.5))
        }
    }
}
