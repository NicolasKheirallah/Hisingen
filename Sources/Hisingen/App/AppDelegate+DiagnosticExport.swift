import AppKit
import UniformTypeIdentifiers

extension AppDelegate {
    /// Builds the redacted diagnostic bundle off the main thread and offers a save panel.
    /// Reached from Settings → Privacy & Data and from the sign-in failure card, where
    /// attaching the failed exchanges to a bug report is the whole point.
    func exportDiagnosticLogs() {
        let database = vehicleDatabase
        Task { @MainActor in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    try await DiagnosticLogExporter.buildReport(database: database)
                }.value
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                panel.nameFieldStringValue = "hisingen_diagnostics_\(Int(Date().timeIntervalSince1970)).json"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    presentExportFailure(error)
                }
            } catch {
                presentExportFailure(error)
            }
        }
    }

    /// A silently missing export file reads as lost data; surface the underlying cause
    /// (permissions, disk full) instead of swallowing it after the user picked a target.
    private func presentExportFailure(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("Export failed")
        alert.informativeText = "\(L10n.text("The diagnostic report could not be created."))\n\n\(error.localizedDescription)"
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}
