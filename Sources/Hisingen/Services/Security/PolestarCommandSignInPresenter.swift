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
    private var presentingForceLogin = false
    /// Dedicated anchor for the sign-in sheet. The Settings window is not one: it can close
    /// or churn mid-present, and a menu-bar (`LSUIElement`) app otherwise has no reliable
    /// anchor at all — the sheet then dismisses instantly with `presentationContextInvalid`,
    /// which looked like "the browser opens and shuts down". A tiny always-on-screen window
    /// keeps the sheet up for the whole sign-in.
    private var anchorWindow: NSWindow?

    private func presentationWindow() -> NSWindow {
        if let anchorWindow { return anchorWindow }
        let window = NSWindow(
            contentRect: NSRect(x: 20, y: 20, width: 60, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.02
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.makeKeyAndOrderFront(nil)
        anchorWindow = window
        return window
    }

    func signIn(authorizeURL: URL, forceLogin: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        cancel()
        let id = UUID()
        flowID = id
        flow = PolestarBrowserFlow(authorizeURL: authorizeURL,
                                  redirectURI: URL(string: "polestar-explore://explore.polestar.com")!)
        NSApp.activate(ignoringOtherApps: true)
        presentingForceLogin = forceLogin
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingContinuation = continuation
                if !startSystemSession(authorizeURL: authorizeURL, forceLogin: forceLogin) {
                    if forceLogin {
                        // The default browser would auto-consent with the existing account —
                        // exactly what a force-login run must not do. Fail loudly instead.
                        Self.recordSignInTrace("force-login:presentation-fallback-suppressed")
                        cancel(with: PolestarError.authenticationRequired(.callbackRejected))
                    } else if !NSWorkspace.shared.open(authorizeURL) {
                        cancel()
                    }
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
    nonisolated static func recordSignInTrace(_ reason: String) {
        Task {
            await APIDiagnosticLogStore.shared.record(
                provider: .polestar, request: nil,
                operation: "Polestar command sign-in window",
                startedAt: Date(), error: nil,
                semanticErrorType: reason)
        }
    }

    private func startSystemSession(authorizeURL: URL, forceLogin: Bool) -> Bool {
        Self.recordSignInTrace("presenter:starting")
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
                    return
                }
                // The decision is a total function and the switch is exhaustive, so every
                // callback-less end of the session reaches `cancel(with:)` and resumes the
                // continuation — a branch that only recorded a trace once hung the awaiting
                // `signIn` task here and wedged the coordinator's re-entrancy guard.
                switch Self.sessionEndOutcome(
                    isUserCancellation: Self.isUserCancellation(error),
                    isPresentationFailure: Self.isPresentationFailure(error),
                    hasAuthorizeURL: self.flow?.authorizeURL != nil,
                    forceLogin: self.presentingForceLogin
                ) {
                case .userCancellation:
                    // A user closing the sheet deliberately is not a failure — but a sheet
                    // that dismisses itself seconds after opening is indistinguishable from
                    // this path, so record it: that is how a second sign-in start (or a task
                    // cancel) shows up, and it used to be completely invisible.
                    await self.recordSessionFailure(error, reason: "dismissed-as-user-cancel")
                    self.cancel(with: CancellationError())
                case .presentationFallback:
                    // The session could not present at all. Fall back to the user's own browser
                    // so this step is never blocked by the presentation layer.
                    Self.recordSignInTrace("presenter:presentation-unavailable")
                    self.session = nil
                    if let authorizeURL = self.flow?.authorizeURL, !NSWorkspace.shared.open(authorizeURL) {
                        self.cancel(with: PolestarError.authenticationRequired(.callbackRejected))
                    }
                case .failure(let failure, let trace):
                    if let trace {
                        Self.recordSignInTrace(trace)
                    }
                    await self.recordSessionFailure(error, reason: "session-ended")
                    self.cancel(with: failure)
                }
            }
        }
        session.presentationContextProvider = self
        // Decline the ephemeral session by default: this is the sign-in the user already has,
        // not a private window that makes them sign in again. An explicit force-login run
        // (account switching) inverts it so the login page always shows.
        session.prefersEphemeralWebBrowserSession = forceLogin
        self.session = session
        guard session.start() else {
            Self.recordSignInTrace("presenter:start-failed")
            self.session = nil
            return false
        }
        Self.recordSignInTrace("presenter:presented")
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
        Self.recordSignInTrace("presenter:callback-received")
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

    /// Always the dedicated anchor window: deterministic, presentable on every space, and
    /// alive for the presenter's lifetime — unlike the Settings window, whose closure or
    /// re-creation used to tear the sheet down mid-sign-in.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationWindow()
    }

    private static func isUserCancellation(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == ASWebAuthenticationSessionErrorDomain
            && error.code == ASWebAuthenticationSessionError.canceledLogin.rawValue
    }

    /// How a callback-less end of the system session must be resolved. Total over its inputs
    /// and exhaustive at the call site: every outcome either resumes the continuation or keeps
    /// the flow alive in the user's own browser.
    enum SessionEndOutcome {
        /// The sheet was closed deliberately (or superseded by a newer flow) — a cancellation,
        /// not a failure to report.
        case userCancellation
        /// The system session never presented; the user's own browser takes over and the
        /// continuation stays pending until LaunchServices hands the redirect back.
        case presentationFallback
        /// Terminal: resume by throwing. `trace` names the diagnostic row the run leaves so a
        /// silent dismissal can never hide which path fired.
        case failure(PolestarError, trace: String?)
    }

    /// Maps a callback-less completion to its outcome. A force-login run must never take the
    /// browser fallback: the default browser would auto-consent with the stored account —
    /// exactly what the run exists to avoid — so its presentation failures fail loudly instead.
    nonisolated static func sessionEndOutcome(
        isUserCancellation: Bool,
        isPresentationFailure: Bool,
        hasAuthorizeURL: Bool,
        forceLogin: Bool
    ) -> SessionEndOutcome {
        if isUserCancellation { return .userCancellation }
        if isPresentationFailure {
            if forceLogin {
                return .failure(.authenticationRequired(.callbackRejected),
                                trace: "force-login requested but presentation failed; browser fallback suppressed")
            }
            if hasAuthorizeURL { return .presentationFallback }
        }
        return .failure(.authenticationRequired(.callbackRejected),
                        trace: forceLogin ? "session-ended-force-login" : nil)
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
