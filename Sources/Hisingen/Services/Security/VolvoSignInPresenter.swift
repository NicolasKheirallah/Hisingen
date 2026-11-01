import AppKit
import Foundation

@MainActor
final class VolvoSignInPresenter: NSObject {
    private var pendingContinuation: CheckedContinuation<URL, Error>?

    func signIn(authorizeURL: URL, callbackScheme _: String) async throws -> URL {
        NSApp.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: CancellationError())
            }
            self.pendingContinuation = continuation

            let opened = NSWorkspace.shared.open(authorizeURL)
            if !opened {
                self.pendingContinuation = nil
                continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
            } else {
                // Browser handoff waits indefinitely otherwise: a closed tab or lost
                // routing wedges every future press behind the re-entrancy guard.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(300))
                    guard let self, self.pendingContinuation != nil else { return }
                    self.pendingContinuation = nil
                    continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
                }
            }
        }
    }

    func cancel() {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(throwing: CancellationError())
    }

    /// Only URLs matching Volvo's OAuth callback are accepted; strays are ignored
    /// so a forged/mistyped `hisingen://` URL cannot break the genuine sign-in.
    func handleCallbackURL(_ url: URL) {
        guard let continuation = pendingContinuation else { return }
        let scheme = url.scheme?.lowercased()
        guard scheme == "hisingen" || scheme == "https" else { return }
        if scheme == "hisingen" {
            guard url.host?.lowercased() == "oauth",
                  url.path.lowercased().hasPrefix("/volvo/callback") else { return }
        }
        pendingContinuation = nil
        continuation.resume(returning: url)
    }

}
