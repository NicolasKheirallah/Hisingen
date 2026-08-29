import Foundation

enum ChargingSessionLifecycleState: String, Codable, Equatable, Sendable {
    case active
    case paused
    case pendingCompletion = "pending_completion"
    case completed
    case interrupted
    case abandoned
}

enum ChargingSessionCompletionReason: String, Codable, Equatable, Sendable {
    case targetReached = "target_reached"
    case disconnected
    case stopped
    case fault
    case staleObservation = "stale_observation"
    case noEnergyAdded = "no_energy_added"
    case recordingDisabled = "recording_disabled"
    case legacy
}

enum ChargingSessionEnergySource: String, Codable, Equatable, Sendable {
    case observedPowerIntegration = "observed_power_integration"
    case socCapacityEstimate = "soc_capacity_estimate"
    case legacyEstimate = "legacy_estimate"

    var displayName: String {
        switch self {
        case .observedPowerIntegration: return L10n.text("Integrated observed power")
        case .socCapacityEstimate: return L10n.text("SoC and usable-capacity estimate")
        case .legacyEstimate: return L10n.text("Legacy estimate")
        }
    }
}

enum ChargingSessionConfidence: String, Codable, Equatable, Sendable {
    case high
    case medium
    case low

    var displayName: String {
        switch self {
        case .high: return L10n.text("High confidence")
        case .medium: return L10n.text("Medium confidence")
        case .low: return L10n.text("Low confidence")
        }
    }
}

/// Historical records exposed by `VehicleDatabase`. Kept outside the repository
/// implementation so persistence consumers can find the stable data contract without
/// navigating schema/migration code.
struct HistoricalChargingSession: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let vin: String
    let startedAt: Date
    let endedAt: Date?
    let startSoc: Double
    let endSoc: Double?
    let energyDeliveredKwh: Double
    let peakPowerKw: Double
    let averagePowerKw: Double
    let locationName: String?
    let createdAt: Date
    let lifecycleState: ChargingSessionLifecycleState
    let completionReason: ChargingSessionCompletionReason?
    let energySource: ChargingSessionEnergySource
    let confidence: ChargingSessionConfidence
    let sampleCoverage: Double?
    let usableCapacityKwh: Double?
    let tariffPricePerKwh: Double?
    let nightTariffEnabled: Bool
    let nightTariffPricePerKwh: Double?
    let nightTariffStartHour: Int?
    let nightTariffEndHour: Int?
    let currencySymbol: String?
    let targetSoc: Double?
    let lastObservedAt: Date?
    let summaryVersion: Int
    let pendingStopCount: Int
    let estimatedCost: Double?

    init(
        id: String, vin: String, startedAt: Date, endedAt: Date?, startSoc: Double,
        endSoc: Double?, energyDeliveredKwh: Double, peakPowerKw: Double,
        averagePowerKw: Double, locationName: String?, createdAt: Date,
        lifecycleState: ChargingSessionLifecycleState = .completed,
        completionReason: ChargingSessionCompletionReason? = .legacy,
        energySource: ChargingSessionEnergySource = .legacyEstimate,
        confidence: ChargingSessionConfidence = .low,
        sampleCoverage: Double? = nil,
        usableCapacityKwh: Double? = nil, tariffPricePerKwh: Double? = nil,
        nightTariffEnabled: Bool = false, nightTariffPricePerKwh: Double? = nil,
        nightTariffStartHour: Int? = nil, nightTariffEndHour: Int? = nil,
        currencySymbol: String? = nil, targetSoc: Double? = nil,
        lastObservedAt: Date? = nil, summaryVersion: Int = 1,
        pendingStopCount: Int = 0, estimatedCost: Double? = nil
    ) {
        self.id = id
        self.vin = vin
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startSoc = startSoc
        self.endSoc = endSoc
        self.energyDeliveredKwh = energyDeliveredKwh
        self.peakPowerKw = peakPowerKw
        self.averagePowerKw = averagePowerKw
        self.locationName = locationName
        self.createdAt = createdAt
        self.lifecycleState = lifecycleState
        self.completionReason = completionReason
        self.energySource = energySource
        self.confidence = confidence
        self.sampleCoverage = sampleCoverage
        self.usableCapacityKwh = usableCapacityKwh
        self.tariffPricePerKwh = tariffPricePerKwh
        self.nightTariffEnabled = nightTariffEnabled
        self.nightTariffPricePerKwh = nightTariffPricePerKwh
        self.nightTariffStartHour = nightTariffStartHour
        self.nightTariffEndHour = nightTariffEndHour
        self.currencySymbol = currencySymbol
        self.targetSoc = targetSoc
        self.lastObservedAt = lastObservedAt
        self.summaryVersion = summaryVersion
        self.pendingStopCount = pendingStopCount
        self.estimatedCost = estimatedCost
    }

    /// Converts the durable summary and its samples into one internally consistent session.
    ///
    /// Older builds could finalize a header with a stale end SoC, or retain a header boundary
    /// that was absent from the bounded chart sample list. Treat the header start and the
    /// greatest observed final SoC as authoritative, synthesize missing boundary samples, and
    /// recover a zero energy estimate when a usable-capacity reference is available.
    func toDomainSession(database: VehicleDatabase, usableCapacityKwh: Double? = nil) -> ChargingSession {
        let samples = reconciledSamples(database: database).map {
            ChargingSample(
                timestamp: $0.timestamp,
                batteryPercentage: $0.soc,
                powerWatts: $0.powerKw.map { Int($0 * 1000.0) },
                chargingType: $0.chargingType.flatMap(ChargingType.init(rawValue:)) ?? .unknown
            )
        }

        let observedEndSoc = samples.last?.batteryPercentage ?? startSoc
        let resolvedEndSoc = max(startSoc, max(endSoc ?? startSoc, observedEndSoc))
        let resolvedEndDate = max(endedAt ?? startedAt, samples.last?.timestamp ?? startedAt)
        let percentageAdded = max(0, resolvedEndSoc - startSoc)
        let resolvedEnergy: Double = {
            if energyDeliveredKwh > 0 { return energyDeliveredKwh }
            guard let usableCapacityKwh, usableCapacityKwh > 0, percentageAdded > 0 else { return 0 }
            return percentageAdded / 100 * usableCapacityKwh
        }()
        return ChargingSession(
            id: UUID(uuidString: id) ?? UUID(), vin: vin,
            startDate: startedAt, endDate: resolvedEndDate,
            startBatteryPercentage: startSoc, endBatteryPercentage: resolvedEndSoc,
            kwhDelivered: resolvedEnergy,
            peakPowerWatts: peakPowerKw > 0 ? Int(peakPowerKw * 1000.0) : nil,
            cost: estimatedCost,
            targetPercentage: targetSoc.map { Int($0.rounded()) }, samples: samples,
            energySource: energySource, confidence: confidence,
            sampleCoverage: sampleCoverage, tariffPricePerKwh: tariffPricePerKwh,
            currencySymbol: currencySymbol, completionReason: completionReason,
            summaryVersion: summaryVersion
        )
    }

    /// Historical-dashboard representation of the same repaired curve used by the vehicle
    /// card, while retaining voltage/current fields that the domain chart does not carry.
    func reconciledSamples(database: VehicleDatabase) -> [HistoricalChargingSample] {
        var samples = database.chargingSamples(for: id).sorted { $0.timestamp < $1.timestamp }
        let startSample = HistoricalChargingSample(
            id: .min, sessionId: id, vin: vin, timestamp: startedAt, soc: startSoc,
            powerKw: nil, voltageVolts: nil, currentAmps: nil, chargingType: nil
        )
        if let first = samples.first {
            if abs(first.timestamp.timeIntervalSince(startedAt)) > 1
                || abs(first.soc - startSoc) > 0.01 {
                samples.insert(startSample, at: 0)
            }
        } else {
            samples = [startSample]
        }

        guard let endedAt, let last = samples.last else { return samples }
        let resolvedEndDate = max(endedAt, last.timestamp)
        let resolvedEndSoc = max(startSoc, max(endSoc ?? startSoc, last.soc))
        if abs(last.timestamp.timeIntervalSince(resolvedEndDate)) > 1
            || abs(last.soc - resolvedEndSoc) > 0.01 {
            samples.append(HistoricalChargingSample(
                id: .max, sessionId: id, vin: vin, timestamp: resolvedEndDate,
                soc: resolvedEndSoc, powerKw: nil, voltageVolts: nil,
                currentAmps: nil, chargingType: nil
            ))
        }
        return samples
    }

    /// Repairs zero-value legacy summaries in memory for aggregate dashboard statistics.
    /// Normal rows return without querying their sample table.
    func reconciled(database: VehicleDatabase, usableCapacityKwh: Double) -> HistoricalChargingSession {
        guard endedAt != nil,
              energyDeliveredKwh <= 0 || (endSoc ?? startSoc) <= startSoc else { return self }
        let samples = reconciledSamples(database: database)
        let resolvedEndSoc = max(startSoc, max(endSoc ?? startSoc, samples.last?.soc ?? startSoc))
        let percentageAdded = max(0, resolvedEndSoc - startSoc)
        guard percentageAdded > 0, usableCapacityKwh > 0 else { return self }
        let powers = samples.compactMap(\.powerKw)
        return HistoricalChargingSession(
            id: id, vin: vin, startedAt: startedAt,
            endedAt: max(endedAt ?? startedAt, samples.last?.timestamp ?? startedAt),
            startSoc: startSoc, endSoc: resolvedEndSoc,
            energyDeliveredKwh: percentageAdded / 100 * usableCapacityKwh,
            peakPowerKw: max(peakPowerKw, powers.max() ?? 0),
            averagePowerKw: powers.isEmpty ? averagePowerKw : powers.reduce(0, +) / Double(powers.count),
            locationName: locationName, createdAt: createdAt,
            lifecycleState: lifecycleState, completionReason: completionReason,
            energySource: energySource, confidence: confidence,
            sampleCoverage: sampleCoverage,
            usableCapacityKwh: usableCapacityKwh, tariffPricePerKwh: tariffPricePerKwh,
            nightTariffEnabled: nightTariffEnabled,
            nightTariffPricePerKwh: nightTariffPricePerKwh,
            nightTariffStartHour: nightTariffStartHour,
            nightTariffEndHour: nightTariffEndHour,
            currencySymbol: currencySymbol, targetSoc: targetSoc,
            lastObservedAt: lastObservedAt, summaryVersion: summaryVersion,
            pendingStopCount: pendingStopCount, estimatedCost: estimatedCost
        )
    }
}

/// Represents a time-series charging sample point.
struct HistoricalChargingSample: Codable, Equatable, Sendable {
    let id: Int64
    let sessionId: String
    let vin: String
    let timestamp: Date
    let soc: Double
    let powerKw: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
    /// Raw `ChargingType.rawValue`, or `nil` for records written before this column existed.
    let chargingType: String?
}

/// Represents a recorded battery state-of-health milestone over time.
struct BatteryHealthRecord: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let vin: String
    let timestamp: Date
    let odometerKm: Double
    let stateOfHealthPct: Double
    let degradationPct: Double
    let effectiveUsableKwh: Double
    let measurementSource: String

    init(id: Int64, vin: String, timestamp: Date, odometerKm: Double,
         stateOfHealthPct: Double, degradationPct: Double, effectiveUsableKwh: Double,
         measurementSource: String = "calculated-v2") {
        self.id = id
        self.vin = vin
        self.timestamp = timestamp
        self.odometerKm = odometerKm
        self.stateOfHealthPct = stateOfHealthPct
        self.degradationPct = degradationPct
        self.effectiveUsableKwh = effectiveUsableKwh
        self.measurementSource = measurementSource
    }
}

struct AirQualityRecord: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let vin: String
    let timestamp: Date
    let airQualityIndex: Double?
    let particulateMatter25: Double?
    let particulateMatter10: Double?
    let filterRemainingPercent: Double?
}

struct HistoricalTelemetryRecord: Codable, Equatable, Identifiable, Sendable {
    let id: Int64
    let vin: String
    let timestamp: Date
    let odometerKm: Double?
    let tripManualKm: Double?
    let tripAutomaticKm: Double?
    let averageConsumption: Double?
    /// Unit of `averageConsumption`: `"kwh"` (kWh/100 km), `"l"` (L/100 km), or nil for
    /// records written before the unit column existed.
    let averageConsumptionUnit: String?
    let ambientTemperatureCelsius: Double?
    let latitude: Double?
    let longitude: Double?
}

struct TripHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let vin: String
    let startedAt: Date
    let endedAt: Date
    let distanceKm: Double
    let averageConsumption: Double?
    let ambientTemperatureCelsius: Double?
    let startLatitude: Double?
    let startLongitude: Double?
    let endLatitude: Double?
    let endLongitude: Double?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}

struct RemoteCommandAuditRecord: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let vin: String
    let command: String
    let status: String
    let executedAt: Date
    let durationMs: Int?
    let errorMessage: String?
}
