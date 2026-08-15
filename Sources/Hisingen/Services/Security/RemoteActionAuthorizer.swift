import AppKit
import LocalAuthentication

@MainActor
final class RemoteActionAuthorizer {
    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = command.risk == .routine ? .warning : .critical
        alert.messageText = command.title
        alert.informativeText = L10n.format(
            "Send this command to %@? Hisingen will submit it once and then refresh vehicle state.",
            vehicle
        )
        alert.addButton(withTitle: L10n.text("Send Command"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        guard command.risk.requiresDeviceOwnerAuthentication else { return true }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            showAuthenticationFailure(error)
            return false
        }
        let reason = L10n.format("Authorize %@ for %@", command.title, vehicle)
        let success = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        if !success { showAuthenticationFailure(nil) }
        return success
    }

    private func showAuthenticationFailure(_ error: NSError?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("Authentication required")
        alert.informativeText = error?.localizedDescription
            ?? L10n.text("This command was cancelled because device-owner authentication did not succeed.")
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}

