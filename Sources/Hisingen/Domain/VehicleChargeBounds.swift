import Foundation

/// Charging-control limits resolved from the vehicle's `GetMyCars` capabilities.
///
/// Polestar encodes an integer as zero when a limit is unknown. Zero is not a usable
/// charging limit, so each side falls back independently to the conservative ranges used by
/// both the UI and command validator. Keeping this in the domain layer prevents a slider and
/// the dispatch path from drifting apart.
struct VehicleChargeBounds: Equatable, Sendable {
    static let fallbackTargetRange = 40...100
    static let fallbackAmperageRange = 6...32

    let targetRange: ClosedRange<Int>
    let amperageRange: ClosedRange<Int>

    init(capabilities: VehicleOTACapabilities?) {
        let advertisedTargetMinimum = capabilities?.targetChargeLevelPercentageMinLimit ?? 0
        let targetMinimum = advertisedTargetMinimum > 0
            ? min(max(advertisedTargetMinimum, 1), 100)
            : Self.fallbackTargetRange.lowerBound

        let advertisedAmpMinimum = capabilities?.chargeAmperageMinLimit ?? 0
        let advertisedAmpMaximum = capabilities?.chargeAmperageMaxLimit ?? 0
        let ampMinimum = advertisedAmpMinimum > 0
            ? min(max(advertisedAmpMinimum, 1), 64)
            : Self.fallbackAmperageRange.lowerBound
        let rawMaximum = advertisedAmpMaximum > 0
            ? min(max(advertisedAmpMaximum, 1), 64)
            : Self.fallbackAmperageRange.upperBound
        let ampMaximum = max(ampMinimum, rawMaximum)

        targetRange = targetMinimum...100
        amperageRange = ampMinimum...ampMaximum
    }

    func targetPresets(step: Int = 10) -> [Int] {
        guard step > 0 else { return [targetRange.lowerBound, targetRange.upperBound] }
        var values = [targetRange.lowerBound]
        var value = ((targetRange.lowerBound + step - 1) / step) * step
        while value < targetRange.upperBound {
            if value > targetRange.lowerBound { values.append(value) }
            value += step
        }
        if values.last != targetRange.upperBound { values.append(targetRange.upperBound) }
        return values
    }

    func amperagePresets(candidates: [Int] = [6, 8, 10, 13, 16, 20, 24, 32]) -> [Int] {
        candidates.filter(amperageRange.contains)
    }
}
