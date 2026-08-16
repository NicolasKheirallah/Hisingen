import AppKit
import AuthenticationServices
import Foundation

@MainActor
final class VolvoSignInPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private var authSession: ASWebAuthenticationSession?

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        DispatchQueue.main.sync {
            NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) ?? NSWindow()
        }
    }

    func signIn(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        NSApp.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
            }
            self.pendingContinuation = continuation

            let session = ASWebAuthenticationSession(
                url: authorizeURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.authSession = nil
                    if let callbackURL {
                        self.handleCallbackURL(callbackURL)
                    } else if let error {
                        if let asError = error as? ASWebAuthenticationSessionError,
                           asError.code == .canceledLogin {
                            self.cancel(with: VolvoError.authenticationRequired(.callbackRejected))
                        } else {
                            self.cancel(with: error)
                        }
                    }
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session

            if !session.start() {
                NSWorkspace.shared.open(authorizeURL)
            }
        }
    }

    func handleCallbackURL(_ url: URL) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        authSession?.cancel()
        authSession = nil
        continuation.resume(returning: url)
    }

    func cancel(with error: Error? = nil) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        authSession?.cancel()
        authSession = nil
        continuation.resume(throwing: error ?? VolvoError.authenticationRequired(.callbackRejected))
    }
}


