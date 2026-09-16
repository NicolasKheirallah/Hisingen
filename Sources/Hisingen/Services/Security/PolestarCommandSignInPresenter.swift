import AppKit
import AuthenticationServices
import Foundation

/// Authorizes the Polestar *command* client (`lp8dyrd_10`, remote commands only – see
/// `PolestarAPI.commandClientID`) through the system browser session rather than Hisingen
/// scripting the PingFederate login form itself.
///
/// `ASWebAuthenticationSession` shows the real Polestar sign-in page – Safari-backed, and with an
/// ephemeral session declined it carries the cookies and saved credentials the user already has –
/// and then dismisses itself the moment the `polestar-explore://` redirect arrives. That is the
/// whole point of using it here: the user gets the sign-in they recognise and the window closes on
/// its own once the token is in hand, with no new permission to grant.
///
/// Two properties of the previous real-browser flow are preserved. Hisingen still never sees the
/// Polestar ID password, because the page runs outside this process (the same reason the command
/// client does not use `PolestarWebSignInPresenter`'s `WKWebView`, whose DOM the app *could* read).
/// And the callback is delivered to this session directly, so the flow no longer depends on
/// LaunchServices routing the custom scheme back into this app – another app registering
/// `polestar-explore://` can neither intercept nor stall it.
///
/// If the session cannot start at all (no usable presentation anchor, a platform regression) the
/// flow falls back to opening the URL in the user's own browser and waiting for the OS to hand the
/// redirect back through the registered scheme, which is what this presenter did before.
@MainActor
final class PolestarCommandSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var flow: PolestarBrowserFlow?
    private var flowID: UUID?
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var session: ASWebAuthenticationSession?

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
                if !startSystemSession(authorizeURL: authorizeURL),
                   !NSWorkspace.shared.open(authorizeURL) {
                    cancel()
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.flowID == id else { return }
                self?.cancel(with: CancellationError())
            }
        }
    }

    /// Starts the system browser session. Returns whether it started, so the caller can fall back
    /// to the user's own browser. `start()` must be called on the main thread and the session must
    /// be retained until it completes, hence the property assignment before the call.
    private func startSystemSession(authorizeURL: URL) -> Bool {
        // `@Sendable` is load-bearing: a closure formed in a `@MainActor` method inherits that
        // isolation, but AuthenticationServices delivers this completion from a background XPC
        // queue, so an isolated closure traps in `dispatch_assert_queue` before it can hop. It must
        // be non-isolated and do the hop itself.
        let session = ASWebAuthenticationSession(
            url: authorizeURL,
            callbackURLScheme: "polestar-explore"
        ) { @Sendable [weak self] callbackURL, error in
            Task { @MainActor in
                // A completed or cancelled session is released first, so this also guards against
                // a second delivery resuming the continuation twice.
                guard let self, self.session != nil else { return }
                if let callbackURL {
                    self.handleCallbackURL(callbackURL)
                } else if Self.isUserCancellation(error) {
                    // The user closed the sheet deliberately; that is not a failure to report.
                    self.cancel(with: CancellationError())
                } else if Self.isPresentationFailure(error), let authorizeURL = self.flow?.authorizeURL {
                    // The session could not present at all. Fall back to the user's own browser so
                    // this step is never blocked by the presentation layer.
                    await self.recordSessionFailure(error, reason: "presentation-unavailable")
                    self.session = nil
                    if !NSWorkspace.shared.open(authorizeURL) {
                        self.cancel(with: PolestarError.authenticationRequired(.callbackRejected))
                    }
                } else {
                    await self.recordSessionFailure(error, reason: "session-ended")
                    self.cancel(with: PolestarError.authenticationRequired(.callbackRejected))
                }
            }
        }
        session.presentationContextProvider = self
        // Decline the ephemeral session: this is the sign-in the user already has, not a private
        // window that makes them sign in again.
        session.prefersEphemeralWebBrowserSession = false
        self.session = session
        guard session.start() else {
            self.session = nil
            return false
        }
        return true
    }

    /// The sign-in window is otherwise invisible to support diagnostics: a session that never
    /// presents leaves no trace in the API log at all.
    private func recordSessionFailure(_ error: Error?, reason: String) async {
        await APIDiagnosticLogStore.shared.record(
            provider: .polestar, request: nil,
            operation: "Polestar command sign-in window",
            startedAt: Date(), error: error,
            semanticErrorType: "presenter:\(reason)")
    }

    func handleCallbackURL(_ url: URL) {
        guard flow?.accepts(url) == true, let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        flow = nil
        flowID = nil
        let activeSession = session
        session = nil
        activeSession?.cancel()
        continuation.resume(returning: url)
    }

    func cancel(with error: Error? = nil) {
        let activeSession = session
        session = nil
        activeSession?.cancel()
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        flow = nil
        flowID = nil
        continuation.resume(throwing: error ?? PolestarError.authenticationRequired(.callbackRejected))
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    /// The sign-in is always started from the Settings surface, so its window anchors the sheet.
    /// The empty anchor is the documented last resort for a windowless menu-bar app.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor()
    }

    private static func isUserCancellation(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == ASWebAuthenticationSessionErrorDomain
            && error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }

    /// Whether the session failed before it could present, which the user's own browser can still
    /// handle. Reported by `start()` itself or by the completion handler on a later run loop turn.
    private static func isPresentationFailure(_ error: Error?) -> Bool {
        guard let error = error as NSError?,
              error.domain == ASWebAuthenticationSessionErrorDomain,
              let code = ASWebAuthenticationSessionError.Code(rawValue: error.code) else { return false }
        return code == .presentationContextInvalid || code == .presentationContextNotProvided
    }
}
