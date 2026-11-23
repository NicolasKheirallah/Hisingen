import Foundation

/// Runs async operations one at a time, in the order they were submitted.
///
/// An actor method that awaits is re-entered while it waits, so an actor alone does not make a
/// multi-step async operation exclusive. This queue chains each operation behind the previous
/// one's completion instead. It exists for rotate-on-use token refreshes: two overlapping
/// refreshes would both present the same stored token, and the identity provider honours only one.
actor SerialAsyncQueue {
    private var tail: Task<Void, Never>?

    func run<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task<T, any Error> {
            await previous?.value
            return try await operation()
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }
}
