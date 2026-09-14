import Foundation

@MainActor
final class PopoverRefreshCoalescer {
    static let defaultDelay: Duration = .milliseconds(200)

    private let delay: Duration
    private let refresh: @MainActor () -> Void
    private var pendingTask: Task<Void, Never>?

    init(
        delay: Duration = defaultDelay,
        refresh: @escaping @MainActor () -> Void
    ) {
        self.delay = delay
        self.refresh = refresh
    }

    func schedule() {
        guard pendingTask == nil else { return }
        pendingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            pendingTask = nil
            refresh()
        }
    }
}
