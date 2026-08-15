import AppKit
import AuthenticationServices

@MainActor
final class VolvoSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var activeSession: ASWebAuthenticationSession?
    private var anchorWindow: NSWindow?
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    func signIn(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        NSApp.activate(ignoringOtherApps: true)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Volvo ID Authentication"
        window.center()
        window.orderFront(nil)
        anchorWindow = window

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingContinuation = continuation

            let session = ASWebAuthenticationSession(
                url: authorizeURL, callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                guard let self else { return }
                self.anchorWindow?.orderOut(nil)
                self.anchorWindow = nil
                self.activeSession = nil

                guard let continuation = self.pendingContinuation else { return }
                self.pendingContinuation = nil

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
                } else {
                    NSWorkspace.shared.open(authorizeURL)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.activeSession = session

            if !session.start() {
                NSWorkspace.shared.open(authorizeURL)
            }
        }
    }

    func handleCallbackURL(_ url: URL) {
        anchorWindow?.orderOut(nil)
        anchorWindow = nil
        activeSession?.cancel()
        activeSession = nil
        if let continuation = pendingContinuation {
            pendingContinuation = nil
            continuation.resume(returning: url)
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchorWindow ?? NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
        }
    }
}


