import Foundation

struct VehicleControlSettings: Codable, Equatable, Sendable {
    var climateTimerMaximum: Int?
    var repeatedClimateTimers: Bool?
    var singleClimateTimers: Bool?
    var chargeLocationMaximum: Int?
    var locationAmperage: Bool?
    var locationOptimization: Bool?
    var temperatureMinimum: Int?
    var temperatureMaximum: Int?
    var frontSeatSettings: Bool?
    var rearSeatSettings: Bool?
    var steeringWheelSettings: Bool?

    var temperatureRange: ClosedRange<Double> {
        let minimum = max(16, temperatureMinimum ?? 16)
        let maximum = min(30, temperatureMaximum ?? 30)
        guard minimum <= maximum else { return 16...30 }
        return Double(minimum)...Double(maximum)
    }

    func rejection(for command: RemoteCommand, state: VehicleState? = nil,
                   bounds: VehicleChargeBounds? = nil) -> String? {
        let chargingBounds = bounds ?? VehicleChargeBounds(capabilities: state?.otaCapabilities)
        func amperageError(_ amps: Int) -> String? {
            guard amps != 0, !chargingBounds.amperageRange.contains(amps) else { return nil }
            return L10n.format("The charging current must be between %d A and %d A on this vehicle.",
                               chargingBounds.amperageRange.lowerBound, chargingBounds.amperageRange.upperBound)
        }
        switch command {
        case .setClimateTimer(let schedule):
            if let reason = schedule.validationMessage(expectedKind: .climate) { return reason }
            if !schedule.weekdays.isEmpty, repeatedClimateTimers == false {
                return L10n.text("This vehicle does not advertise repeating climate timers.")
            }
            if schedule.weekdays.isEmpty, singleClimateTimers == false {
                return L10n.text("This vehicle does not advertise single climate timers.")
            }
            if let maximum = climateTimerMaximum, let state,
               schedule.backendID == nil, schedule.index == nil,
               state.climateTimers.count >= maximum {
                return L10n.format("The vehicle allows at most %d climate timers.", maximum)
            }
        case .setGlobalChargeTimer(let schedule):
            return schedule.validationMessage(expectedKind: .globalCharging)
        case .createChargeLocationAtCar(_, let amps, _, let optimized):
            if amps != 0, locationAmperage == false { return L10n.text("Location-specific current limits are not supported.") }
            if let reason = amperageError(amps) { return reason }
            if optimized, locationOptimization == false {
                return L10n.text("Vehicle-managed optimized charging is not supported.")
            }
            if let maximum = chargeLocationMaximum, let state,
               state.energy.locations.filter(\.isSavedLocation).count >= maximum {
                return L10n.format("The vehicle allows at most %d charging locations.", maximum)
            }
        case .updateChargeLocationAmpLimit(_, let amps):
            if locationAmperage == false { return L10n.text("Location-specific current limits are not supported.") }
            return amperageError(amps)
        case .setChargeLocationOptimisedCharging:
            if locationOptimization == false { return L10n.text("Vehicle-managed optimized charging is not supported.") }
        case .startClimate(let temperature, let frontLeft, let frontRight, let rearLeft, let rearRight, let steering):
            if temperature != 0 {
                if let minimum = temperatureMinimum, temperature < Float(minimum) {
                    return L10n.format("The minimum supported temperature is %d °C.", minimum)
                }
                if let maximum = temperatureMaximum, temperature > Float(maximum) {
                    return L10n.format("The maximum supported temperature is %d °C.", maximum)
                }
            }
            if frontSeatSettings == false, frontLeft != .unspecified || frontRight != .unspecified {
                return L10n.text("Front seat settings are managed by the vehicle.")
            }
            if rearSeatSettings == false, rearLeft != .unspecified || rearRight != .unspecified {
                return L10n.text("Rear seat settings are managed by the vehicle.")
            }
            if steeringWheelSettings == false, steering != .unspecified {
                return L10n.text("Steering-wheel settings are managed by the vehicle.")
            }
        default: break
        }
        return nil
    }
}
