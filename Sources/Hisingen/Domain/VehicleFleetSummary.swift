import Foundation

struct VehicleFleetSummary {
    let rangeKm: Int?
    let odometerKm: Int?
    let chargingCount: Int
    let chargingPowerWatts: Int
    let chargingCoverage: Int

    init(states: [VehicleState], now: Date = Date()) {
        let ranges = states.filter { $0.hasFreshReading(.range, now: now) }.compactMap(\.primaryRangeKm)
        rangeKm = ranges.isEmpty ? nil : ranges.reduce(0, +)
        let odometers = states.filter { $0.hasFreshReading(.odometer, now: now) }.compactMap(\.maintenance.odometerKm)
        odometerKm = odometers.isEmpty ? nil : odometers.reduce(0, +)
        let known = states.filter {
            guard $0.hasFreshReading(.charging, now: now) else { return false }
            if case .unknown = $0.energy.chargingState { return false }
            return true
        }
        let charging = known.filter(\.isCharging)
        chargingCount = charging.count
        chargingPowerWatts = charging.compactMap(\.energy.powerWatts).filter { $0 > 0 }.reduce(0, +)
        chargingCoverage = known.count
    }
}
