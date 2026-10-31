import AppKit
import Foundation

/// What Settings → Features → Remote Controls → "Authorize…" tells the user when it does not
/// complete.
///
/// The browser round-trip fails *after* the user has signed in, and its only feedback used to be
/// a system notification: invisible when notifications are off, in Focus, or simply while the
/// user is still looking at the window that started it. Two full attempts in the log ended that
/// way, and the report was "Authorize doesn't do anything". The failure is classified once here
/// so it can be rendered in-window instead.
struct CommandAuthorizationFailure: Equatable {
    let title: String
    let message: String
    /// Whether the way out is a fresh sign-in, so the alert can offer that as a button instead of
    /// telling the reader to go find the control.
    let offersSignIn: Bool

    init(title: String, message: String, offersSignIn: Bool = false) {
        self.title = title
        self.message = message
        self.offersSignIn = offersSignIn
    }

    /// Maps a thrown error to the copy shown for it. The session case is the common one: the
    /// browser step mints a grant, then verification needs the account session behind it, and a
    /// dead session throws the grant away. Saying so immediately is the whole fix.
    static func make(for error: any Error) -> CommandAuthorizationFailure {
        switch SignInFailureKind.classify(error, provider: .polestar) {
        case .sessionExpired:
            return CommandAuthorizationFailure(
                title: L10n.text("Sign in to Polestar first"),
                message: L10n.text("Your Polestar session expired. Sign in again. The interactive window handles any new verification step Polestar added."),
                offersSignIn: true
            )
        case .interactiveChallenge, .invalidCredentials:
            return CommandAuthorizationFailure(
                title: L10n.text("Authorization failed"),
                message: L10n.text("Polestar requested an additional or changed sign-in step. Sign in again via the interactive window, then retry Authorize."),
                offersSignIn: true
            )
        case .transient:
            return CommandAuthorizationFailure(
                title: L10n.text("Authorization failed"),
                message: L10n.text("Couldn't confirm remote-command authorization with Polestar. Check your connection and try again.")
            )
        case .signingFlowChanged, .unspecified:
            return CommandAuthorizationFailure(
                title: L10n.text("Authorization failed"),
                message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }
}

/// Presents a `CommandAuthorizationFailure` where the user is: in front of the Settings window
/// that owns the button. Injectable so tests can assert the flow reports instead of opening a
/// browser.
@MainActor
protocol CommandAuthorizationAlertPresenting {
    /// Returns true when the user chose to sign in now.
    func present(_ failure: CommandAuthorizationFailure) -> Bool
}

/// A window-modal alert. Deliberately not a notification: the user just clicked a control, so
/// the answer belongs in the app they are already looking at, even with Focus on.
@MainActor
struct CommandAuthorizationAlertPresenter: CommandAuthorizationAlertPresenting {
    nonisolated init() {}

    func present(_ failure: CommandAuthorizationFailure) -> Bool {
        let alert = NSAlert()
        alert.messageText = failure.title
        alert.informativeText = failure.message
        alert.alertStyle = .warning
        if failure.offersSignIn {
            alert.addButton(withTitle: L10n.text("Sign In"))
            alert.addButton(withTitle: L10n.text("OK"))
        } else {
            alert.addButton(withTitle: L10n.text("OK"))
        }
        // A menu-bar app is not the active app when a Settings control is clicked in a panel that
        // never took focus, and a window-modal alert from an inactive app can open behind
        // everything. Bringing the app forward first is what makes this answer visible at all.
        NSApp.activate(ignoringOtherApps: true)
        return failure.offersSignIn && alert.runModal() == .alertFirstButtonReturn
    }
}
