import AppKit
import Foundation

@MainActor
final class VolvoSignInPresenter: NSObject {
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    func signIn(authorizeURL: URL, callbackScheme: String) async throws -> URL {
        NSApp.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
            }
            self.pendingContinuation = continuation
            NSWorkspace.shared.open(authorizeURL)
        }
    }

    func handleCallbackURL(_ url: URL) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: url)
    }

    func cancel() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
    }
}


