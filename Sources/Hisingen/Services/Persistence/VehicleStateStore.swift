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
    private let chargingSessionEngine: ChargingSessionEngine

    init(defaults: UserDefaults = .standard, database: VehicleDatabase,
         preferences: PreferencesStore? = nil) {
        self.defaults = defaults
        self.database = database
        self.preferences = preferences ?? PreferencesStore(defaults: defaults)
        self.chargingSessionEngine = ChargingSessionEngine(database: database)
    }

    func snapshot(for vin: String) -> VehicleState? {
        if let sqliteSnapshot = database.loadSnapshot(for: vin) {
            return sqliteSnapshot
        }
        guard let snapshot = load([String: VehicleState].self, key: snapshotsKey)?[vin] else { return nil }
        guard Date().timeIntervalSince(snapshot.fetchedAt) <= 7 * 24 * 60 * 60 else {
            clear(vin: vin)
            return nil
        }
        // Legacy installations stored complete snapshots in UserDefaults. Migrate the entry
        // once into SQLite, which is now authoritative, but never carry forward sensitive
        // live fields (location, owner name, registration) from that older representation.
        // This is both a schema migration and a privacy boundary for caches written by older
        // versions of the app.
        let sanitized = snapshot.cacheableCopy
        database.saveSnapshot(sanitized)
        var legacySnapshots = load([String: VehicleState].self, key: snapshotsKey) ?? [:]
        legacySnapshots.removeValue(forKey: vin)
        store(legacySnapshots, key: snapshotsKey)
        var migrated = sanitized
        migrated.isCachedSnapshot = true
        return migrated
    }

    func save(_ state: VehicleState) {
        database.saveSnapshot(state)

        // Cabin AQI comes from Polestar's GetPreCleaning service. Do not persist a value on
        // Volvo snapshots even if a stale/imported payload happens to carry that field.
        if !state.isVolvo, let airQuality = state.airQuality {
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
            let capacity = preferences.vehicleSpecificationOverride(for: state.vin)?.usableBatteryCapacityKwh
                ?? state.configuredUsableBatteryCapacityKwh
            if preferences.storeChargingHistory {
                database.repairLegacyChargingSessions(
                    for: state.vin, usableCapacityKwh: capacity
                )
            }
            let locationName: String? = {
                guard preferences.persistLocationHistory else { return nil }
                guard let location = state.location,
                      let latitude = location.latitude,
                      let longitude = location.longitude else { return nil }
                return String(format: "%.4f°, %.4f°", latitude, longitude)
            }()
            chargingSessionEngine.ingest(
                ChargingSessionObservation(
                    vin: state.vin, timestamp: state.fetchedAt, soc: batteryPct,
                    chargingState: state.chargingState,
                    chargerConnection: state.chargerConnection,
                    powerKw: state.chargingPowerWatts.map { Double($0) / 1_000 },
                    voltageVolts: state.chargingVoltageVolts.map(Double.init),
                    currentAmps: state.chargingCurrentAmps.map(Double.init),
                    chargingType: state.chargingType,
                    targetSoc: state.chargeTargetPercentage.map(Double.init)
                ),
                configuration: ChargingSessionEngineConfiguration(
                    usableCapacityKwh: capacity,
                    tariffPricePerKwh: preferences.electricityPricePerKwh,
                    nightTariffEnabled: preferences.nightTariffEnabled,
                    nightTariffPricePerKwh: preferences.nightElectricityPricePerKwh,
                    nightTariffStartHour: preferences.nightTariffStartHour,
                    nightTariffEndHour: preferences.nightTariffEndHour,
                    currencySymbol: preferences.currencySymbol,
                    locationName: locationName
                ),
                recordingEnabled: preferences.storeChargingHistory
            )
            let sessions = database.recentChargingSessions(for: state.vin, limit: 20)
                .map { $0.toDomainSession(database: database, usableCapacityKwh: capacity) }
                .filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
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

    /// Forgets a vehicle's cached snapshot and charging baseline. Durable SQLite history
    /// (charging sessions, telemetry, battery health, fuel entries…) is kept unless
    /// `eraseHistory` is set: the sign-out path passes the user's Settings → Privacy & Data
    /// choice, while the deliberate "Erase local vehicle data" action wipes directly.
    func clear(vin: String? = nil, eraseHistory: Bool = false) {
        if eraseHistory {
            database.wipeAll(for: vin)
        } else if let vin {
            database.deleteSnapshot(for: vin)
        } else {
            database.deleteAllSnapshots()
        }
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
