import AppKit
import Foundation

/// Authorizes the Polestar *command* client (`lp8dyrd_10`, remote commands only — see
/// `PolestarAPI.commandClientID`) through the user's real system browser instead of Hisingen
/// scripting the PingFederate login form itself. Mirrors `VolvoSignInPresenter` exactly: opens
/// the authorization URL via `NSWorkspace`, and waits for the OS to hand the final redirect back
/// through the app's registered `polestar-explore://` URL scheme (the command client's own
/// registered redirect URI — see `PolestarAPI.commandRedirectURL`). Hisingen never sees the
/// Polestar ID password for this flow.
@MainActor
final class PolestarCommandSignInPresenter: NSObject {
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    func signIn(authorizeURL: URL) async throws -> URL {
        NSApp.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: PolestarError.authenticationRequired(.callbackRejected))
            }
            self.pendingContinuation = continuation

            let opened = NSWorkspace.shared.open(authorizeURL)
            if !opened {
                self.pendingContinuation = nil
                continuation.resume(throwing: PolestarError.authenticationRequired(.callbackRejected))
            }
        }
    }

    func handleCallbackURL(_ url: URL) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: url)
    }

    func cancel(with error: Error? = nil) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(throwing: error ?? PolestarError.authenticationRequired(.callbackRejected))
    }
}
