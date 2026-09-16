import Foundation
import Testing

/// Drains queued MainActor hops (e.g. `Notifier` posting through a fresh `Task`) and waits
/// until the observed state has been stable for three consecutive checks. Used before both
/// positive and negative assertions so a regression cannot hide behind scheduler delay
/// (TESTS-11 discipline).
///
/// This is not a persistence helper. Persistence reads no longer need one:
/// `VehicleStateStore.save` writes the authoritative snapshot before it returns, and the
/// coalesced history passes wait behind `drainHistory()`. This helper survives because
/// `Notifier` and the provider fakes hop through the main actor, which no interface can await.
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
