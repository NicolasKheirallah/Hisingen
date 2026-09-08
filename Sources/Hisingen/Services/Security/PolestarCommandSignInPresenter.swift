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
    private var flow: PolestarBrowserFlow?
    private var flowID: UUID?
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    func signIn(authorizeURL: URL) async throws -> URL {
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        flowID = id
        flow = PolestarBrowserFlow(authorizeURL: authorizeURL,
                                  redirectURI: URL(string: "polestar-explore://explore.polestar.com")!)
        NSApp.activate(ignoringOtherApps: true)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
                if !NSWorkspace.shared.open(authorizeURL) { cancel() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flowID == id else { return }
                self?.cancel(with: CancellationError())
            }
        }
    }

    func handleCallbackURL(_ url: URL) {
        guard flow?.accepts(url) == true, let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        flow = nil
        flowID = nil
        continuation.resume(returning: url)
    }

    func cancel(with error: Error? = nil) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        flow = nil
        flowID = nil
        continuation.resume(throwing: error ?? PolestarError.authenticationRequired(.callbackRejected))
    }
}
