import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsActionsCard: View {
    let binder: PreferenceBinder

    @State private var pendingSettingsImport: Data?
    @State private var showSettingsImportConfirmation = false
    @State private var showSettingsResetConfirmation = false
    @State private var settingsTransferFeedback: (message: String, isError: Bool)?

    private var preferences: PreferencesStore { binder.preferences }

    var body: some View {
        Card {
            VStack(spacing: 8) {
                CardHeader(symbol: "gearshape.2", title: L10n.text("Settings Backup"), color: .secondary)
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
                .buttonStyle(.hisSecondary)
                .controlSize(.small)

                if let settingsTransferFeedback {
                    Label(
                        settingsTransferFeedback.message,
                        systemImage: settingsTransferFeedback.isError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .hisType(.micro, weight: .medium)
                    .foregroundStyle(settingsTransferFeedback.isError ? HisingenTheme.semanticCritical : HisingenTheme.semanticGood)
                    .textSelection(.enabled)
                }
            }
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
                settingsTransferFeedback = (L10n.text("Preferences reset to defaults."), false)
            }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text("Presentation, feature, update, and notification preferences return to defaults. Accounts, sessions, vehicles, and history are kept."))
        }
    }

    private func exportSettings() {
        do {
            let data = try preferences.exportSettingsPropertyList()
            FileExport.save(data, type: .propertyList, filename: "hisingen-settings.plist") { _, error in
                if let error {
                    settingsTransferFeedback = (L10n.format("Export failed: %@", error.localizedDescription), true)
                } else {
                    settingsTransferFeedback = (L10n.text("Settings exported."), false)
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
