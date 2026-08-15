import Foundation

final class VehicleStateStore {
    private let defaults: UserDefaults
    private let snapshotsKey = "cached_vehicle_snapshots_v1"
    private let baselinesKey = "charging_baselines_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func snapshot(for vin: String) -> VehicleState? {
        guard let snapshot = load([String: VehicleState].self, key: snapshotsKey)?[vin] else { return nil }
        guard Date().timeIntervalSince(snapshot.fetchedAt) <= 7 * 24 * 60 * 60 else {
            clear(vin: vin)
            return nil
        }
        return snapshot
    }

    func save(_ state: VehicleState) {
        var values = load([String: VehicleState].self, key: snapshotsKey) ?? [:]
        values[state.vin] = state.cacheableCopy
        store(values, key: snapshotsKey)
    }

    func baseline(for vin: String) -> ChargingBaseline? {
        guard let baseline = load([String: ChargingBaseline].self, key: baselinesKey)?[vin] else { return nil }
        guard let timestamp = baseline.sampledAt ?? baseline.vehicleReportedAt,
              Date().timeIntervalSince(timestamp) <= 7 * 24 * 60 * 60 else {
            var values = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
            values.removeValue(forKey: vin)
            store(values, key: baselinesKey)
            return nil
        }
        return baseline
    }

    func save(_ baseline: ChargingBaseline) {
        var values = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
        values[baseline.vin] = baseline
        store(values, key: baselinesKey)
    }

    func clear(vin: String? = nil) {
        if let vin {
            var snapshots = load([String: VehicleState].self, key: snapshotsKey) ?? [:]
            var baselines = load([String: ChargingBaseline].self, key: baselinesKey) ?? [:]
            snapshots.removeValue(forKey: vin)
            baselines.removeValue(forKey: vin)
            store(snapshots, key: snapshotsKey)
            store(baselines, key: baselinesKey)
        } else {
            defaults.removeObject(forKey: snapshotsKey)
            defaults.removeObject(forKey: baselinesKey)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }

    private func store<T: Encodable>(_ value: T, key: String) {
        if let data = try? encoder.encode(value) { defaults.set(data, forKey: key) }
    }
}

