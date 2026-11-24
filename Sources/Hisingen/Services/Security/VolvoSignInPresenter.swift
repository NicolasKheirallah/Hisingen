import AppKit
import Foundation

@MainActor
final class VolvoSignInPresenter: NSObject {
    private let logger = AppLog.logger("volvo-sign-in")
    /// The round trip awaiting its callback. The id names this call, so a timeout armed by an
    /// earlier call can tell that the continuation now pending is not the one it was armed for.
    private var pending: (id: UUID, continuation: CheckedContinuation<URL, Error>)?
    private let openInBrowser: @MainActor (URL) -> Bool
    private let callbackTimeout: TimeInterval
    private let sleep: @MainActor (TimeInterval) async throws -> Void

    /// `openInBrowser` and `sleep` are seams for tests: the callback gate can be exercised
    /// without launching the user's browser, and a timeout can be fired on demand instead of
    /// waiting out the wall clock.
    init(callbackTimeout: TimeInterval = 300,
         openInBrowser: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
         sleep: @escaping @MainActor (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.openInBrowser = openInBrowser
        self.callbackTimeout = callbackTimeout
        self.sleep = sleep
        super.init()
    }

    /// Whether a browser round trip is still waiting for its callback.
    var isWaitingForCallback: Bool { pending != nil }

    func signIn(authorizeURL: URL, callbackScheme _: String) async throws -> URL {
        // Production always has an application; a unit test does not.
        _ = NSApp?.activate(ignoringOtherApps: true)

        return try await withCheckedThrowingContinuation { continuation in
            if let existing = self.pending {
                self.pending = nil
                existing.continuation.resume(throwing: CancellationError())
            }
            let id = UUID()
            self.pending = (id, continuation)

            let opened = self.openInBrowser(authorizeURL)
            if !opened {
                self.pending = nil
                continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
            } else {
                // Browser handoff waits indefinitely otherwise: a closed tab or lost
                // routing wedges every future press behind the re-entrancy guard. The timeout
                // belongs to this call alone: once this round trip has ended, a later sign-in's
                // continuation must not be what it finds pending.
                let timeout = self.callbackTimeout
                let sleep = self.sleep
                Task { @MainActor [weak self] in
                    try? await sleep(timeout)
                    guard let self, let pending = self.pending, pending.id == id else { return }
                    self.pending = nil
                    pending.continuation.resume(throwing: VolvoError.authenticationRequired(.callbackRejected))
                }
            }
        }
    }

    func cancel() {
        guard let pending else { return }
        self.pending = nil
        pending.continuation.resume(throwing: CancellationError())
    }

    /// Only the registered Volvo callback is resumed to the token exchange. A stray or crafted
    /// `hisingen://` URL is refused here as well as at the exchange, and the refusal names the
    /// component that did not match, never the query that carries the authorization code.
    func handleCallbackURL(_ url: URL) {
        if let refusal = VolvoCallback.refusal(for: url) {
            logger.notice("\(refusal.logMessage, privacy: .public)")
            return
        }
        guard let pending else {
            // A registered callback with nothing waiting means the round trip was already
            // finished, cancelled, or timed out. Saying so beats a silent drop.
            logger.notice("Volvo sign-in callback arrived with no sign-in waiting for it")
            return
        }
        self.pending = nil
        pending.continuation.resume(returning: url)
    }

}
