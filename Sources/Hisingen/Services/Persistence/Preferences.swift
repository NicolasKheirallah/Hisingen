

import Foundation
import SwiftUI


enum InterfaceLanguage: String, CaseIterable {
    case system
    case english
    case swedish
    case german
    case norwegian
    case danish
    case dutch
    case french
    case spanish
    case italian
    case finnish
    case portuguese
    case polish
    case chinese
    case korean

    var languageCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .swedish: return "sv"
        case .german: return "de"
        case .norwegian: return "nb"
        case .danish: return "da"
        case .dutch: return "nl"
        case .french: return "fr"
        case .spanish: return "es"
        case .italian: return "it"
        case .finnish: return "fi"
        case .portuguese: return "pt"
        case .polish: return "pl"
        case .chinese: return "zh"
        case .korean: return "ko"
        }
    }

    var title: String {
        switch self {
        case .system: return L10n.text("System Default")
        case .english: return L10n.text("English")
        case .swedish: return L10n.text("Swedish")
        case .german: return L10n.text("German")
        case .norwegian: return L10n.text("Norwegian")
        case .danish: return L10n.text("Danish")
        case .dutch: return L10n.text("Dutch")
        case .french: return L10n.text("French")
        case .spanish: return L10n.text("Spanish")
        case .italian: return L10n.text("Italian")
        case .finnish: return L10n.text("Finnish")
        case .portuguese: return L10n.text("Portuguese")
        case .polish: return L10n.text("Polish")
        case .chinese: return L10n.text("Chinese (Simplified)")
        case .korean: return L10n.text("Korean")
        }
    }

    var effectiveLanguageCode: String {
        languageCode ?? Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "en"
    }
}

enum MenuBarStyle: String, CaseIterable, Codable {
    case battery = "battery"
    case batteryAndRange = "battery-and-range"
    case chargingAware = "charging-aware"
    case compactCharging = "compact-charging"
    case batteryAndPower = "battery-and-power"
    case range = "range"
    case iconOnly = "icon-only"
    case lockAndBattery = "lock-and-battery"

    var title: String {
        switch self {
        case .battery: return L10n.text("Battery Percentage")
        case .batteryAndRange: return L10n.text("Battery and Range")
        case .chargingAware: return L10n.text("Charging Aware (Time to Full)")
        case .compactCharging: return L10n.text("Compact Charging")
        case .batteryAndPower: return L10n.text("Battery and Power")
        case .range: return L10n.text("Range")
        case .iconOnly: return L10n.text("Icon Only (Minimal)")
        case .lockAndBattery: return L10n.text("Lock Status and Battery")
        }
    }
}


enum CarRenderAngle: Int, CaseIterable, Codable, Sendable {
    case frontThreeQuarter = 1
    case frontDirect = 2
    case sideProfile = 0
    case rearThreeQuarter = 3
    case rearProfile = 4
    case overhead = 5

    var title: String {
        switch self {
        case .frontThreeQuarter: return L10n.text("Front Three-Quarter")
        case .frontDirect: return L10n.text("Front Direct")
        case .sideProfile: return L10n.text("Side Profile")
        case .rearThreeQuarter: return L10n.text("Rear Three-Quarter")
        case .rearProfile: return L10n.text("Rear Profile")
        case .overhead: return L10n.text("Overhead (Top-Down)")
        }
    }

    var symbol: String {
        switch self {
        case .frontThreeQuarter: return "car.side.front.open.fill"
        case .frontDirect: return "car.front.waves.up.fill"
        case .sideProfile: return "car.side.fill"
        case .rearThreeQuarter: return "car.side.rear.open.fill"
        case .rearProfile: return "car.rear.and.tire.marks"
        case .overhead: return "car.top.door.front.left.open.fill"
        }
    }
}

enum VehicleModelBadgePosition: String, CaseIterable, Codable, Sendable {
    case inlineHeader = "inline-header"
    case topRightOverlay = "top-right-overlay"
    case topLeftOverlay = "top-left-overlay"
    case subheadline = "subheadline"
    case hidden = "hidden"

    var title: String {
        switch self {
        case .inlineHeader: return L10n.text("Inline with Greeting (Top Right)")
        case .topRightOverlay: return L10n.text("Over Vehicle Image (Top Right)")
        case .topLeftOverlay: return L10n.text("Over Vehicle Image (Top Left)")
        case .subheadline: return L10n.text("Below Greeting")
        case .hidden: return L10n.text("Hidden")
        }
    }
}

enum RegistrationNumberBadgePosition: String, CaseIterable, Codable, Sendable {
    case belowGreeting = "below-greeting"
    case platePill = "plate-pill"
    case inlineHeader = "inline-header"
    case topRightOverlay = "top-right-overlay"
    case topLeftOverlay = "top-left-overlay"
    case hidden = "hidden"

    var title: String {
        switch self {
        case .belowGreeting: return L10n.text("Below Greeting")
        case .platePill: return L10n.text("License Plate Style (Below Greeting)")
        case .inlineHeader: return L10n.text("Inline with Greeting (Top Right)")
        case .topRightOverlay: return L10n.text("Over Vehicle Image (Top Right)")
        case .topLeftOverlay: return L10n.text("Over Vehicle Image (Top Left)")
        case .hidden: return L10n.text("Hidden")
        }
    }
}

enum VehicleLabelFormat: String, CaseIterable, Codable, Sendable {
    case registration = "registration"
    case nickname = "nickname"
    case modelAndYear = "model-and-year"
    case modelOnly = "model-only"
    case nicknameAndRegistration = "nickname-and-registration"
    case registrationAndModel = "registration-and-model"

    var title: String {
        switch self {
        case .registration: return L10n.text("Registration / License Plate")
        case .nickname: return L10n.text("Nickname")
        case .modelAndYear: return L10n.text("Model Name & Year")
        case .modelOnly: return L10n.text("Model Name Only")
        case .nicknameAndRegistration: return L10n.text("Nickname & Registration")
        case .registrationAndModel: return L10n.text("Registration & Model")
        }
    }
}

enum AppearanceMode: String, CaseIterable, Codable, Sendable {
    case system = "system"
    case light = "light"
    case dark = "dark"

    var title: String {
        switch self {
        case .system: return L10n.text("System (Automatic)")
        case .light: return L10n.text("Light")
        case .dark: return L10n.text("Dark")
        }
    }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum ThemeCategory: String, CaseIterable, Sendable {
    case all = "all"
    case brand = "brand"
    case dark = "dark"
    case sport = "sport"
    case nature = "nature"

    var title: String {
        switch self {
        case .all: return L10n.text("All")
        case .brand: return L10n.text("Brand")
        case .dark: return L10n.text("OLED & Dark")
        case .sport: return L10n.text("Performance")
        case .nature: return L10n.text("Nature")
        }
    }
}

enum AppTheme: String, CaseIterable, Codable, Sendable {
    case hisingen
    case polestar
    case volvo
    case nordicNight
    case aurora
    case swedishGold
    case cyanRacing
    case forest
    case sandDune

    var title: String {
        switch self {
        case .hisingen: return L10n.text("Hisingen Glass")
        case .polestar: return L10n.text("Polestar Minimal")
        case .volvo: return L10n.text("Volvo Iron")
        case .nordicNight: return L10n.text("Nordic Night")
        case .aurora: return L10n.text("Aurora Borealis")
        case .swedishGold: return L10n.text("Swedish Gold")
        case .cyanRacing: return L10n.text("Cyan Racing")
        case .forest: return L10n.text("Gothenburg Forest")
        case .sandDune: return L10n.text("Sand Dune")
        }
    }

    var subtitle: String {
        switch self {
        case .hisingen: return L10n.text("Rounded cards, translucent materials, amber accents")
        case .polestar: return L10n.text("Monochrome panels, sharp corners, Scandinavian minimalism")
        case .volvo: return L10n.text("Volvo iron blue accent, soft panels, light/bold contrast")
        case .nordicNight: return L10n.text("Pitch OLED black, electric cyan glow, modern dark style")
        case .aurora: return L10n.text("Deep midnight slate with radiant northern lights emerald")
        case .swedishGold: return L10n.text("Polestar BST Öhlins Swedish Gold, dark charcoal luxury")
        case .cyanRacing: return L10n.text("Cyan Racing championship blue, crisp track geometry")
        case .forest: return L10n.text("Swedish pine and eucalyptus earth tones, organic soft feel")
        case .sandDune: return L10n.text("Warm desert sand and titanium champagne minimalism")
        }
    }

    var category: ThemeCategory {
        switch self {
        case .hisingen, .polestar, .volvo: return .brand
        case .nordicNight: return .dark
        case .aurora: return .nature
        case .swedishGold, .cyanRacing: return .sport
        case .forest: return .nature
        case .sandDune: return .brand
        }
    }

    var accentColorHex: String {
        switch self {
        case .hisingen: return "#E56E23"
        case .polestar: return "#E56E23"
        case .volvo: return "#005B94"
        case .nordicNight: return "#00E5FF"
        case .aurora: return "#00E676"
        case .swedishGold: return "#D4AF37"
        case .cyanRacing: return "#0090D0"
        case .forest: return "#4CAF50"
        case .sandDune: return "#C5A059"
        }
    }

    var previewHexColors: [String] {
        switch self {
        case .hisingen:
            return ["#E56E23", "#FFA726", "#424242"]
        case .polestar:
            return ["#E56E23", "#FFFFFF", "#141416"]
        case .volvo:
            return ["#005B94", "#003057", "#F4F6F9"]
        case .nordicNight:
            return ["#00E5FF", "#0A192F", "#000000"]
        case .aurora:
            return ["#00E676", "#1DE9B6", "#0B132B"]
        case .swedishGold:
            return ["#D4AF37", "#E5A93C", "#1E1E24"]
        case .cyanRacing:
            return ["#0090D0", "#00B4D8", "#0A0F1A"]
        case .forest:
            return ["#2E7D32", "#4CAF50", "#0D1F0F"]
        case .sandDune:
            return ["#C5A059", "#E0C097", "#1E1B18"]
        }
    }
}

enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case kilometers = "kilometers"
    case miles = "miles"

    var title: String {
        self == .kilometers ? L10n.text("Kilometers (km)") : L10n.text("Miles (mi)")
    }

    var suffix: String { self == .kilometers ? "km" : "mi" }

    func convert(km: Int) -> Int {
        self == .kilometers ? km : Int((Double(km) * 0.621371).rounded())
    }

    func convert(km: Double) -> Double {
        self == .kilometers ? km : km * 0.621371
    }
}

enum TemperatureUnit: String, CaseIterable, Codable, Sendable {
    case celsius
    case fahrenheit

    var title: String {
        self == .celsius ? L10n.text("Celsius (°C)") : L10n.text("Fahrenheit (°F)")
    }

    var suffix: String { self == .celsius ? "°C" : "°F" }

    func convert(celsius: Double) -> Double {
        self == .celsius ? celsius : (celsius * 9 / 5) + 32
    }
}

enum PressureUnit: String, CaseIterable, Codable, Sendable {
    case kilopascals
    case psi

    var title: String {
        self == .kilopascals ? L10n.text("Kilopascals (kPa)") : L10n.text("PSI")
    }

    var suffix: String { self == .kilopascals ? "kPa" : "psi" }

    func convert(kilopascals: Double) -> Double {
        self == .kilopascals ? kilopascals : kilopascals * 0.145037738
    }
}

enum FuelVolumeUnit: String, CaseIterable, Codable, Sendable {
    case liters = "liters"
    case gallonsUS = "gallons_us"
    case gallonsUK = "gallons_uk"

    var title: String {
        switch self {
        case .liters: return L10n.text("Liters (L)")
        case .gallonsUS: return L10n.text("Gallons US (gal)")
        case .gallonsUK: return L10n.text("Gallons Imperial (UK gal)")
        }
    }

    var suffix: String {
        switch self {
        case .liters: return "L"
        case .gallonsUS: return "gal"
        case .gallonsUK: return "UK gal"
        }
    }

    func convert(liters: Double) -> Double {
        switch self {
        case .liters: return liters
        case .gallonsUS: return liters * 0.264172052
        case .gallonsUK: return liters * 0.219969248
        }
    }
}

enum FuelEconomyUnit: String, CaseIterable, Codable, Sendable {
    case litersPer100Km = "l_per_100km"
    case milesPerGallonUS = "mpg_us"
    case milesPerGallonUK = "mpg_uk"
    case kmPerLiter = "km_per_l"

    var title: String {
        switch self {
        case .litersPer100Km: return L10n.text("L/100 km")
        case .milesPerGallonUS: return L10n.text("MPG (US)")
        case .milesPerGallonUK: return L10n.text("MPG (UK)")
        case .kmPerLiter: return L10n.text("km/L")
        }
    }

    var suffix: String {
        switch self {
        case .litersPer100Km: return "L/100km"
        case .milesPerGallonUS: return "mpg"
        case .milesPerGallonUK: return "mpg (UK)"
        case .kmPerLiter: return "km/L"
        }
    }

    func format(lPer100Km: Double) -> String {
        guard lPer100Km > 0 else { return "— \(suffix)" }
        switch self {
        case .litersPer100Km:
            return String(format: "%.1f L/100km", lPer100Km)
        case .milesPerGallonUS:
            let mpg = 235.214583 / lPer100Km
            return String(format: "%.1f mpg", mpg)
        case .milesPerGallonUK:
            let mpg = 282.481 / lPer100Km
            return String(format: "%.1f mpg (UK)", mpg)
        case .kmPerLiter:
            let kml = 100.0 / lPer100Km
            return String(format: "%.1f km/L", kml)
        }
    }
}

enum EnergyConsumptionUnit: String, CaseIterable, Codable, Sendable {
    case kwhPer100Km = "kwh_per_100km"
    case kwhPer100Miles = "kwh_per_100mi"
    case milesPerKwh = "mi_per_kwh"

    var title: String {
        switch self {
        case .kwhPer100Km: return L10n.text("kWh/100 km")
        case .kwhPer100Miles: return L10n.text("kWh/100 mi")
        case .milesPerKwh: return L10n.text("mi/kWh")
        }
    }

    func format(kwhPer100Km value: Double) -> String {
        guard value > 0 else { return "—" }
        switch self {
        case .kwhPer100Km:
            return String(format: "%.1f kWh/100 km", value)
        case .kwhPer100Miles:
            return String(format: "%.1f kWh/100 mi", value * 1.609344)
        case .milesPerKwh:
            return String(format: "%.2f mi/kWh", 62.1371192 / value)
        }
    }
}
