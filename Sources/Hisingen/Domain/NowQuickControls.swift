import Foundation

/// Which of the reader's chosen Now controls this car and their feature switches can use.
///
/// The rule is deliberately uneven. Locks and climate are the two states a reader expects to see
/// even with remote commands switched off, and charging is a state rather than a command, so it
/// stays for any car with electric range. Every other control is a command, and a control the car
/// does not report would only fail after the tap.
extension NowQuickControl {
    static func applicable(
        _ chosen: [NowQuickControl],
        features: Set<AppFeature>,
        hasElectricRange: Bool,
        profile: VehicleCapabilityProfile,
        supportsTrunkControl: Bool
    ) -> [NowQuickControl] {
        chosen.filter { control in
            guard features.contains(control.feature) else {
                return control == .locks || control == .climate
                    || (control == .charging && hasElectricRange)
            }
            switch control {
            case .locks, .climate: return true
            case .charging: return hasElectricRange
            case .chargeLimit: return hasElectricRange && profile.permits(.chargeTarget)
            case .currentLimit: return hasElectricRange && profile.permits(.chargingCurrentLimit)
            case .airCleaning: return profile.permits(.preCleaning)
            case .windows: return profile.permits(.windows)
            case .locate: return profile.permits(.honkAndFlash)
            case .tailgate: return supportsTrunkControl
            }
        }
    }
}
