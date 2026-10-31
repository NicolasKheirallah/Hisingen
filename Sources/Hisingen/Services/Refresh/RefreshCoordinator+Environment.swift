import AppKit
import Foundation

extension RefreshCoordinator {
    func networkDidChange(_ available: Bool) {
        let restored = available && !networkAvailable
        networkAvailable = available
        if !available {
            cancelCurrentWork(preservingCommandConfirmation: true)
        } else if restored && !sleeping {
            if deferRecoveryForRateLimit() { publishDiagnostics(); return }
            resumeCommandConfirmationIfNeeded()
            if sessionReady { refresh(trigger: .networkRestored) }
            else { beginSession(preferredVIN: preferences.vin.nilIfEmpty) }
        }
        publishDiagnostics()
    }

    func systemWillSleep() {
        sleeping = true
        cancelCurrentWork(preservingCommandConfirmation: true)
    }

    func systemDidWake() {
        sleeping = false
        guard networkAvailable else {
            publishDiagnostics()
            return
        }
        if deferRecoveryForRateLimit() { publishDiagnostics(); return }
        resumeCommandConfirmationIfNeeded()
        if sessionReady { refresh(trigger: .wake) }
        else { beginSession(preferredVIN: preferences.vin.nilIfEmpty) }
    }

    private func deferRecoveryForRateLimit() -> Bool {
        guard let until = rateLimitedUntil, until > now() else { return false }
        schedule(after: until.timeIntervalSince(now()), retrySession: !sessionReady, addsJitter: false)
        return true
    }

    func installSystemObservers() {
        observerTokens.append(addMainActorObserver(for: NSWorkspace.willSleepNotification) { coordinator in
            coordinator.systemWillSleep()
        })
        observerTokens.append(addMainActorObserver(for: NSWorkspace.didWakeNotification) { coordinator in
            coordinator.systemDidWake()
        })
    }

    /// `MainActor.assumeIsolated` is a runtime assertion, not a compiler-checked guarantee: it
    /// traps if the notification is ever delivered off the main thread. What makes it sound is
    /// `queue: .main` on the registration – so the two must never drift apart. Binding them
    /// together here means the delivery queue cannot be changed independently of the
    /// assumption that depends on it. The body stays synchronous deliberately: `willSleep`
    /// must cancel in-flight work *before* the machine suspends, which an async hop onto the
    /// main actor could miss.
    private func addMainActorObserver(
        for name: Notification.Name,
        handler: @escaping @MainActor @Sendable (RefreshCoordinator) -> Void
    ) -> any NSObjectProtocol {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
    }
}
