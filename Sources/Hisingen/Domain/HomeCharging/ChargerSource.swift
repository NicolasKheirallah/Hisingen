import Foundation

/// Where Hisingen gets one home charger's readings and sends its commands.
///
/// Home Assistant is a bridge: it reaches any charger it has an integration for, runs plans around
/// the clock and keeps sessions while the Mac is closed. Direct sources use the vendor's cloud.
enum ChargerSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case homeAssistant
    case easee
    case zaptec
    case nexBlue = "nexblue"

    var id: String { rawValue }

    var providerName: String {
        switch self {
        case .homeAssistant: return "Home Assistant"
        case .easee: return "Easee"
        case .zaptec: return "Zaptec"
        case .nexBlue: return "NexBlue"
        }
    }

    /// Signs in with the vendor account instead of a Home Assistant token.
    var isDirect: Bool { self != .homeAssistant }

    /// The Hisingen component for Home Assistant owns adaptive charging plans.
    var supportsPlans: Bool { self == .homeAssistant }
}

/// The login a direct charger needs. It lives in the Keychain and nowhere else: never in
/// preferences, exports, logs or error text.
struct DirectChargerCredentials: Codable, Equatable, Sendable, CustomStringConvertible {
    var username: String
    var password: String

    /// The description is what a stray `print` or `String(describing:)` would show.
    var description: String { "DirectChargerCredentials(redacted)" }

    var isComplete: Bool {
        !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
    }
}

/// A charger an account can reach, as the vendor lists it.
struct DirectChargerSummary: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// The site or installation the vendor files it under, when there is one.
    var siteName: String?
    var isOnline: Bool?

    var displayName: String {
        let base = name.isEmpty ? id : name
        guard let siteName, !siteName.isEmpty, siteName != base else { return base }
        return "\(base) · \(siteName)"
    }
}
