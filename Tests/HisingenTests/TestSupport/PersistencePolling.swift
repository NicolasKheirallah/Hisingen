import Foundation
import Testing

/// `VehicleHistoryRecorder.record` hands its storage pass to a detached utility task
/// (PERSIST-06/07), so a read right after `VehicleStateStore.save` / `record` can race the
/// write. Poll the database until `condition` holds or the timeout lapses; the returned
/// Bool lets callers turn "never appeared" into an explicit assertion failure instead of a
/// confusing secondary mismatch downstream.
@MainActor
func awaitStored(
    timeout: TimeInterval = 5,
    pollInterval: Duration = .milliseconds(5),
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { return false }
        try? await Task.sleep(for: pollInterval)
    }
    return true
}

/// Drains queued MainActor hops (e.g. `Notifier` posting through a fresh `Task`) and waits
/// until the observed state has been stable for three consecutive checks. Used before both
/// positive and negative assertions so a regression cannot hide behind scheduler delay
/// (TESTS-11 discipline).
@MainActor
func awaitStable(
    stabilityChecks: Int = 3,
    pollInterval: Duration = .milliseconds(5),
    _ observation: @MainActor () async -> Int
) async {
    var stable = 0
    var last = await observation()
    while stable < stabilityChecks {
        try? await Task.sleep(for: pollInterval)
        let current = await observation()
        if current == last {
            stable += 1
        } else {
            stable = 0
            last = current
        }
    }
}
