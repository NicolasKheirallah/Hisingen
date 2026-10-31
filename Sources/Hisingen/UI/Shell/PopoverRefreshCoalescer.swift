import Foundation

@MainActor
final class PopoverRefreshCoalescer {
    static let defaultDelay: Duration = .milliseconds(200)

    private let delay: Duration
    /// The wait before a coalesced refresh. `Task.sleep` in the app; a controllable sleeper in tests.
    private let sleep: @Sendable (Duration) async throws -> Void
    private let refresh: @MainActor () -> Void
    private var pendingTask: Task<Void, Never>?

    init(
        delay: Duration = defaultDelay,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        refresh: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.sleep = sleep
        self.refresh = refresh
    }

    func schedule() {
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await sleep(delay)
            } catch {
                return
            }
            pendingTask = nil
            refresh()
        }
    }
}
