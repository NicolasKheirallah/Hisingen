import Foundation

/// Pure math for the instrument layer: gesture physics and charge projections.
///
/// Everything here is a total function over its inputs with no view, no clock and no I/O, so
/// the physics the panel *feels* is the physics the tests assert. Every function returns nil
/// rather than a guess: a projection the data cannot support is not shown at all (empty is
/// better than deceptive).
enum InstrumentMath {

    // MARK: - Gesture physics

    /// Rubber-band resistance at a boundary: the further past the edge the pointer drags, the
    /// less the content follows, so an overscroll reads as "responsive, but nothing more here"
    /// instead of a hard stop. Apple's form; `dimension` is the length of the scrolling axis.
    static func rubberBandDisplacement(overshoot: CGFloat, dimension: CGFloat, constant: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0 else { return 0 }
        return (overshoot * dimension * constant) / (dimension + constant * abs(overshoot))
    }

    /// Where a decelerating flick lands: exponential decay from the release velocity, the
    /// projection Apple's own scroll machinery uses (`d ≈ 0.998` for normal scroll feel).
    /// Returns the distance past the release point the gesture is *going*.
    static func momentumProjection(velocity: CGFloat, decelerationRate: CGFloat = 0.998) -> CGFloat {
        (velocity / 1000) * decelerationRate / (1 - decelerationRate)
    }

    /// The tab a horizontal swipe should land on, chosen from the projection of the release
    /// velocity rather than from the release position alone — but clamped to one tab either
    /// side. Tabs are discrete destinations, not a continuous scroll: velocity decides the
    /// *direction* of a flick and whether a half-dragged page commits, never "how many tabs
    /// a strong flick skips".
    static func projectedTab(
        currentIndex: Int,
        count: Int,
        translation: CGFloat,
        releaseVelocity: CGFloat,
        pageWidth: CGFloat
    ) -> Int? {
        guard count > 0, pageWidth > 0, (0..<count).contains(currentIndex) else { return nil }
        let travelled = -translation / pageWidth
        // The gesture reports velocity in the pointer's axis (negative for a leftward flick
        // toward the next tab), so it enters the projection negated, matching `travelled`.
        let projected = travelled + momentumProjection(velocity: -releaseVelocity) / pageWidth
        let step = max(-1, min(1, CGFloat(projected.rounded())))
        let target = currentIndex + Int(step)
        return min(count - 1, max(0, target))
    }

    /// Whether a downward pull at the scroll top has earned a refresh: the drag must pass the
    /// distance threshold and the release must still carry downward intent. Position alone
    /// does not commit; a slow release with downward momentum does, per the velocity rule.
    static func pullRefreshShouldCommit(dragDistance: CGFloat, releaseVelocity: CGFloat, threshold: CGFloat = 56) -> Bool {
        dragDistance >= threshold || (dragDistance > threshold * 0.4 && releaseVelocity > 320)
    }

    // MARK: - Charge projection

    /// What a charge-target change would cost in time and range, derived only from real
    /// readings. Every output is nil unless the inputs that decide it exist.
    ///
    /// Battery capacity is not a field the car reports directly; it is *derived* from two real
    /// readings — available energy and its own percentage — and only when both are present and
    /// the arithmetic is sane (a percentage above zero, available energy not below zero). A
    /// derived capacity is marked as such in the UI that consumes it.
    struct ChargeProjection: Equatable {
        /// Minutes of charging until the car reaches `targetPercent` at `powerKw`.
        let minutesToTarget: Int?
        /// Kilometres of range between the current level and the target, at the car's own
        /// average consumption.
        let addedRangeKm: Int?
        /// True when capacity had to be derived from available-energy ÷ percentage rather
        /// than read from a reported figure.
        let capacityIsDerived: Bool
    }

    static func chargeProjection(
        currentPercent: Double?,
        targetPercent: Int?,
        availableEnergyKwh: Double?,
        reportedCapacityKwh: Double?,
        averageConsumptionKwhPer100Km: Double?,
        powerKw: Double?
    ) -> ChargeProjection? {
        guard let currentPercent, let targetPercent,
              targetPercent > Int(currentPercent.rounded(.down)), currentPercent > 0 else { return nil }

        var capacityIsDerived = false
        let capacityKwh: Double?
        if let reportedCapacityKwh, reportedCapacityKwh > 0 {
            capacityKwh = reportedCapacityKwh
        } else if let availableEnergyKwh, availableEnergyKwh > 0, currentPercent > 1 {
            capacityKwh = availableEnergyKwh / currentPercent * 100
            capacityIsDerived = true
        } else {
            capacityKwh = nil
        }

        let deltaFraction = (Double(targetPercent) - currentPercent) / 100
        let energyToAddKwh = capacityKwh.map { $0 * deltaFraction }

        let minutes: Int?
        if let energyToAddKwh, let powerKw, powerKw > 0 {
            minutes = max(1, Int((energyToAddKwh / powerKw * 60).rounded()))
        } else {
            minutes = nil
        }

        let addedRange: Int?
        if let energyToAddKwh, let averageConsumptionKwhPer100Km, averageConsumptionKwhPer100Km > 0 {
            addedRange = max(1, Int((energyToAddKwh / averageConsumptionKwhPer100Km * 100).rounded()))
        } else {
            addedRange = nil
        }

        guard minutes != nil || addedRange != nil else { return nil }
        return ChargeProjection(
            minutesToTarget: minutes,
            addedRangeKm: addedRange,
            capacityIsDerived: capacityIsDerived
        )
    }
}
