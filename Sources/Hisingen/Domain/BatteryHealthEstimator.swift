import Foundation

struct BatteryHealthEstimate: Equatable, Sendable {
    let stateOfHealthPercent: Double
    let degradationPercent: Double
    let estimatedUsableCapacityKwh: Double
    let referenceUsableCapacityKwh: Double
    let fullChargeRangeKm: Double?
    let wltpReferenceRangeKm: Double?
    let recordedAt: Date
    let isRemembered: Bool

    var methodologySummary: String {
        L10n.text("Hisingen calculates this value only at 100% charge. It divides the vehicle-reported estimated range by the configured WLTP range and multiplies by 100. The result is saved and updates only after another 100% reading. It is a range-based estimate, not a battery-management-system measurement.")
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

    static func estimate(
        state: VehicleState,
        specification: VehicleSpecificationOverride? = nil
    ) -> BatteryHealthEstimate? {
        guard state.powertrain.hasElectricRange,
              let charge = state.energy.batteryPercentage,
              charge >= fullChargeThreshold,
              let fullChargeRange = state.energy.rangeKm.map(Double.init),
              fullChargeRange > 0 else { return nil }

        let wltpRange = specification?.wltpRangeKm
            ?? positive(state.model.nominalWltpRangeKm)
        let referenceCapacity = specification?.usableBatteryCapacityKwh
            ?? state.energy.reportedBatteryCapacityKwh.flatMap(positive)
            ?? positive(state.factoryUsableBatteryCapacityKwh)
        guard let wltpRange, wltpRange > 0,
              let referenceCapacity, referenceCapacity >= 5 else { return nil }

        let stateOfHealth = rounded(min(100, fullChargeRange / wltpRange * 100))
        return BatteryHealthEstimate(
            stateOfHealthPercent: stateOfHealth,
            degradationPercent: rounded(100 - stateOfHealth),
            estimatedUsableCapacityKwh: rounded(referenceCapacity * stateOfHealth / 100),
            referenceUsableCapacityKwh: referenceCapacity,
            fullChargeRangeKm: fullChargeRange,
            wltpReferenceRangeKm: wltpRange,
            recordedAt: state.freshness.fetchedAt,
            isRemembered: false
        )
    }

    static func remembered(
        stateOfHealthPercent: Double,
        degradationPercent: Double,
        estimatedUsableCapacityKwh: Double,
        recordedAt: Date,
        fallbackReferenceCapacityKwh: Double
    ) -> BatteryHealthEstimate {
        let fraction = stateOfHealthPercent / 100
        let referenceCapacity = fraction > 0
            ? estimatedUsableCapacityKwh / fraction
            : fallbackReferenceCapacityKwh
        return BatteryHealthEstimate(
            stateOfHealthPercent: stateOfHealthPercent,
            degradationPercent: degradationPercent,
            estimatedUsableCapacityKwh: estimatedUsableCapacityKwh,
            referenceUsableCapacityKwh: referenceCapacity,
            fullChargeRangeKm: nil,
            wltpReferenceRangeKm: nil,
            recordedAt: recordedAt,
            isRemembered: true
        )
    }

    private static func positive(_ value: Double) -> Double? { value > 0 ? value : nil }
    private static func rounded(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
