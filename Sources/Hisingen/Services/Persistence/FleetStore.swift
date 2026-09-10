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

    func updateCars(_ cars: [CarSummary]) { carsByBrand[preferences.activeBrand] = cars }

    func retain(_ state: VehicleState) { snapshots[state.identity.vin] = state }

    func snapshot(for vin: String) -> VehicleState? {
        if let state = snapshots[vin] { return state }
        let state = stateStore.snapshot(for: vin)
        snapshots[vin] = state
        return state
    }

    func snapshot(activeState: VehicleState? = nil) -> FleetSnapshot {
        let configured = VehicleBrand.allCases.map { preferences.vin(for: $0) }
        let knownVINs = VehicleBrand.allCases.flatMap { carsByBrand[$0, default: []].map(\.vin) }
        for vin in knownVINs + configured where !vin.isEmpty {
            _ = snapshot(for: vin)
        }
        return FleetSnapshot(cars: carsByBrand[preferences.activeBrand, default: []],
                             configuredVINs: configured + knownVINs,
                             snapshots: snapshots, activeState: activeState)
    }

    /// Persistence is cleared by the session lifecycle before this in-memory invalidation.
    func forget(brand: VehicleBrand) {
        let removedVINs = Set(carsByBrand[brand, default: []].map(\.vin) + [preferences.vin(for: brand)])
        snapshots = snapshots.filter { !removedVINs.contains($0.key) && $0.value.model.brand != brand }
        carsByBrand[brand] = nil
    }
}
