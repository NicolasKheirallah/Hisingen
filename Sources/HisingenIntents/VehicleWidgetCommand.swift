import Foundation

/// The commands the widget-facing intents can ask Hisingen to send.
///
/// The enum lives with the intents rather than in the app because the widget extension
/// cannot link the app executable: both targets link this module, and the command names
/// therefore cannot drift between them.
public enum VehicleWidgetCommand: String, Codable, Sendable, CaseIterable {
    case lock
    case unlock
    case startClimate
    case refresh
    case honkAndFlash
    case startChargingOverride
    case startPreCleaning
}
