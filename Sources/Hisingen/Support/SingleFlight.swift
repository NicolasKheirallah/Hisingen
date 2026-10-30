import Foundation

/// Shares one in-flight `Task` per key.
///
/// The table stays in the owning actor. Only the synchronous `join` and `finish` touch it, and
/// callers await `task.value` between the two, so the actor never holds the table across a
/// suspension point.
enum SingleFlight {
    /// Returns the request already running for `key`, or starts one with `start`.
    static func join<Key: Hashable & Sendable, Value: Sendable>(
        _ key: Key,
        in table: inout [Key: PolestarInFlightRequest<Value>],
        start: () -> Task<Value, Error>
    ) -> PolestarInFlightRequest<Value> {
        if let existing = table[key] { return existing }
        let request = PolestarInFlightRequest(id: UUID(), task: start())
        table[key] = request
        return request
    }

    /// Clears `key` once `request` has completed. A newer flight under the same key stays put.
    static func finish<Key: Hashable & Sendable, Value: Sendable>(
        _ key: Key,
        _ request: PolestarInFlightRequest<Value>,
        in table: inout [Key: PolestarInFlightRequest<Value>]
    ) {
        if table[key]?.id == request.id { table[key] = nil }
    }
}
