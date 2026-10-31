import AppKit
import LocalAuthentication

@MainActor
protocol RemoteActionAuthorizing: AnyObject {
    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool
}

@MainActor
final class RemoteActionAuthorizer: RemoteActionAuthorizing {
    /// Result of the device-owner step. `unavailable` carries the reason the policy can't run.
    enum OwnerAuthentication {
        case succeeded
        case failed
        case unavailable(NSError?)
    }

    typealias Confirmation = @MainActor (RemoteCommand, String) -> Bool
    typealias OwnerAuthenticator = @MainActor (_ reason: String) async -> OwnerAuthentication

    private let preferences: PreferencesStore
    private let confirm: Confirmation
    private let authenticateOwner: OwnerAuthenticator
    private let reportAuthenticationFailure: @MainActor (NSError?) -> Void

    /// The defaults show the real alert and `LAContext` prompt; tests replace them so every
    /// branch runs without a modal.
    init(preferences: PreferencesStore,
         confirm: Confirmation? = nil,
         authenticateOwner: OwnerAuthenticator? = nil,
         reportAuthenticationFailure: (@MainActor (NSError?) -> Void)? = nil) {
        self.preferences = preferences
        self.confirm = confirm ?? { command, vehicle in
            Self.runConfirmationAlert(command, vehicle: vehicle, temperatureUnit: preferences.temperatureUnit)
        }
        self.authenticateOwner = authenticateOwner ?? Self.evaluateDeviceOwner
        self.reportAuthenticationFailure = reportAuthenticationFailure ?? Self.showAuthenticationFailure
    }

    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool {
        let requiresConfirmation = command.risk != .routine || preferences.requireBiometricsForRemoteControls
        if requiresConfirmation {
            guard confirm(command, vehicle) else { return false }
        }
        guard preferences.requireBiometricsForRemoteControls || command.risk.requiresDeviceOwnerAuthentication else { return true }

        let reason = L10n.format("Authorize %@ for %@", command.title(temperatureUnit: preferences.temperatureUnit), vehicle)
        switch await authenticateOwner(reason) {
        case .succeeded:
            return true
        case .failed:
            reportAuthenticationFailure(nil)
            return false
        case .unavailable(let error):
            reportAuthenticationFailure(error)
            return false
        }
    }

    private static func runConfirmationAlert(_ command: RemoteCommand, vehicle: String,
                                             temperatureUnit: TemperatureUnit) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = command.risk == .destructive ? .critical : .warning
        alert.messageText = command.title(temperatureUnit: temperatureUnit)
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
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func evaluateDeviceOwner(reason: String) async -> OwnerAuthentication {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable(error)
        }
        let success = await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        return success ? .succeeded : .failed
    }

    private static func showAuthenticationFailure(_ error: NSError?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.text("Authentication required")
        alert.informativeText = error?.localizedDescription
            ?? L10n.text("This command was cancelled because device-owner authentication did not succeed.")
        alert.addButton(withTitle: L10n.text("OK"))
        alert.runModal()
    }
}
