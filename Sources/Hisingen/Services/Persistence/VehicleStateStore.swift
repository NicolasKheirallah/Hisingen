import Foundation
import OSLog

/// Main-actor isolated because it holds no lock of its own: every mutation is a
/// read-modify-write over a `UserDefaults`-backed dictionary, which two concurrent callers
/// would interleave and lose writes from. Both real callers (`RefreshCoordinator`, `Notifier`)
/// are already `@MainActor`; this makes the requirement compiler-enforced rather than assumed.
@MainActor
final class VehicleStateStore {
    private let defaults: UserDefaults
    private let snapshotsKey = "cached_vehicle_snapshots_v1"
    private let baselinesKey = "charging_baselines_v1"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let logger = AppLog.logger("state-store")

    let database: VehicleDatabase
    private let preferences: PreferencesStore

    init(defaults: UserDefaults = .standard, database: VehicleDatabase,
         preferences: PreferencesStore? = nil) {
        self.defaults = defaults
        self.database = database
        self.preferences = preferences ?? PreferencesStore(defaults: defaults)
    }

    func snapshot(for vin: String) -> VehicleState? {
        if let sqliteSnapshot = database.loadSnapshot(for: vin) {
            return sqliteSnapshot
        }
        guard var snapshot = load([String: VehicleState].self, key: snapshotsKey)?[vin] else { return nil }
        guard Date().timeIntervalSince(snapshot.fetchedAt) <= 7 * 24 * 60 * 60 else {
            clear(vin: vin)
            return nil
        }
        snapshot.isCachedSnapshot = true
        return snapshot
    }

    func save(_ state: VehicleState) {
        database.saveSnapshot(state)

        if let airQuality = state.airQuality {
            database.recordAirQuality(
                vin: state.vin,
                airQualityIndex: airQuality.airQualityIndex.map(Double.init),
                particulateMatter25: airQuality.particulateMatter25.map(Double.init),
                particulateMatter10: airQuality.particulateMatter10.map(Double.init),
                filterRemainingPercent: airQuality.filterRemainingPercent.map(Double.init)
            )
        }

        if state.odometerKm != nil || state.tripMeterManualKm != nil || state.tripMeterAutomaticKm != nil {
            let persistLocation = preferences.persistLocationHistory
            database.recordTelemetry(
                vin: state.vin, odometerKm: state.odometerKm.map(Double.init),
                tripManualKm: state.tripMeterManualKm,
                tripAutoKm: state.tripMeterAutomaticKm,
                avgConsumption: state.batteryDiagnostics?.averageConsumption
                    ?? state.averageFuelConsumptionLPer100Km,
                consumptionUnit: state.batteryDiagnostics?.averageConsumption != nil
                    ? "kwh"
                    : (state.averageFuelConsumptionLPer100Km != nil ? "l" : nil),
                ambientTempC: state.weather?.temperatureCelsius,
                latitude: persistLocation ? state.location?.latitude : nil,
                longitude: persistLocation ? state.location?.longitude : nil
            )
        }

        if let batteryPct = state.batteryPercentage {
            // Connectivity trend (wake reason / signal / network) — change-gated inside.
            database.recordConnectivity(
                vin: state.vin,
                networkType: state.connectivity?.networkType,
                signalBars: state.connectivity?.signalBars,
                wakeReason: state.connectivity?.wakeReason
            )
            // Cabin temperature trend — digital-twin platforms only; no-op when absent.
            database.recordCabinClimate(
                vin: state.vin,
                interiorCelsius: state.climateStatus?.interiorTemperatureCelsius,
                requestedCelsius: state.climateStatus?.requestedTemperatureCelsius
            )
            let sessions = database.recentChargingSessions(for: state.vin, limit: 20)
                .map { $0.toDomainSession(database: database) }
            let previousHealth = database.batteryHealthHistory(for: state.vin, limit: 1).first
                .map { BatteryHealthPriorEstimate(stateOfHealthPercent: $0.stateOfHealthPct, timestamp: $0.timestamp) }
            if let odo = state.odometerKm, let estimate = BatteryHealthEstimator.estimate(
                state: state, chargingSessions: sessions,
                specification: preferences.vehicleSpecificationOverride(for: state.vin),
                previous: previousHealth
            ) {
                database.recordBatteryHealthMilestone(
                    vin: state.vin, odometerKm: Double(odo),
                    sohPct: estimate.stateOfHealthPercent,
                    degPct: estimate.degradationPercent,
                    usableKwh: estimate.estimatedUsableCapacityKwh
                )
            }
            let powerKw = state.chargingPowerWatts.map { Double($0) / 1000.0 }
            let voltage = state.chargingVoltageVolts.map(Double.init)
            let current = state.chargingCurrentAmps.map(Double.init)

            if state.chargingState.isActivelyCharging {
                let session = database.activeChargingSession(for: state.vin)
                let sessionId: String
                if let session {
                    sessionId = session.id
                } else {
                    let locName: String? = {
                        guard preferences.persistLocationHistory else { return nil }
                        guard let loc = state.location, let lat = loc.latitude, let lon = loc.longitude else { return nil }
                        return String(format: "%.4f°, %.4f°", lat, lon)
                    }()
                    sessionId = database.startChargingSession(vin: state.vin, startSoc: batteryPct, location: locName)
                }
                database.recordChargingSample(
                    sessionId: sessionId, vin: state.vin, soc: batteryPct,
                    powerKw: powerKw, voltage: voltage, current: current,
                    chargingType: state.chargingType.rawValue
                )
            } else if let active = database.activeChargingSession(for: state.vin) {
                let samples = database.chargingSamples(for: active.id)
                let peak = samples.compactMap(\.powerKw).max() ?? (powerKw ?? 0.0)
                let avg = samples.isEmpty ? peak : (samples.compactMap(\.powerKw).reduce(0, +) / Double(samples.count))
                let socDelta = max(0, batteryPct - active.startSoc)
                let capacity = preferences.vehicleSpecificationOverride(for: state.vin)?.usableBatteryCapacityKwh
                    ?? state.configuredUsableBatteryCapacityKwh
                let energy = (socDelta / 100.0) * capacity
                database.completeChargingSession(
                    id: active.id, endSoc: batteryPct, energyDeliveredKwh: energy,
                    peakPowerKw: peak, averagePowerKw: avg
                )
            }
        }

        // SQLite is the authoritative snapshot store (`database.saveSnapshot` above). The
        // UserDefaults mirror is no longer written: it previously re-encoded the entire
        // per-VIN dictionary on every save — an O(all-vehicles) plist rewrite per refresh —
        // and was only ever a legacy fallback for installs predating SQLite.
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
        database.wipeAll(for: vin)
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
        do {
            return try decoder.decode(type, from: data)
        } catch {
            logger.error("Could not decode persisted state for key \(key, privacy: .public): \(error, privacy: .public)")
            return nil
        }
    }

    private func store<T: Encodable>(_ value: T, key: String) {
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            logger.error("Could not encode persisted state for key \(key, privacy: .public): \(error, privacy: .public)")
        }
    }
}
