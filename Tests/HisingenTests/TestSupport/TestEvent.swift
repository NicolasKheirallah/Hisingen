import Foundation

/// Event waits are bounded and cancellation-aware, including when the producer never responds.
@MainActor
final class TestEvent<Value: Sendable> {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Value, Error>
        let deadline: Task<Void, Never>
    }
    private var buffered: [Value] = []
    private var waiters: [Waiter] = []

    func yield(_ value: Value) {
        guard !waiters.isEmpty else { buffered.append(value); return }
        let waiter = waiters.removeFirst()
        waiter.deadline.cancel()
        waiter.continuation.resume(returning: value)
    }

    func next(timeout: Duration = .seconds(10), onWait: (() -> Void)? = nil) async throws -> Value {
        try Task.checkCancellation()
        if !buffered.isEmpty { return buffered.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.fail(id, error: TestEventTimeout())
                }
                waiters.append(Waiter(id: id, continuation: continuation, deadline: deadline))
                onWait?()
            }
        } onCancel: {
            Task { @MainActor in self.fail(id, error: CancellationError()) }
        }
    }

    func removePending() { buffered.removeAll() }

    func cancel() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.deadline.cancel()
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    private func fail(_ id: UUID, error: any Error) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.deadline.cancel()
        waiter.continuation.resume(throwing: error)
    }
}

struct TestEventTimeout: Error {}
