import Foundation
import OSLog

/// The Charging Session ledger – the sole owner of the Charging Session lifecycle.
///
/// Owns every domain read and write over the `charging_sessions` and `charging_samples`
/// tables: `VehicleDatabase` keeps the schema, migrations, and cross-table operations
/// (wipe, prune, backup, counts), but nothing outside this module interprets those two
/// tables. Session summaries are versioned materialized state advanced through explicit
/// lifecycle transitions; sample integration and its gap-tolerance policies live here and
/// nowhere else, so the write-time summary and the read-time estimates can never drift
/// apart in separate integrators.
///
/// `charging_samples` is the append-only observation log. `charging_sessions` is a
/// versioned materialized summary that this ledger advances through explicit states. A
/// one-poll idle or disconnect is only `pendingCompletion`; a second confirms the stop.
/// Paused and scheduled charging keep the physical session open and a new active
/// observation resumes it.
struct ChargingSessionObservation: Equatable, Sendable {
    let vin: String
    let timestamp: Date
    let soc: Double
    let chargingState: ChargingState
    let chargerConnection: ChargerConnection
    let powerKw: Double?
    let voltageVolts: Double?
    let currentAmps: Double?
    let chargingType: ChargingType
    let targetSoc: Double?
}

struct ChargingSessionLedgerConfiguration: Equatable, Sendable {
    let usableCapacityKwh: Double
    let tariffPricePerKwh: Double?
    let nightTariffEnabled: Bool
    let nightTariffPricePerKwh: Double?
    let nightTariffStartHour: Int
    let nightTariffEndHour: Int
    let currencySymbol: String?
    let locationName: String?

    init(
        usableCapacityKwh: Double, tariffPricePerKwh: Double?,
        nightTariffEnabled: Bool = false, nightTariffPricePerKwh: Double? = nil,
        nightTariffStartHour: Int = 22, nightTariffEndHour: Int = 6,
        currencySymbol: String?, locationName: String?
    ) {
        self.usableCapacityKwh = usableCapacityKwh
        self.tariffPricePerKwh = tariffPricePerKwh
        self.nightTariffEnabled = nightTariffEnabled
        self.nightTariffPricePerKwh = nightTariffPricePerKwh
        self.nightTariffStartHour = nightTariffStartHour
        self.nightTariffEndHour = nightTariffEndHour
        self.currencySymbol = currencySymbol
        self.locationName = locationName
    }
}

struct ChargingSessionCalculatedSummary: Equatable, Sendable {
    let endSoc: Double
    let energyKwh: Double
    let peakPowerKw: Double
    let averagePowerKw: Double
    let source: ChargingSessionEnergySource
    let confidence: ChargingSessionConfidence
    let sampleCoverage: Double
}

/// The authoritative summary integration, fed by the ledger's gap policies.
enum ChargingSessionSummaryCalculator {
    /// Gaps longer than this are evidence that Hisingen did not observe the interval and must
    /// not be silently integrated as if the last power value held throughout it. Same constant
    /// as the chart curve's visual gap threshold, so what the summary integrated and what the
    /// curve displays agree by construction.
    static let maximumIntegratableGap = HistoryInsights.chargingCurveGapThreshold

    static func calculate(
        startSoc: Double, terminalSoc: Double, startedAt: Date, endedAt: Date,
        samples: [HistoricalChargingSample], usableCapacityKwh: Double
    ) -> ChargingSessionCalculatedSummary {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        // A provider's first stop snapshots can lag behind its final charging sample. Preserve
        // the greatest SoC actually observed inside the session instead of allowing one stale
        // terminal value to erase the gain.
        let greatestObservedSoc = ordered.map(\.soc).max() ?? startSoc
        let endSoc = max(startSoc, max(terminalSoc, greatestObservedSoc))
        let powers = ordered.compactMap(\.powerKw)
        let peak = powers.max() ?? 0
        let average = powers.isEmpty ? 0 : powers.reduce(0, +) / Double(powers.count)
        let duration = max(0, endedAt.timeIntervalSince(startedAt))

        var integratedKwh = 0.0
        var coveredSeconds = 0.0
        if ordered.count >= 2 {
            for (first, second) in zip(ordered, ordered.dropFirst()) {
                let interval = second.timestamp.timeIntervalSince(first.timestamp)
                guard interval > 0, interval <= maximumIntegratableGap,
                      let firstPower = first.powerKw,
                      let secondPower = second.powerKw else { continue }
                // Zero-power pauses are observed coverage with zero energy; only nil
                // (unknown) is skipped. Negative glitches clamp to zero.
                let p0 = max(0, firstPower)
                let p1 = max(0, secondPower)
                integratedKwh += ((p0 + p1) / 2) * interval / 3_600
                coveredSeconds += interval
            }
        }
        let coverage = duration > 0 ? min(1, coveredSeconds / duration) : 0
        if integratedKwh > 0, coverage >= 0.70 {
            return ChargingSessionCalculatedSummary(
                endSoc: endSoc, energyKwh: integratedKwh,
                peakPowerKw: peak, averagePowerKw: average,
                source: .observedPowerIntegration,
                confidence: coverage >= 0.90 ? .high : .medium,
                sampleCoverage: coverage
            )
        }

        let socEnergy = max(0, endSoc - startSoc) / 100 * max(0, usableCapacityKwh)
        let confidence: ChargingSessionConfidence = ordered.count >= 3 && endSoc - startSoc >= 1
            ? .medium : .low
        return ChargingSessionCalculatedSummary(
            endSoc: endSoc, energyKwh: socEnergy,
            peakPowerKw: peak, averagePowerKw: average,
            source: .socCapacityEstimate, confidence: confidence,
            sampleCoverage: coverage
        )
    }
}

final class ChargingSessionLedger: Sendable {
    static let requiredStopObservations = 2
    static let maximumContinuityGap: TimeInterval = 12 * 60 * 60
    /// Paused/scheduled polls append samples for confirmation, but a week-long scheduled
    /// wait must not grow the table unboundedly: cap stored samples per session and thin
    /// paused stretches to one sample per hour.
    static let maximumSamplesPerSession = 2_000

    let sql: SQLiteDatabase
    private let logger = AppLog.logger("charging-ledger")

    init(sql: SQLiteDatabase) {
        self.sql = sql
    }

    /// Runs one write and logs it on failure. Public writers stay non-throwing, so this log is
    /// the only record of a lost lifecycle update or discard.
    func logOnFailure(_ operation: String, _ write: () throws -> Void) {
        do {
            try write()
        } catch {
            logger.error("Charging ledger \(operation, privacy: .public) failed: \(error, privacy: .public)")
        }
    }
}
