import Foundation

/// An in-memory holder of per-VIN state: the tier neither SQL nor `UserDefaults` can reach by
/// name. Erasing a vehicle has to drop these too, or a snapshot the reader just deleted keeps
/// answering – a brand name in a notification, a parking location on a card – from RAM.
@MainActor
protocol VehicleMemoryCaching: AnyObject {
    /// Drops everything filed under the scope's VIN; a fleet-wide scope drops every vehicle's.
    func dropCachedVehicles(_ scope: VehicleScope)

    /// Drops only what a held snapshot contributes. A location erase is the scope that needs it:
    /// the snapshot still carries the coordinates just deleted, while a notification latch, a
    /// badge count or a persisted dedupe mirror is not location state and must survive.
    func dropCachedSnapshots(_ scope: VehicleScope)
}

/// The registered in-memory tiers.
///
/// Registration is separate from construction because the holders – `Notifier` and
/// `FleetStore` – are built from the state store that builds the eraser, so an initializer
/// edge would be a cycle; and because Settings drives an eraser of its own, so state kept on
/// one instance would be invisible to the other. Members are held weakly: they are long-lived
/// objects owned by the app, and a registry that kept them alive would keep alive the caches
/// it exists to drop.
@MainActor
final class VehicleMemoryCacheRegistry {
    static let shared = VehicleMemoryCacheRegistry()

    private final class WeakCache {
        weak var value: (any VehicleMemoryCaching)?
        init(_ value: any VehicleMemoryCaching) { self.value = value }
    }

    private var caches: [WeakCache] = []

    func register(_ cache: any VehicleMemoryCaching) {
        pruneReleased()
        guard !caches.contains(where: { $0.value === cache }) else { return }
        caches.append(WeakCache(cache))
    }

    func drop(_ scope: VehicleScope) {
        pruneReleased()
        for cache in caches { cache.value?.dropCachedVehicles(scope) }
    }

    /// The snapshot-only counterpart of `drop(_:)`, for the scope that invalidates positions
    /// without ending anything.
    func dropSnapshots(_ scope: VehicleScope) {
        pruneReleased()
        for cache in caches { cache.value?.dropCachedSnapshots(scope) }
    }

    private func pruneReleased() {
        caches.removeAll { $0.value == nil }
    }
}
