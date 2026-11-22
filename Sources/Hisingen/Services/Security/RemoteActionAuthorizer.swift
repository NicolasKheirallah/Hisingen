import AppKit
import LocalAuthentication

@MainActor
protocol RemoteActionAuthorizing: AnyObject {
    /// `origin` is who asked. A `.deepLink` command always needs the person's confirmation,
    /// whatever its risk: a URL another app or page opened says nothing about what the person
    /// at the Mac wanted.
    func authorize(_ command: RemoteCommand, vehicle: String, origin: RemoteCommandOrigin) async -> Bool
}

extension RemoteActionAuthorizing {
    /// A command the person asked for in the app itself.
    func authorize(_ command: RemoteCommand, vehicle: String) async -> Bool {
        await authorize(command, vehicle: vehicle, origin: .userInitiated)
    }
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

    func authorize(_ command: RemoteCommand, vehicle: String, origin: RemoteCommandOrigin) async -> Bool {
        let requiresConfirmation = origin == .deepLink
            || command.risk != .routine
            || preferences.requireBiometricsForRemoteControls
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

    /// How long the confirmation stays open before it counts as declined. While it is open the
    /// dispatch lane is held, so an alert nobody sees would otherwise answer every later command
    /// and automation with "busy".
    static let confirmationTimeout: TimeInterval = 120

    private static func runConfirmationAlert(_ command: RemoteCommand, vehicle: String,
                                             temperatureUnit: TemperatureUnit) -> Bool {
        // A menu-bar app is not frontmost when a deep link or a Shortcut raises this, and an
        // alert from a background app can open behind the windows the person is working in.
        NSApp.activate(ignoringOtherApps: true)
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
        // The timer is added to the main run loop below, so its block runs on the main thread.
        let expiry = Timer(timeInterval: confirmationTimeout, repeats: false) { _ in
            MainActor.assumeIsolated { NSApp.abortModal() }
        }
        RunLoop.main.add(expiry, forMode: .common)
        defer { expiry.invalidate() }
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
