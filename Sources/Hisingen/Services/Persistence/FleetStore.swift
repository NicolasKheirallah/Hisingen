import Foundation

/// A render-ready fleet. Live state takes precedence over retained and persisted snapshots.
struct FleetSnapshot {
    let cars: [CarSummary]
    let vehicles: [String]
    private let snapshots: [String: VehicleState]

    init(cars: [CarSummary] = [], configuredVINs: [String] = [],
         snapshots: [String: VehicleState] = [:], activeState: VehicleState? = nil) {
        self.cars = cars
        var values = snapshots
        if let activeState { values[activeState.identity.vin] = activeState }
        self.snapshots = values
        var seen = Set<String>()
        vehicles = (cars.map(\.vin) + configuredVINs + values.keys.sorted())
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func snapshot(for vin: String) -> VehicleState? { snapshots[vin] }

    func vehicles(orderedBy order: [String]) -> [String] {
        vehicles.sorted {
            let left = order.firstIndex(of: $0) ?? Int.max
            let right = order.firstIndex(of: $1) ?? Int.max
            return left == right ? $0 < $1 : left < right
        }
    }
}

/// Owns retained fleet snapshots and the persistence fallback used by every presentation.
@MainActor
final class FleetStore {
    private let stateStore: VehicleStateStore
    private let preferences: PreferencesStore
    private var carsByBrand: [VehicleBrand: [CarSummary]] = [:]
    private var snapshots: [String: VehicleState] = [:]

    init(stateStore: VehicleStateStore, preferences: PreferencesStore) {
        self.stateStore = stateStore
        self.preferences = preferences
    }

    func updateCars(_ cars: [CarSummary]) {
        preferences.rememberKnownVINs(cars.map(\.vin), for: preferences.activeBrand)
        let detached = preferences.detachedVehicleVINs(for: preferences.activeBrand)
        carsByBrand[preferences.activeBrand] = cars.filter { !detached.contains($0.vin.normalizedVIN) }
    }

    func retain(_ state: VehicleState) {
        guard !preferences.isVehicleDetached(state.identity.vin) else { return }
        snapshots[state.identity.vin] = state
    }

    func snapshot(for vin: String) -> VehicleState? {
        guard !preferences.isVehicleDetached(vin) else { return nil }
        if let state = snapshots[vin] { return state }
        let state = stateStore.snapshot(for: vin)
        snapshots[vin] = state
        return state
    }

    /// The VINs this app knows for one brand, without the vehicles the reader signed out of it.
    /// A connected account can name a vehicle the garage scan has not reached yet, and a scan can
    /// retain one the reader never selected; both belong here.
    func knownVINs(for brand: VehicleBrand) -> [String] {
        var values = preferences.knownVINs(for: brand)
        values += carsByBrand[brand, default: []].map(\.vin)
        let selected = preferences.vin(for: brand)
        if !selected.isEmpty { values.append(selected) }
        values += snapshots.values.filter { $0.model.brand == brand }.map(\.identity.vin)
        let detached = preferences.detachedVehicleVINs(for: brand)
        var seen = Set<String>()
        return values
            .map { $0.normalizedVIN }
            .filter { !$0.isEmpty && !detached.contains($0) && seen.insert($0).inserted }
    }

    func snapshot(activeState: VehicleState? = nil) -> FleetSnapshot {
        let detached = Set(VehicleBrand.allCases.flatMap { preferences.detachedVehicleVINs(for: $0) })
        let configured = VehicleBrand.allCases
            .map { preferences.vin(for: $0) }
            .filter { !detached.contains($0.normalizedVIN) }
        let persistedVINs = VehicleBrand.allCases.flatMap { preferences.knownVINs(for: $0) }
        let knownVINs = (VehicleBrand.allCases.flatMap { carsByBrand[$0, default: []].map(\.vin) }
            + persistedVINs)
            .filter { !detached.contains($0.normalizedVIN) }
        for vin in knownVINs + configured where !vin.isEmpty {
            _ = snapshot(for: vin)
        }
        let visibleSnapshots = snapshots.filter { !detached.contains($0.key.normalizedVIN) }
        let visibleActiveState = activeState.flatMap {
            detached.contains($0.identity.vin.normalizedVIN) ? nil : $0
        }
        return FleetSnapshot(cars: carsByBrand[preferences.activeBrand, default: []],
                             configuredVINs: configured + knownVINs,
                             snapshots: visibleSnapshots, activeState: visibleActiveState)
    }

    /// Drops one vehicle from the in-memory fleet, for a per-vehicle sign-out. Persistence is
    /// cleared by `VehicleStateStore.clear` before this.
    func forget(vin: String) {
        let key = vin.normalizedVIN
        guard !key.isEmpty else { return }
        snapshots.removeValue(forKey: key)
        for brand in VehicleBrand.allCases {
            carsByBrand[brand]?.removeAll { $0.vin.normalizedVIN == key }
        }
    }

    /// Persistence is cleared by the session lifecycle before this in-memory invalidation.
    func forget(brand: VehicleBrand) {
        let removedVINs = Set(carsByBrand[brand, default: []].map(\.vin) + [preferences.vin(for: brand)])
        snapshots = snapshots.filter { !removedVINs.contains($0.key) && $0.value.model.brand != brand }
        carsByBrand[brand] = nil
        preferences.clearKnownVINs(for: brand)
    }
}

extension FleetStore: VehicleMemoryCaching {
    /// Drops retained snapshots for the erased vehicles, or all of them. `forget(brand:)` only
    /// covers the sign-out path and is keyed by brand; without this an erased vehicle still
    /// renders from the retained snapshot until relaunch. The next `snapshot(for:)` reads the
    /// persistence tier instead, which the erase has already cleared. `carsByBrand` is
    /// brand-keyed rather than VIN-keyed and is left to `forget(brand:)`.
    func dropCachedVehicles(_ scope: VehicleScope) {
        snapshots = snapshots.filter { !scope.covers($0.key) }
    }

    /// Retained snapshots are all this store holds, so the snapshot-only drop is the same drop.
    func dropCachedSnapshots(_ scope: VehicleScope) {
        dropCachedVehicles(scope)
    }
}
