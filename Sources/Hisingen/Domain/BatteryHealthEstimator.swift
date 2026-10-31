import Foundation

struct BatteryHealthEstimate: Equatable, Sendable {
    let stateOfHealthPercent: Double
    let rawStateOfHealthPercent: Double
    let degradationPercent: Double
    let estimatedUsableCapacityKwh: Double
    let referenceUsableCapacityKwh: Double
    let fullChargeRangeKm: Double?
    let wltpReferenceRangeKm: Double?
    let recordedAt: Date
    let isRemembered: Bool
    let method: String

    var methodologySummary: String {
        L10n.text("Hisingen estimates this value at 100% charge from vehicle-reported range divided by the configured WLTP range, and from high-confidence charging sessions when available. It is a range and energy estimate, not a battery-management-system measurement.")
    }
}

struct VehicleSpecificationOverride: Codable, Equatable, Sendable {
    var usableBatteryCapacityKwh: Double?
    var wltpRangeKm: Double?
    var isEmpty: Bool { usableBatteryCapacityKwh == nil && wltpRangeKm == nil }
}

enum BatteryHealthEstimator {
    /// Every lower reported percentage leaves the remembered result unchanged.
    static let fullChargeThreshold = 100.0
    /// Minimum SoC span for a session-energy estimate. Below this the divider
    /// amplifies SoC rounding noise. 30 points keeps AC overnights while
    /// rejecting short top-ups.
    static let minimumSessionDeltaSoc = 30.0
    /// Assumed wall-to-battery efficiency used only to convert AC/DC energy
    /// into pack energy. Real losses vary with temperature and power, so the
    /// session method stays an estimate and never overwrites the range method.
    static let acChargingEfficiency = 0.89
    static let dcChargingEfficiency = 0.95
    static let dcPowerThresholdKw = 22.0

    static let fullChargeRangeMethod = "full-charge-range"
    static let sessionEnergyMethod = "session-energy"
    static let fusedMethod = "fused"

    /// WLTP reference with provenance. User override wins. Otherwise only a
    /// known model with a real table entry qualifies. Unknown models and PHEV
    /// families with no BEV table entry return nil instead of inventing one.
    static func wltpReference(
        state: VehicleState,
        specification: VehicleSpecificationOverride? = nil
    ) -> Double? {
        if let override = specification?.wltpRangeKm, override > 0 { return override }
        guard state.model.isKnown, state.model.hasModelReferenceSpecs else { return nil }
        return positive(state.model.nominalWltpRangeKm)
    }

    static func estimate(
        state: VehicleState,
        specification: VehicleSpecificationOverride? = nil
    ) -> BatteryHealthEstimate? {
        guard state.powertrain.isElectricOnly,
              let charge = state.energy.batteryPercentage,
              charge >= fullChargeThreshold,
              let fullChargeRange = state.energy.rangeKm.map(Double.init),
              fullChargeRange > 0 else { return nil }

        // `wltpReference` already refuses unknown models without an override,
        // so a VIN-specific reference rescues trims the table never learned.
        let wltpRange = wltpReference(state: state, specification: specification)
        let referenceCapacity = state.measuredCapacityReference(specification: specification)?.kwh
        guard let wltpRange, wltpRange > 0,
              let referenceCapacity, referenceCapacity >= 5 else { return nil }

        let raw = fullChargeRange / wltpRange * 100
        let capped = rounded(min(100, raw))
        return BatteryHealthEstimate(
            stateOfHealthPercent: capped,
            rawStateOfHealthPercent: rounded(raw),
            degradationPercent: rounded(100 - capped),
            estimatedUsableCapacityKwh: rounded(referenceCapacity * capped / 100),
            referenceUsableCapacityKwh: referenceCapacity,
            fullChargeRangeKm: fullChargeRange,
            wltpReferenceRangeKm: wltpRange,
            recordedAt: state.freshness.fetchedAt,
            isRemembered: false,
            method: fullChargeRangeMethod
        )
    }

    /// Independent capacity estimate from one completed charging session.
    /// Converts wall energy into pack energy with an assumed efficiency, then
    /// divides by the SoC span. Requires integrated power (not SoC-derived
    /// energy), medium or better confidence, and a wide SoC window.
    static func estimateFromChargingSession(
        session: HistoricalChargingSession,
        referenceCapacityKwh: Double,
        recordedAt: Date? = nil
    ) -> BatteryHealthEstimate? {
        guard session.lifecycleState == .completed,
              session.energySource == .observedPowerIntegration,
              session.confidence == .high || session.confidence == .medium,
              let endSoc = session.endSoc,
              endSoc > session.startSoc,
              session.energyDeliveredKwh > 0,
              referenceCapacityKwh >= 5 else { return nil }
        let delta = endSoc - session.startSoc
        guard delta >= minimumSessionDeltaSoc else { return nil }
        let efficiency = session.peakPowerKw > dcPowerThresholdKw
            ? dcChargingEfficiency : acChargingEfficiency
        let packEnergy = session.energyDeliveredKwh * efficiency
        let usable = packEnergy / (delta / 100)
        guard usable.isFinite, usable > 0 else { return nil }
        let raw = usable / referenceCapacityKwh * 100
        guard (50...110).contains(raw) else { return nil }
        let capped = rounded(min(100, raw))
        return BatteryHealthEstimate(
            stateOfHealthPercent: capped,
            rawStateOfHealthPercent: rounded(raw),
            degradationPercent: rounded(100 - capped),
            estimatedUsableCapacityKwh: rounded(min(usable, referenceCapacityKwh)),
            referenceUsableCapacityKwh: referenceCapacityKwh,
            fullChargeRangeKm: nil,
            wltpReferenceRangeKm: nil,
            recordedAt: recordedAt ?? session.endedAt ?? session.startedAt,
            isRemembered: false,
            method: sessionEnergyMethod
        )
    }

    /// Median of recent same-method milestones. One bad GOM reading moves a
    /// mean, it cannot move a median of three.
    static func stableMedianSoH(from records: [BatteryHealthRecord], limit: Int = 3) -> Double? {
        let recent = records.sorted { $0.timestamp > $1.timestamp }.prefix(max(1, limit))
        return Statistics.median(recent.map(\.stateOfHealthPct))
    }

    /// Fuse range and session methods by median. Returns nil when they disagree
    /// by more than tolerance, so a confident-looking number never hides a
    /// method conflict the driver should see.
    static func fusedSoH(rangeSoH: Double?, sessionSoH: Double?, tolerance: Double = 5.0) -> Double? {
        let values = [rangeSoH, sessionSoH].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        guard let median = Statistics.median(values) else { return nil }
        if values.count == 2, abs(values[0] - values[1]) > tolerance { return nil }
        return (median * 10).rounded() / 10
    }

    static func remembered(
        stateOfHealthPercent: Double,
        degradationPercent: Double,
        estimatedUsableCapacityKwh: Double,
        recordedAt: Date,
        fallbackReferenceCapacityKwh: Double,
        method: String = fullChargeRangeMethod
    ) -> BatteryHealthEstimate {
        let fraction = stateOfHealthPercent / 100
        let referenceCapacity = fraction > 0
            ? estimatedUsableCapacityKwh / fraction
            : fallbackReferenceCapacityKwh
        return BatteryHealthEstimate(
            stateOfHealthPercent: stateOfHealthPercent,
            rawStateOfHealthPercent: stateOfHealthPercent,
            degradationPercent: degradationPercent,
            estimatedUsableCapacityKwh: estimatedUsableCapacityKwh,
            referenceUsableCapacityKwh: referenceCapacity,
            fullChargeRangeKm: nil,
            wltpReferenceRangeKm: nil,
            recordedAt: recordedAt,
            isRemembered: true,
            method: method
        )
    }

    private static func positive(_ value: Double) -> Double? { value > 0 ? value : nil }
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
