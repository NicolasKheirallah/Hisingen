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

    /// The charging ledger lives on the database (both own the same SQLite handle); the
    /// recorder routes every charging observation through it.
    private var chargingSessionLedger: ChargingSessionLedger { database.charging }

    init(database: VehicleDatabase, preferences: PreferencesStore) {
        self.database = database
        self.preferences = preferences
    }

    func record(_ state: VehicleState) {
        recordActivitiesAndSnapshot(state)
        recordAirQuality(state)
        recordTelemetry(state)
        recordBatteryHistory(state)
    }

    func resetTransientState(vin: String? = nil) {
        parkedChargeLossDetector.reset(vin: vin)
    }

    private func recordActivitiesAndSnapshot(_ state: VehicleState) {
        let previous = database.loadSnapshot(for: state.identity.vin)
        if preferences.storeChargingHistory {
            if let loss = parkedChargeLossDetector.ingest(state) {
                database.recordActivities([loss])
            }
        } else {
            parkedChargeLossDetector.reset(vin: state.identity.vin)
        }
        database.recordActivities(VehicleActivity.changes(from: previous, to: state))
        database.saveSnapshot(state)
    }

    private func recordAirQuality(_ state: VehicleState) {
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

    private func recordTelemetry(_ state: VehicleState) {
        guard state.maintenance.odometerKm != nil || state.tripComputer.manualTripKm != nil
                || state.tripComputer.automaticTripKm != nil else { return }
        let persistLocation = preferences.persistLocationHistory
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
            latitude: persistLocation ? state.location?.latitude : nil,
            longitude: persistLocation ? state.location?.longitude : nil
        )
    }

    private func recordBatteryHistory(_ state: VehicleState) {
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

        let specification = preferences.vehicleSpecificationOverride(for: state.identity.vin)
        let capacity = specification?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh
        chargingSessionLedger.ingest(
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
                tariffPricePerKwh: preferences.electricityPricePerKwh,
                nightTariffEnabled: preferences.nightTariffEnabled,
                nightTariffPricePerKwh: preferences.nightElectricityPricePerKwh,
                nightTariffStartHour: preferences.nightTariffStartHour,
                nightTariffEndHour: preferences.nightTariffEndHour,
                currencySymbol: preferences.currencySymbol,
                locationName: chargingLocationName(for: state)
            ),
            recordingEnabled: preferences.storeChargingHistory
        )
        recordBatteryHealth(state, capacity: capacity, specification: specification)
    }

    private func chargingLocationName(for state: VehicleState) -> String? {
        guard preferences.persistLocationHistory,
              let location = state.location,
              let latitude = location.latitude,
              let longitude = location.longitude else { return nil }
        return String(format: "%.4f°, %.4f°", latitude, longitude)
    }

    private func recordBatteryHealth(
        _ state: VehicleState,
        capacity: Double,
        specification: VehicleSpecificationOverride?
    ) {
        let sessions = database.charging.recentChargingSessions(for: state.identity.vin, limit: 20)
            .map { database.charging.domainSession(from: $0, usableCapacityKwh: capacity) }
            .filter { $0.percentageAdded > 0 && $0.kwhDelivered > 0 }
        let previous = database.history.batteryHealthHistory(for: state.identity.vin, limit: 1).first
            .map {
                BatteryHealthPriorEstimate(
                    stateOfHealthPercent: $0.stateOfHealthPct,
                    timestamp: $0.timestamp
                )
            }
        guard let odometer = state.maintenance.odometerKm,
              let estimate = BatteryHealthEstimator.estimate(
                state: state,
                chargingSessions: sessions,
                specification: specification,
                previous: previous
              ) else { return }
        database.recordBatteryHealthMilestone(
            vin: state.identity.vin,
            odometerKm: Double(odometer),
            sohPct: estimate.stateOfHealthPercent,
            degPct: estimate.degradationPercent,
            usableKwh: estimate.estimatedUsableCapacityKwh
        )
    }
}
