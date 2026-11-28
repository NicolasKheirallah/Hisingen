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
    /// The reader entered the session by hand rather than the app recording it.
    case manualEntry = "manual_entry"
}

enum ChargingSessionEnergySource: String, Codable, Equatable, Sendable {
    case observedPowerIntegration = "observed_power_integration"
    case socCapacityEstimate = "soc_capacity_estimate"
    case legacyEstimate = "legacy_estimate"
    /// A row created from the home charger's own record, with no battery-side reading behind it.
    /// `energy_delivered_kwh` stays zero; the metered energy lives in the wallbox columns.
    case wallboxOnly = "wallbox_only"
    /// The reader typed the energy and price from a receipt.
    case manualEntry = "manual_entry"

    var displayName: String {
        switch self {
        case .observedPowerIntegration: return L10n.text("Integrated observed power")
        case .socCapacityEstimate: return L10n.text("SoC and usable-capacity estimate")
        case .legacyEstimate: return L10n.text("Legacy estimate")
        case .wallboxOnly: return L10n.text("Charger measurement only")
        case .manualEntry: return L10n.text("Entered by hand")
        }
    }
}

/// Where a charging session happened. Recorded sessions count as home until the reader
/// changes them; a session entered by hand carries the place the reader picked.
enum ChargingSessionPlace: String, Codable, Equatable, Hashable, CaseIterable, Sendable, Identifiable {
    case home
    case publicCharging = "public"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .home: return L10n.text("Home")
        case .publicCharging: return L10n.text("Public")
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

/// What the home charger metered for a session, kept apart from the battery-side estimate in
/// `energyDeliveredKwh`. The two answer different questions: wall energy is what the meter and
/// the bill see, battery energy is what the pack gained.
struct WallboxMeasurement: Codable, Equatable, Sendable {
    var chargerID: String
    var sessionKey: String
    var keyKind: String
    var energyKwh: Double
    var energySource: String
    /// The timestamp of the last charger reading behind `energyKwh`.
    var measuredAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var peakPowerKw: Double?
    var cost: Double?
    /// The priced part when interval prices were missing and no total could be given.
    var partialCost: Double?
    var costMethod: String?
    var priceSource: String?
    var costAssumptions: [String]
    var missingKwh: Double?
    var currency: String?
    /// How the session was matched to its vehicle (`overlap`, `dedicated`, or why it is unassigned).
    var attribution: String?
    /// The vendor's raw start and stop tokens (see `ChargerSessionStart` and `ChargerSessionEnd`).
    var startReason: String?
    var stopReason: String?

    var isEstimatedCost: Bool { costMethod != nil && costMethod != HomeSessionCost.Method.intervalTibber.rawValue }
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
    /// Market-price cost of the session, computed from recorded samples against hourly
    /// spot prices. `nil` until a covered backfill pass prices it.
    var spotEstimatedCost: Double? = nil
    /// The home charger's measurement for this session, when a paired charger recorded one.
    var wallbox: WallboxMeasurement? = nil
    /// Home or public. Recorded sessions count as home until the reader changes them; a
    /// session entered by hand carries the place picked in the sheet.
    var place: ChargingSessionPlace = .home
    /// True when the reader entered or edited the session's cost/tariff by hand.
    var costManuallyEdited: Bool = false

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
        pendingStopCount: Int = 0, estimatedCost: Double? = nil,
        spotEstimatedCost: Double? = nil,
        wallbox: WallboxMeasurement? = nil,
        place: ChargingSessionPlace = .home,
        costManuallyEdited: Bool = false
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
        self.spotEstimatedCost = spotEstimatedCost
        self.wallbox = wallbox
        self.place = place
        self.costManuallyEdited = costManuallyEdited
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
    static let fullChargeRangeSource = "full-charge-range-v1"
    static let calculatedSource = "calculated-v2"
    static let legacyEstimateSource = "legacy-estimate"
    static let sessionEnergySource = "session-energy-v1"

    /// Which `measurement_source` values count as a real state-of-health measurement.
    ///
    /// One predicate, because four readers must agree on it: the per-VIN read, the cross-vehicle
    /// export, the backup, and the row count that a settings screen shows next to them. When it
    /// was written inline in all four, a row counted in one screen could be absent from the
    /// export that was supposed to contain it.
    static let measurementSourceFilter =
        "measurement_source IN ('\(fullChargeRangeSource)', '\(calculatedSource)', '\(legacyEstimateSource)', '\(sessionEnergySource)')"

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
         measurementSource: String = BatteryHealthRecord.calculatedSource) {
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

enum TripPurpose: String, Codable, CaseIterable, Identifiable, Sendable {
    case privateTrip = "private"
    case business = "business"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .privateTrip: return L10n.text("Private")
        case .business: return L10n.text("Business")
        }
    }
}

struct MonthlyMileageReport: Equatable, Identifiable, Sendable {
    let monthStart: Date
    let privateKm: Double
    let businessKm: Double
    let unclassifiedKm: Double
    let privateTrips: Int
    let businessTrips: Int
    let unclassifiedTrips: Int

    var id: Date { monthStart }
    var totalKm: Double { privateKm + businessKm + unclassifiedKm }
    var totalTrips: Int { privateTrips + businessTrips + unclassifiedTrips }

    static func build(
        from trips: [TripHistoryEntry],
        purposes: [String: TripPurpose],
        calendar: Calendar = .current
    ) -> [MonthlyMileageReport] {
        let grouped = Dictionary(grouping: trips) { trip in
            let components = calendar.dateComponents([.era, .year, .month], from: trip.endedAt)
            return calendar.date(from: components) ?? calendar.startOfDay(for: trip.endedAt)
        }
        return grouped.map { month, monthTrips in
            let privateTrips = monthTrips.filter { purposes[$0.id] == .privateTrip }
            let businessTrips = monthTrips.filter { purposes[$0.id] == .business }
            let unclassified = monthTrips.filter { purposes[$0.id] == nil }
            return MonthlyMileageReport(
                monthStart: month,
                privateKm: privateTrips.reduce(0) { $0 + $1.distanceKm },
                businessKm: businessTrips.reduce(0) { $0 + $1.distanceKm },
                unclassifiedKm: unclassified.reduce(0) { $0 + $1.distanceKm },
                privateTrips: privateTrips.count,
                businessTrips: businessTrips.count,
                unclassifiedTrips: unclassified.count
            )
        }
        .sorted { $0.monthStart > $1.monthStart }
    }

    static func csv(
        reports: [MonthlyMileageReport], vin: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        var csv = "Month,VIN,Business Trips,Business km,Private Trips,Private km,Unclassified Trips,Unclassified km,Total km\n"
        for report in reports.sorted(by: { $0.monthStart < $1.monthStart }) {
            csv += [
                formatter.string(from: report.monthStart), vin,
                String(report.businessTrips), String(format: "%.2f", report.businessKm),
                String(report.privateTrips), String(format: "%.2f", report.privateKm),
                String(report.unclassifiedTrips), String(format: "%.2f", report.unclassifiedKm),
                String(format: "%.2f", report.totalKm)
            ].joined(separator: ",") + "\n"
        }
        return csv
    }
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
