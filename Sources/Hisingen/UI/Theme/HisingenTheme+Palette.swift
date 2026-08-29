import SwiftUI
import AppKit

@MainActor
extension HisingenTheme {

    // MARK: - Brand Core Colors

    /// Polestar signature Swedish Gold & Amber highlight (#E56E23)
    static let polestarAmber = Color(red: 229/255, green: 110/255, blue: 35/255)

    /// Official Volvo Digital / Electric Blue
    static let volvoBlue = Color(
        light: NSColor(red: 0x00/255, green: 0x5b/255, blue: 0x94/255, alpha: 1),
        dark: NSColor(red: 0x38/255, green: 0xbd/255, blue: 0xf8/255, alpha: 1)
    )

    /// Official Volvo Heritage Iron Navy (#003057)
    static let volvoNavy = Color(
        light: NSColor(red: 0x00/255, green: 0x30/255, blue: 0x57/255, alpha: 1),
        dark: NSColor(red: 0x1e/255, green: 0x3a/255, blue: 0x5f/255, alpha: 1)
    )

    // MARK: - Semantic Surface & Text Tokens

    static var canvas: Color {
        switch theme {
        case .volvo:
            return Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.95, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.00, green: 0.00, blue: 0.00, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.95, green: 0.99, blue: 0.97, alpha: 1), dark: NSColor(red: 0.04, green: 0.07, blue: 0.12, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.94, green: 0.98, blue: 1.0, alpha: 1), dark: NSColor(red: 0.04, green: 0.06, blue: 0.10, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.95, green: 0.98, blue: 0.95, alpha: 1), dark: NSColor(red: 0.04, green: 0.09, blue: 0.05, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.98, green: 0.97, blue: 0.94, alpha: 1), dark: NSColor(red: 0.09, green: 0.08, blue: 0.07, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1), dark: NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
        case .polestar:
            return Color(light: NSColor(red: 0.94, green: 0.95, blue: 0.96, alpha: 1), dark: NSColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1))
        }
    }

    static var ink: Color {
        switch theme {
        case .polestar: return Color(light: NSColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), dark: NSColor(red: 0.96, green: 0.96, blue: 0.98, alpha: 1))
        case .volvo: return Color(light: NSColor(red: 0.06, green: 0.09, blue: 0.15, alpha: 1), dark: NSColor(red: 0.97, green: 0.98, blue: 1.0, alpha: 1))
        case .nordicNight: return Color(light: NSColor(red: 0.02, green: 0.12, blue: 0.20, alpha: 1), dark: NSColor.white)
        case .aurora: return Color(light: NSColor(red: 0.02, green: 0.18, blue: 0.12, alpha: 1), dark: NSColor.white)
        case .swedishGold: return Color(light: NSColor(red: 0.14, green: 0.11, blue: 0.04, alpha: 1), dark: NSColor.white)
        case .cyanRacing: return Color(light: NSColor(red: 0.03, green: 0.12, blue: 0.22, alpha: 1), dark: NSColor.white)
        case .forest: return Color(light: NSColor(red: 0.06, green: 0.16, blue: 0.08, alpha: 1), dark: NSColor.white)
        case .sandDune: return Color(light: NSColor(red: 0.14, green: 0.12, blue: 0.09, alpha: 1), dark: NSColor.white)
        case .hisingen: return Color(light: NSColor(red: 0.06, green: 0.08, blue: 0.12, alpha: 1), dark: NSColor(white: 0.98, alpha: 1))
        }
    }

    static var inkMuted: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.42, green: 0.42, blue: 0.46, alpha: 1), dark: NSColor(red: 0.65, green: 0.65, blue: 0.70, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.35, green: 0.42, blue: 0.50, alpha: 1), dark: NSColor(red: 0.60, green: 0.68, blue: 0.76, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.30, green: 0.75, blue: 0.95, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.06, green: 0.45, blue: 0.32, alpha: 1), dark: NSColor(red: 0.28, green: 0.82, blue: 0.60, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.48, green: 0.36, blue: 0.10, alpha: 1), dark: NSColor(red: 0.90, green: 0.82, blue: 0.55, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.08, green: 0.42, blue: 0.58, alpha: 1), dark: NSColor(red: 0.45, green: 0.80, blue: 0.98, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.18, green: 0.42, blue: 0.22, alpha: 1), dark: NSColor(red: 0.52, green: 0.88, blue: 0.65, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.42, green: 0.36, blue: 0.30, alpha: 1), dark: NSColor(red: 0.82, green: 0.76, blue: 0.70, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.38, green: 0.44, blue: 0.52, alpha: 1), dark: NSColor(red: 0.65, green: 0.70, blue: 0.78, alpha: 1))
        }
    }

    static var hairline: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.85, green: 0.86, blue: 0.88, alpha: 1), dark: NSColor(red: 0.18, green: 0.18, blue: 0.22, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.86, green: 0.89, blue: 0.93, alpha: 1), dark: NSColor(red: 0.16, green: 0.20, blue: 0.28, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.0, green: 0.60, blue: 0.80, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 0.25))
        case .aurora:
            return Color(light: NSColor(red: 0.0, green: 0.65, blue: 0.35, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.90, blue: 0.46, alpha: 0.25))
        case .swedishGold:
            return Color(light: NSColor(red: 0.72, green: 0.52, blue: 0.05, alpha: 0.35), dark: NSColor(red: 0.83, green: 0.69, blue: 0.22, alpha: 0.30))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.0, green: 0.48, blue: 0.78, alpha: 0.35), dark: NSColor(red: 0.0, green: 0.56, blue: 0.82, alpha: 0.30))
        case .forest:
            return Color(light: NSColor(red: 0.14, green: 0.48, blue: 0.18, alpha: 0.35), dark: NSColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 0.25))
        case .sandDune:
            return Color(light: NSColor(red: 0.65, green: 0.50, blue: 0.25, alpha: 0.35), dark: NSColor(red: 0.77, green: 0.63, blue: 0.35, alpha: 0.30))
        case .hisingen:
            return Color(light: NSColor(white: 0.0, alpha: 0.08), dark: NSColor(white: 1.0, alpha: 0.12))
        }
    }

    static var accent: Color {
        switch theme {
        case .polestar:
            return Color(light: NSColor(red: 0.90, green: 0.43, blue: 0.14, alpha: 1), dark: NSColor(red: 1.0, green: 0.54, blue: 0.24, alpha: 1))
        case .volvo:
            return Color(light: NSColor(red: 0.0, green: 0.36, blue: 0.58, alpha: 1), dark: NSColor(red: 0.22, green: 0.74, blue: 0.97, alpha: 1))
        case .hisingen:
            return Color(light: NSColor(red: 0.88, green: 0.38, blue: 0.05, alpha: 1), dark: NSColor(red: 0.96, green: 0.50, blue: 0.15, alpha: 1))
        case .nordicNight:
            return Color(light: NSColor(red: 0.0, green: 0.55, blue: 0.75, alpha: 1), dark: NSColor(red: 0.0, green: 0.90, blue: 1.0, alpha: 1))
        case .aurora:
            return Color(light: NSColor(red: 0.0, green: 0.60, blue: 0.35, alpha: 1), dark: NSColor(red: 0.0, green: 0.92, blue: 0.50, alpha: 1))
        case .swedishGold:
            return Color(light: NSColor(red: 0.72, green: 0.52, blue: 0.05, alpha: 1), dark: NSColor(red: 0.88, green: 0.72, blue: 0.22, alpha: 1))
        case .cyanRacing:
            return Color(light: NSColor(red: 0.0, green: 0.48, blue: 0.78, alpha: 1), dark: NSColor(red: 0.0, green: 0.65, blue: 0.95, alpha: 1))
        case .forest:
            return Color(light: NSColor(red: 0.14, green: 0.48, blue: 0.18, alpha: 1), dark: NSColor(red: 0.30, green: 0.78, blue: 0.35, alpha: 1))
        case .sandDune:
            return Color(light: NSColor(red: 0.65, green: 0.50, blue: 0.25, alpha: 1), dark: NSColor(red: 0.82, green: 0.68, blue: 0.42, alpha: 1))
        }
    }
}
