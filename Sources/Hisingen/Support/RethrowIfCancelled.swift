import Foundation

/// For a `catch` block that must not treat cancellation as a failure: rethrows when the task
/// was cancelled, or when `error` is itself a `CancellationError` raised below.
func rethrowIfCancelled(_ error: any Error) throws {
    try Task.checkCancellation()
    if error is CancellationError { throw error }
}
