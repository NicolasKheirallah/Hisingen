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
    private var parkedChargeLossDetector = ParkedChargeLossDetector()

    init(database: VehicleDatabase, preferences: PreferencesStore) {
        self.database = database
        self.preferences = preferences
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
        let database = self.database
        Task.detached(priority: .utility) {
            Self.recordActivitiesAndSnapshot(
                state, parkedChargeLossActivity: parkedChargeLoss, into: database)
            Self.recordAirQuality(state, into: database)
            Self.recordTelemetry(
                state, persistLocationHistory: inputs.persistLocationHistory, into: database)
            Self.recordBatteryHistory(state, inputs: inputs, into: database)
        }
    }

    func resetTransientState(vin: String? = nil) {
        parkedChargeLossDetector.reset(vin: vin)
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
            filterRemainingPercent: airQuality.filterRemainingPercent.map(Double.init)
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
            longitude: persistLocationHistory ? state.location?.longitude : nil
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
            wakeReason: state.connectivity?.wakeReason
        )
        database.recordCabinClimate(
            vin: state.identity.vin,
            interiorCelsius: state.climateStatus?.interiorTemperatureCelsius,
            requestedCelsius: state.climateStatus?.requestedTemperatureCelsius
        )

        let capacity = inputs.specification?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh
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
            measurementSource: BatteryHealthRecord.fullChargeRangeSource
        )
    }
}
