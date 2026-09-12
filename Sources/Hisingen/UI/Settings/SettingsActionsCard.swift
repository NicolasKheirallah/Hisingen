import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsActionsCard: View {
    let binder: PreferenceBinder
    let onSignOut: () -> Void

    @State private var pendingSettingsImport: Data?
    @State private var showSettingsImportConfirmation = false
    @State private var showSettingsResetConfirmation = false
    @State private var showSignOutConfirmation = false
    @State private var settingsTransferFeedback: (message: String, isError: Bool)?

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Button { exportSettings() } label: {
                        Label(L10n.text("Export Settings"), systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    Button { chooseSettingsImport() } label: {
                        Label(L10n.text("Import Settings"), systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    Button(role: .destructive) { showSettingsResetConfirmation = true } label: {
                        Label(L10n.text("Reset Preferences"), systemImage: "arrow.counterclockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if let settingsTransferFeedback {
                    Label(
                        settingsTransferFeedback.message,
                        systemImage: settingsTransferFeedback.isError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(settingsTransferFeedback.isError ? Color.red : HisingenTheme.semanticGood)
                    .textSelection(.enabled)
                }

                Divider().opacity(0.4)
                Button(role: .destructive) {
                    showSignOutConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                        Text(L10n.format("Sign Out of %@ Account", preferences.activeBrand.displayName))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .tint(.red)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text(L10n.text("Quit Hisingen"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            }
        }
        .confirmationDialog(
            L10n.format("Sign out of %@?", preferences.activeBrand.displayName),
            isPresented: $showSignOutConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Sign Out & Remove Session"), role: .destructive) { onSignOut() }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("The saved session and account credentials for this provider will be removed from this Mac. Local vehicle history is kept."))
        }
        .confirmationDialog(
            L10n.text("Import these settings?"),
            isPresented: $showSettingsImportConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Import & Replace Settings"), role: .destructive) {
                applyPendingSettingsImport()
            }
            Button(L10n.text("Cancel"), role: .cancel) { pendingSettingsImport = nil }
        } message: {
            Text(L10n.text("Presentation, feature, update, and notification preferences will be replaced. Accounts, sessions, vehicles, and history are not included."))
        }
        .confirmationDialog(
            L10n.text("Reset app preferences?"),
            isPresented: $showSettingsResetConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("Reset Preferences"), role: .destructive) {
                preferences.resetTransferableSettings()
                notifyAllPreferenceSubsystems()
                binder.notify(.closeSettings)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Presentation, feature, update, and notification preferences return to defaults. Accounts, sessions, vehicles, and history are kept."))
        }
    }

    private func exportSettings() {
        do {
            let data = try preferences.exportSettingsPropertyList()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.propertyList]
            panel.nameFieldStringValue = "hisingen-settings.plist"
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                    settingsTransferFeedback = (L10n.text("Settings exported."), false)
                } catch {
                    settingsTransferFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
                }
            }
        } catch {
            settingsTransferFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
        }
    }

    private func chooseSettingsImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard fileSize <= 1_000_000 else {
                    settingsTransferFeedback = (L10n.text("The selected settings archive is larger than 1 MB."), true)
                    return
                }
                pendingSettingsImport = try Data(contentsOf: url, options: .mappedIfSafe)
                showSettingsImportConfirmation = true
            } catch {
                settingsTransferFeedback = (L10n.format("Import failed: %@", error.localizedDescription), true)
            }
        }
    }

    private func applyPendingSettingsImport() {
        guard let data = pendingSettingsImport else { return }
        defer { pendingSettingsImport = nil }
        do {
            try preferences.importSettingsPropertyList(data)
            settingsTransferFeedback = (L10n.text("Settings imported."), false)
            notifyAllPreferenceSubsystems()
            binder.notify(.closeSettings)
        } catch {
            settingsTransferFeedback = (L10n.format("Import failed: %@", error.localizedDescription), true)
        }
    }

    private func notifyAllPreferenceSubsystems() {
        binder.notify(.features)
        binder.notify(.notifications)
        binder.notify(.presentation)
        binder.notify(.launchAtLogin)
        binder.notify(.updater)
    }
}
