import AppKit
import LocalAuthentication

@MainActor
protocol RemoteActionAuthorizing: AnyObject {
    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool
}

@MainActor
final class RemoteActionAuthorizer: RemoteActionAuthorizing {
    private let preferences: PreferencesStore

    init(preferences: PreferencesStore) { self.preferences = preferences }

    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool {
        let requiresConfirmation = command.risk != .routine || preferences.requireBiometricsForRemoteControls
        if requiresConfirmation {
            let alert = NSAlert()
            alert.alertStyle = command.risk == .destructive ? .critical : .warning
            alert.messageText = command.title(temperatureUnit: preferences.temperatureUnit)
            // A software install takes the car out of use for the duration, and the confirmation
            // said only that a command would be sent. The one consequence the reader cannot undo by
            // waiting is stated where they decide.
            let consequence = command == .installOTANow
                ? " " + L10n.text("The car cannot be driven while this installs.")
                : ""
            alert.informativeText = L10n.format(
                "Send this command to %@? Hisingen will submit it once and then refresh vehicle state.",
                vehicle
            ) + consequence
            alert.addButton(withTitle: L10n.text("Send Command"))
            alert.addButton(withTitle: L10n.text("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        guard preferences.requireBiometricsForRemoteControls || command.risk.requiresDeviceOwnerAuthentication else { return true }

        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            showAuthenticationFailure(error)
            return false
        }
        let reason = L10n.format("Authorize %@ for %@", command.title(temperatureUnit: preferences.temperatureUnit), vehicle)
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
