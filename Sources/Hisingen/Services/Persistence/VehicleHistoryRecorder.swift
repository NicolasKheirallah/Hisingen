import Foundation

/// Owns the complete persistence workflow for one fresh vehicle snapshot.
///
/// Callers provide a domain snapshot. This module decides which cache, activity, telemetry,
/// charging, air-quality, connectivity, climate, and battery-health records that observation
/// implies. Keeping those decisions together prevents a new history stream from being wired
/// into only some refresh paths or applied after the snapshot it must compare against.
@MainActor
final class VehicleHistoryRecorder {
    private let database: VehicleDatabase
    private let preferences: PreferencesStore
    private let writer: Writer
    private var parkedChargeLossDetector = ParkedChargeLossDetector()

    init(
        database: VehicleDatabase,
        preferences: PreferencesStore,
        beforePersist: (@Sendable () -> Void)? = nil
    ) {
        self.database = database
        self.preferences = preferences
        self.writer = Writer(beforePersist: beforePersist)
    }

    /// Main-actor-owned preference values resolved once per observation so the storage pass
    /// can run detached without capturing the non-Sendable `PreferencesStore`.
    private struct RecordingInputs: Sendable {
        var persistLocationHistory: Bool
        var storeChargingHistory: Bool
        var specification: VehicleSpecificationOverride?
        var tariffPricePerKwh: Double
        var nightTariffEnabled: Bool
        var nightTariffPricePerKwh: Double
        var nightTariffStartHour: Int
        var nightTariffEndHour: Int
        var currencySymbol: String
    }

    private struct RecordingRequest: Sendable {
        let state: VehicleState
        let parkedChargeLoss: VehicleActivity?
        let inputs: RecordingInputs
        let database: VehicleDatabase
    }

    /// One long-lived utility queue replaces a detached task per observation. Pending values
    /// coalesce by VIN, while distinct vehicles retain FIFO order. This bounds memory when a
    /// dashboard read or another writer temporarily occupies SQLite.
    private final class Writer: @unchecked Sendable {
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.hisingen.history-writer", qos: .utility)
        private var pending: [String: RecordingRequest] = [:]
        private var order: [String] = []
        private var draining = false
        private var idleWaiters: [CheckedContinuation<Void, Never>] = []
        private let beforePersist: (@Sendable () -> Void)?

        init(beforePersist: (@Sendable () -> Void)?) {
            self.beforePersist = beforePersist
        }

        func enqueue(_ request: RecordingRequest) {
            let vin = request.state.identity.vin
            lock.lock()
            if pending[vin] == nil { order.append(vin) }
            pending[vin] = request
            let shouldStart = !draining
            if shouldStart { draining = true }
            lock.unlock()
            if shouldStart {
                // The queued drain owns the writer until every accepted observation lands.
                // A short-lived VehicleStateStore may be released immediately after `save`.
                queue.async { self.drain() }
            }
        }

        func waitUntilIdle() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if !draining && order.isEmpty {
                    lock.unlock()
                    continuation.resume()
                } else {
                    idleWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func drain() {
            while true {
                lock.lock()
                guard let vin = order.first else {
                    draining = false
                    let waiters = idleWaiters
                    idleWaiters.removeAll()
                    lock.unlock()
                    waiters.forEach { $0.resume() }
                    return
                }
                order.removeFirst()
                let request = pending.removeValue(forKey: vin)
                lock.unlock()
                if let request {
                    beforePersist?()
                    VehicleHistoryRecorder.persist(request)
                }
            }
        }
    }

    func record(_ state: VehicleState) {
        // The recording body is pure storage I/O (per-event inserts, dedupe reads, the
        // charging-ledger ingest) with no UI dependency. The main actor only reads its own
        // mutable state (preferences, the parked-charge detector) and hands off Sendable
        // values; the SQLite handle is Sendable and safe for cross-thread use.
        let storeChargingHistory = preferences.storeChargingHistory
        let parkedChargeLoss: VehicleActivity?
        if storeChargingHistory {
            parkedChargeLoss = parkedChargeLossDetector.ingest(state)
        } else {
            parkedChargeLossDetector.reset(vin: state.identity.vin)
            parkedChargeLoss = nil
        }
        let inputs = RecordingInputs(
            persistLocationHistory: preferences.persistLocationHistory,
            storeChargingHistory: storeChargingHistory,
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin),
            tariffPricePerKwh: preferences.electricityPricePerKwh,
            nightTariffEnabled: preferences.nightTariffEnabled,
            nightTariffPricePerKwh: preferences.nightElectricityPricePerKwh,
            nightTariffStartHour: preferences.nightTariffStartHour,
            nightTariffEndHour: preferences.nightTariffEndHour,
            currencySymbol: preferences.currencySymbol
        )
        writer.enqueue(RecordingRequest(
            state: state, parkedChargeLoss: parkedChargeLoss,
            inputs: inputs, database: database
        ))
    }

    func waitUntilIdle() async { await writer.waitUntilIdle() }

    func resetTransientState(vin: String? = nil) {
        parkedChargeLossDetector.reset(vin: vin)
    }

    private nonisolated static func persist(_ request: RecordingRequest) {
        recordActivitiesAndSnapshot(
            request.state, parkedChargeLossActivity: request.parkedChargeLoss,
            into: request.database
        )
        recordAirQuality(request.state, into: request.database)
        recordTelemetry(
            request.state,
            persistLocationHistory: request.inputs.persistLocationHistory,
            into: request.database
        )
        recordBatteryHistory(request.state, inputs: request.inputs, into: request.database)
    }

    private nonisolated static func recordActivitiesAndSnapshot(
        _ state: VehicleState, parkedChargeLossActivity: VehicleActivity?, into database: VehicleDatabase
    ) {
        let previous = database.loadSnapshot(for: state.identity.vin)
        if let parkedChargeLossActivity {
            database.recordActivities([parkedChargeLossActivity])
        }
        database.recordActivities(VehicleActivity.changes(from: previous, to: state))
        database.saveSnapshot(state)
    }

    private nonisolated static func recordAirQuality(_ state: VehicleState, into database: VehicleDatabase) {
        // Cabin AQI comes from Polestar's GetPreCleaning service. Do not persist a value on
        // Volvo snapshots even if a stale or imported payload happens to carry that field.
        guard !state.isVolvo, let airQuality = state.airQuality else { return }
        database.recordAirQuality(
            vin: state.identity.vin,
            airQualityIndex: airQuality.airQualityIndex.map(Double.init),
            particulateMatter25: airQuality.particulateMatter25.map(Double.init),
            particulateMatter10: airQuality.particulateMatter10.map(Double.init),
            filterRemainingPercent: airQuality.filterRemainingPercent.map(Double.init),
            timestamp: state.freshness.fetchedAt
        )
    }

    private nonisolated static func recordTelemetry(
        _ state: VehicleState, persistLocationHistory: Bool, into database: VehicleDatabase
    ) {
        guard state.maintenance.odometerKm != nil || state.tripComputer.manualTripKm != nil
                || state.tripComputer.automaticTripKm != nil else { return }
        database.recordTelemetry(
            vin: state.identity.vin,
            odometerKm: state.maintenance.odometerKm.map(Double.init),
            tripManualKm: state.tripComputer.manualTripKm,
            tripAutoKm: state.tripComputer.automaticTripKm,
            avgConsumption: state.energy.diagnostics?.averageConsumption
                ?? state.fuelSystem.averageConsumptionLPer100Km,
            consumptionUnit: state.energy.diagnostics?.averageConsumption != nil
                ? "kwh"
                : (state.fuelSystem.averageConsumptionLPer100Km != nil ? "l" : nil),
            ambientTempC: state.weather?.temperatureCelsius,
            latitude: persistLocationHistory ? state.location?.latitude : nil,
            longitude: persistLocationHistory ? state.location?.longitude : nil,
            timestamp: state.freshness.fetchedAt
        )
    }

    private nonisolated static func recordBatteryHistory(
        _ state: VehicleState, inputs: RecordingInputs, into database: VehicleDatabase
    ) {
        guard let batteryPercentage = state.energy.batteryPercentage else { return }

        database.recordConnectivity(
            vin: state.identity.vin,
            networkType: state.connectivity?.networkType,
            signalBars: state.connectivity?.signalBars,
            wakeReason: state.connectivity?.wakeReason,
            timestamp: state.freshness.fetchedAt
        )
        database.recordCabinClimate(
            vin: state.identity.vin,
            interiorCelsius: state.climateStatus?.interiorTemperatureCelsius,
            requestedCelsius: state.climateStatus?.requestedTemperatureCelsius
        )

        let capacity = state.configuredCapacityReference(specification: inputs.specification).kwh
        database.charging.ingest(
            ChargingSessionObservation(
                vin: state.identity.vin,
                timestamp: state.freshness.fetchedAt,
                soc: batteryPercentage,
                chargingState: state.energy.chargingState,
                chargerConnection: state.energy.connection,
                powerKw: state.energy.powerWatts.map { Double($0) / 1_000 },
                voltageVolts: state.energy.voltageVolts.map(Double.init),
                currentAmps: state.energy.currentAmps.map(Double.init),
                chargingType: state.energy.type,
                targetSoc: state.energy.targetPercentage.map(Double.init)
            ),
            configuration: ChargingSessionLedgerConfiguration(
                usableCapacityKwh: capacity,
                tariffPricePerKwh: inputs.tariffPricePerKwh,
                nightTariffEnabled: inputs.nightTariffEnabled,
                nightTariffPricePerKwh: inputs.nightTariffPricePerKwh,
                nightTariffStartHour: inputs.nightTariffStartHour,
                nightTariffEndHour: inputs.nightTariffEndHour,
                currencySymbol: inputs.currencySymbol,
                locationName: chargingLocationName(for: state, persistLocationHistory: inputs.persistLocationHistory)
            ),
            recordingEnabled: inputs.storeChargingHistory
        )
        recordBatteryHealth(state, specification: inputs.specification, database: database)
    }

    private nonisolated static func chargingLocationName(for state: VehicleState, persistLocationHistory: Bool) -> String? {
        guard persistLocationHistory,
              let location = state.location,
              let latitude = location.latitude,
              let longitude = location.longitude else { return nil }
        return String(format: "%.4f°, %.4f°", latitude, longitude)
    }

    private nonisolated static func recordBatteryHealth(
        _ state: VehicleState,
        specification: VehicleSpecificationOverride?,
        database: VehicleDatabase
    ) {
        guard let odometer = state.maintenance.odometerKm,
              let estimate = BatteryHealthEstimator.estimate(
                state: state,
                specification: specification
              ) else { return }
        database.recordBatteryHealthMilestone(
            vin: state.identity.vin,
            odometerKm: Double(odometer),
            sohPct: estimate.stateOfHealthPercent,
            degPct: estimate.degradationPercent,
            usableKwh: estimate.estimatedUsableCapacityKwh,
            measurementSource: BatteryHealthRecord.fullChargeRangeSource,
            timestamp: state.freshness.fetchedAt
        )
    }
}
