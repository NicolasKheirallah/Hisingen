import AppKit
import Foundation

@MainActor
final class VolvoSignInPresenter: NSObject {
    private let logger = AppLog.logger("volvo-sign-in")
    private var pendingContinuation: CheckedContinuation<URL, Error>?
    private let openInBrowser: @MainActor (URL) -> Bool

    /// `openInBrowser` is a seam for tests: the callback gate can be exercised without launching
    /// the user's browser.
    init(openInBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }) {
        self.openInBrowser = openInBrowser
        super.init()
    }

    /// Whether a browser round trip is still waiting for its callback.
    var isWaitingForCallback: Bool { pendingContinuation != nil }

    func signIn(authorizeURL: URL, callbackScheme _: String) async throws -> URL {
        // Production always has an application; a unit test does not.
        _ = NSApp?.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pendingContinuation {
                self.pendingContinuation = nil
                existing.resume(throwing: CancellationError())
            }
            self.pendingContinuation = continuation

            let opened = self.openInBrowser(authorizeURL)
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

    /// Only the registered Volvo callback is resumed to the token exchange. A stray or crafted
    /// `hisingen://` URL is refused here as well as at the exchange, and the refusal names the
    /// component that did not match, never the query that carries the authorization code.
    func handleCallbackURL(_ url: URL) {
        if let refusal = VolvoCallback.refusal(for: url) {
            logger.notice("\(refusal.logMessage, privacy: .public)")
            return
        }
        guard let continuation = pendingContinuation else {
            // A registered callback with nothing waiting means the round trip was already
            // finished, cancelled, or timed out. Saying so beats a silent drop.
            logger.notice("Volvo sign-in callback arrived with no sign-in waiting for it")
            return
        }
        pendingContinuation = nil
        continuation.resume(returning: url)
    }

}
