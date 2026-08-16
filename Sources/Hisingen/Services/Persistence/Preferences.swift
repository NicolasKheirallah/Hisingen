

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

@MainActor
enum Preferences {
    private static let d = UserDefaults.standard

    static var email: String {
        get { d.string(forKey: "polestar_email") ?? "" }
        set { d.set(newValue, forKey: "polestar_email") }
    }


    static var activeBrand: VehicleBrand {
        get { VehicleBrand(rawValue: d.string(forKey: "active_vehicle_brand") ?? "") ?? .polestar }
        set {
            d.set(newValue.rawValue, forKey: "active_vehicle_brand")
            syncAppThemeStorageKey()
        }
    }


    static var volvoClientID: String {
        get {
            let saved = d.string(forKey: "volvo_client_id") ?? ""
            if !saved.isEmpty { return saved }
            return BuiltinVolvoSecrets.clientID
        }
        set { d.set(newValue, forKey: "volvo_client_id") }
    }


    static var vin: String {
        get { d.string(forKey: vinKey) ?? "" }
        set {
            d.set(newValue, forKey: vinKey)
            syncAppThemeStorageKey()
        }
    }

    private static var vinKey: String {
        vinKey(for: activeBrand)
    }

    private static func vinKey(for brand: VehicleBrand) -> String {
        brand == .volvo ? "volvo_vin" : "polestar_vin"
    }


    static func vin(for brand: VehicleBrand) -> String {
        d.string(forKey: vinKey(for: brand)) ?? ""
    }

    static func setVin(_ newVin: String, for brand: VehicleBrand) {
        d.set(newVin, forKey: vinKey(for: brand))
        if brand == activeBrand {
            syncAppThemeStorageKey()
        }
    }


    static func lastVehicleLabel(for brand: VehicleBrand) -> String {
        let storedVIN = vin(for: brand)
        guard !storedVIN.isEmpty else { return brand.displayName }
        let nickname = vehicleNickname(for: storedVIN)
        return nickname.isEmpty ? storedVIN : nickname
    }


    static func hasResumableSession(for brand: VehicleBrand) -> Bool {
        switch brand {
        case .polestar:
            if d.bool(forKey: "has_polestar_session") { return true }
            if !email.isEmpty && d.bool(forKey: "has_polestar_password") { return true }
            return !email.isEmpty && ((try? Keychain.readSessionToken()) ?? nil)?.isEmpty == false
        case .volvo:
            if !volvoClientID.isEmpty && d.bool(forKey: "has_volvo_session") { return true }
            guard !volvoClientID.isEmpty else { return false }
            return ((try? Keychain.readVolvoSessionToken()) ?? nil)?.isEmpty == false
        }
    }

    static func vehicleNickname(for vin: String) -> String {
        let normalizedVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedVIN.isEmpty else { return "" }
        if let nicknames = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String],
           let nickname = nicknames[normalizedVIN] {
            return nickname
        }
        guard normalizedVIN == self.vin.uppercased() else { return "" }
        return d.string(forKey: "polestar_vehicle_nickname") ?? ""
    }

    static func setVehicleNickname(_ nickname: String, for vin: String) {
        let normalizedVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalizedVIN.isEmpty else { return }
        var nicknames = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String] ?? [:]
        let normalizedNickname = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedNickname.isEmpty {
            nicknames.removeValue(forKey: normalizedVIN)
        } else {
            nicknames[normalizedVIN] = normalizedNickname
        }
        d.set(nicknames, forKey: "polestar_vehicle_nicknames_v1")
        if normalizedVIN == self.vin.uppercased() {
            d.removeObject(forKey: "polestar_vehicle_nickname")
        }
    }

    static var menuBarStyle: MenuBarStyle {
        get {
            let raw = d.string(forKey: "statusbar_display_option") ?? ""
            if let value = MenuBarStyle(rawValue: raw) { return value }
            switch raw {
            case "Range", "Range (km)": return .range
            case "Charge Time": return .chargingAware
            case "Battery and Range": return .batteryAndRange
            case "Compact Charging": return .compactCharging
            case "Battery and Power": return .batteryAndPower
            default: return .battery
            }
        }
        set { d.set(newValue.rawValue, forKey: "statusbar_display_option") }
    }

    static var carRenderAngle: CarRenderAngle {
        get {
            let raw = d.object(forKey: "car_render_angle") as? Int ?? 0
            return CarRenderAngle(rawValue: raw) ?? .frontThreeQuarter
        }
        set { d.set(newValue.rawValue, forKey: "car_render_angle") }
    }

    static var vehicleModelBadgePosition: VehicleModelBadgePosition {
        get {
            let raw = d.string(forKey: "vehicle_model_badge_position") ?? ""
            return VehicleModelBadgePosition(rawValue: raw) ?? .inlineHeader
        }
        set { d.set(newValue.rawValue, forKey: "vehicle_model_badge_position") }
    }

    static var registrationBadgePosition: RegistrationNumberBadgePosition {
        get {
            let raw = d.string(forKey: "registration_badge_position") ?? ""
            return RegistrationNumberBadgePosition(rawValue: raw) ?? .belowGreeting
        }
        set { d.set(newValue.rawValue, forKey: "registration_badge_position") }
    }

    static var vehicleLabelFormat: VehicleLabelFormat {
        get {
            let raw = d.string(forKey: "vehicle_label_format") ?? ""
            return VehicleLabelFormat(rawValue: raw) ?? .modelAndYear
        }
        set { d.set(newValue.rawValue, forKey: "vehicle_label_format") }
    }

    static func formattedVehicleTitle(
        vin: String,
        modelName: String?,
        modelYear: String?,
        registrationNo: String?,
        fallbackBrand: VehicleBrand? = nil,
        format: VehicleLabelFormat? = nil
    ) -> String {
        let selectedFormat = format ?? vehicleLabelFormat
        let brand = fallbackBrand ?? activeBrand
        let nickname = vehicleNickname(for: vin).trimmingCharacters(in: .whitespacesAndNewlines)
        let reg = registrationNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let year = modelYear?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelAndYr = [model.isEmpty ? nil : model, year.isEmpty ? nil : year].compactMap { $0 }.joined(separator: " · ")

        switch selectedFormat {
        case .registration:
            if !reg.isEmpty { return reg }
            if !nickname.isEmpty { return nickname }
            if !modelAndYr.isEmpty { return modelAndYr }
            return !model.isEmpty ? model : brand.displayName

        case .nickname:
            if !nickname.isEmpty { return nickname }
            if !reg.isEmpty { return reg }
            if !modelAndYr.isEmpty { return modelAndYr }
            return !model.isEmpty ? model : brand.displayName

        case .modelAndYear:
            if !modelAndYr.isEmpty { return modelAndYr }
            if !model.isEmpty { return model }
            if !nickname.isEmpty { return nickname }
            if !reg.isEmpty { return reg }
            return brand.displayName

        case .modelOnly:
            if !model.isEmpty { return model }
            if !modelAndYr.isEmpty { return modelAndYr }
            if !nickname.isEmpty { return nickname }
            if !reg.isEmpty { return reg }
            return brand.displayName

        case .nicknameAndRegistration:
            if !nickname.isEmpty && !reg.isEmpty { return "\(nickname) (\(reg))" }
            if !nickname.isEmpty { return nickname }
            if !reg.isEmpty { return reg }
            if !modelAndYr.isEmpty { return modelAndYr }
            return brand.displayName

        case .registrationAndModel:
            if !reg.isEmpty && !model.isEmpty { return "\(reg) · \(model)" }
            if !reg.isEmpty { return reg }
            if !modelAndYr.isEmpty { return modelAndYr }
            return !nickname.isEmpty ? nickname : brand.displayName
        }
    }

    static var distanceUnit: DistanceUnit {
        get {
            let raw = d.string(forKey: "distance_unit") ?? ""
            if let value = DistanceUnit(rawValue: raw) { return value }
            return raw == "Miles (mi)" ? .miles : .kilometers
        }
        set { d.set(newValue.rawValue, forKey: "distance_unit") }
    }

    static var fuelVolumeUnit: FuelVolumeUnit {
        get {
            let raw = d.string(forKey: "fuel_volume_unit") ?? ""
            return FuelVolumeUnit(rawValue: raw) ?? .liters
        }
        set { d.set(newValue.rawValue, forKey: "fuel_volume_unit") }
    }

    static var fuelEconomyUnit: FuelEconomyUnit {
        get {
            let raw = d.string(forKey: "fuel_economy_unit") ?? ""
            return FuelEconomyUnit(rawValue: raw) ?? .litersPer100Km
        }
        set { d.set(newValue.rawValue, forKey: "fuel_economy_unit") }
    }

    static func theme(for vin: String, brand: VehicleBrand? = nil) -> AppTheme {
        let normalizedVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedVIN.isEmpty,
           let themes = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String],
           let raw = themes[normalizedVIN],
           let theme = AppTheme(rawValue: raw) {
            return theme
        }
        let resolvedBrand = brand ?? (normalizedVIN.isEmpty ? activeBrand : (normalizedVIN.hasPrefix("YV") ? .volvo : activeBrand))
        if let brandRaw = d.string(forKey: "theme_for_\(resolvedBrand.rawValue)"),
           let theme = AppTheme(rawValue: brandRaw) {
            return theme
        }
        switch resolvedBrand {
        case .volvo: return .volvo
        case .polestar: return .polestar
        }
    }

    static func setTheme(_ theme: AppTheme, for vin: String, brand: VehicleBrand? = nil) {
        let normalizedVIN = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !normalizedVIN.isEmpty {
            var themes = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String] ?? [:]
            themes[normalizedVIN] = theme.rawValue
            d.set(themes, forKey: "vehicle_themes_v1")
        }
        let targetBrand = brand ?? activeBrand
        d.set(theme.rawValue, forKey: "theme_for_\(targetBrand.rawValue)")
        d.set(theme.rawValue, forKey: "app_theme")
    }

    static var appTheme: AppTheme {
        get {
            let currentVin = vin
            if !currentVin.isEmpty {
                return theme(for: currentVin, brand: activeBrand)
            }
            if let brandTheme = d.string(forKey: "theme_for_\(activeBrand.rawValue)"),
               let theme = AppTheme(rawValue: brandTheme) {
                return theme
            }
            return AppTheme(rawValue: d.string(forKey: "app_theme") ?? "") ?? (activeBrand == .volvo ? .volvo : .polestar)
        }
        set {
            setTheme(newValue, for: vin, brand: activeBrand)
        }
    }

    /// Re-derives the resolved theme for the currently active vehicle and writes it into the
    /// legacy `"app_theme"` key, which `@AppStorage("app_theme")` observers watch for redraws.
    /// Call this after switching the active vehicle/brand so those views pick up that car's
    /// stored theme without waiting for the user to reselect it in Settings.
    static func syncAppThemeStorageKey() {
        d.set(appTheme.rawValue, forKey: "app_theme")
    }

    static var appearanceMode: AppearanceMode {
        get {
            guard let raw = d.string(forKey: "his_appearanceMode"),
                  let mode = AppearanceMode(rawValue: raw) else {
                return .system
            }
            return mode
        }
        set {
            d.set(newValue.rawValue, forKey: "his_appearanceMode")
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    applyAppearance()
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        applyAppearance()
                    }
                }
            }
        }
    }

    /// Applies the configured appearance mode (system, light, or dark) across AppKit
    @MainActor
    static func applyAppearance() {
        let appearance = appearanceMode.nsAppearance
        NSApplication.shared.appearance = appearance
    }

    static var interfaceLanguage: InterfaceLanguage {
        get { InterfaceLanguage(rawValue: d.string(forKey: "interface_language") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "interface_language") }
    }

    static var tintMenuBarIcon: Bool {
        get { boolDefaultTrue("tint_menu_bar_icon") }
        set { d.set(newValue, forKey: "tint_menu_bar_icon") }
    }

    static var launchAtLogin: Bool {
        get { d.bool(forKey: "launch_at_login") }
        set { d.set(newValue, forKey: "launch_at_login") }
    }

    static var remoteClimateTemperature: Double {
        get {
            let value = d.double(forKey: "remote_climate_temperature_v2")
            if value > 0 {
                return min(max(value, 16.0), 30.0)
            }
            let legacy = d.integer(forKey: "remote_climate_temperature")
            return legacy == 0 ? 21.0 : min(max(Double(legacy), 16.0), 30.0)
        }
        set {
            let clamped = min(max(newValue, 16.0), 30.0)
            let roundedToHalf = (clamped * 2).rounded() / 2
            d.set(roundedToHalf, forKey: "remote_climate_temperature_v2")
            d.set(Int(roundedToHalf.rounded()), forKey: "remote_climate_temperature")
        }
    }

    static var remoteDriverSeatHeating: HeatingLevel {
        get { HeatingLevel(rawValue: d.integer(forKey: "remote_driver_seat_heating")) ?? .unspecified }
        set { d.set(newValue.rawValue, forKey: "remote_driver_seat_heating") }
    }

    static var remoteFrontRightSeatHeating: HeatingLevel {
        get { HeatingLevel(rawValue: d.integer(forKey: "remote_front_right_seat_heating")) ?? .unspecified }
        set { d.set(newValue.rawValue, forKey: "remote_front_right_seat_heating") }
    }

    static var remoteRearLeftSeatHeating: HeatingLevel {
        get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_left_seat_heating")) ?? .unspecified }
        set { d.set(newValue.rawValue, forKey: "remote_rear_left_seat_heating") }
    }

    static var remoteRearRightSeatHeating: HeatingLevel {
        get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_right_seat_heating")) ?? .unspecified }
        set { d.set(newValue.rawValue, forKey: "remote_rear_right_seat_heating") }
    }

    static var remoteSteeringWheelHeating: HeatingLevel {
        get { HeatingLevel(rawValue: d.integer(forKey: "remote_steering_heating")) ?? .unspecified }
        set { d.set(newValue.rawValue, forKey: "remote_steering_heating") }
    }

    static var features: FeatureSelection {
        get {
            if let values = d.array(forKey: "enabled_features_v2") as? [String] {
                return FeatureSelection(
                    enabled: Set(values.compactMap(AppFeature.init(rawValue:)))
                        .intersection(AppFeature.permittedFeatures)
                )
            }
            if let legacy = d.array(forKey: "enabled_features_v1") as? [String] {
                var enabled = Set(legacy.compactMap(AppFeature.init(rawValue:)))
                let newlyImplemented: Set<AppFeature> = [
                    .exteriorStatus, .tyreAndWarnings, .softwareUpdates, .chargingSchedule,
                    .climateStatus, .tripMeters
                ]
                enabled.formUnion(newlyImplemented)
                let migrated = FeatureSelection(enabled: enabled.intersection(AppFeature.permittedFeatures))
                d.set(migrated.enabled.map(\.rawValue).sorted(), forKey: "enabled_features_v2")
                return migrated
            }
            do {
                var selection = FeatureSelection.default
                if d.bool(forKey: "show_vehicle_image") {
                    selection.set(.vehicleImage, enabled: true)
                }
                return selection
            }
        }
        set {
            d.set(newValue.enabled.intersection(AppFeature.permittedFeatures).map(\.rawValue).sorted(),
                  forKey: "enabled_features_v2")
            d.removeObject(forKey: "enabled_features_v1")
            d.removeObject(forKey: "show_vehicle_image")
        }
    }


    private static func boolDefaultTrue(_ key: String) -> Bool {
        d.object(forKey: key) == nil ? true : d.bool(forKey: key)
    }

    static var notifyChargingStarted: Bool {
        get { boolDefaultTrue("notify_charging_started") }
        set { d.set(newValue, forKey: "notify_charging_started") }
    }

    static var notifyChargingComplete: Bool {
        get { boolDefaultTrue("notify_charging_complete") }
        set { d.set(newValue, forKey: "notify_charging_complete") }
    }

    static var notifyChargingProblem: Bool {
        get { boolDefaultTrue("notify_charging_problem") }
        set { d.set(newValue, forKey: "notify_charging_problem") }
    }

    static var notifyLowBattery: Bool {
        get { boolDefaultTrue("notify_low_battery") }
        set { d.set(newValue, forKey: "notify_low_battery") }
    }

    static var notifyPlugInReminder: Bool {
        get { boolDefaultTrue("notify_plugin_reminder") }
        set { d.set(newValue, forKey: "notify_plugin_reminder") }
    }

    static var notifySoftwareUpdates: Bool {
        get { boolDefaultTrue("notify_software_updates") }
        set { d.set(newValue, forKey: "notify_software_updates") }
    }

    static var notifyVehicleWarnings: Bool {
        get { boolDefaultTrue("notify_vehicle_warnings") }
        set { d.set(newValue, forKey: "notify_vehicle_warnings") }
    }

    static var lowBatteryThreshold: Int {
        get {
            let value = d.integer(forKey: "low_battery_threshold")
            return value == 0 ? 20 : min(max(value, 5), 50)
        }
        set { d.set(min(max(newValue, 5), 50), forKey: "low_battery_threshold") }
    }

    static var electricityPricePerKwh: Double {
        get {
            let val = d.double(forKey: "electricity_price_per_kwh")
            return val > 0 ? val : 2.0
        }
        set { d.set(newValue, forKey: "electricity_price_per_kwh") }
    }

    static var currencySymbol: String {
        get {
            let str = d.string(forKey: "electricity_currency_symbol") ?? ""
            if !str.isEmpty { return str }
            return Locale.current.currencySymbol ?? "kr"
        }
        set { d.set(newValue, forKey: "electricity_currency_symbol") }
    }

    static var storeChargingHistory: Bool {
        get { d.bool(forKey: "store_charging_history") }
        set { d.set(newValue, forKey: "store_charging_history") }
    }

    static var notifyRainWithWindowsOpen: Bool {
        get { boolDefaultTrue("notify_rain_with_windows") }
        set { d.set(newValue, forKey: "notify_rain_with_windows") }
    }

    static var notifyEveningUnlocked: Bool {
        get { boolDefaultTrue("notify_evening_unlocked") }
        set { d.set(newValue, forKey: "notify_evening_unlocked") }
    }

    static var privateNotificationDetails: Bool {
        get { d.object(forKey: "private_notification_details") == nil ? true : d.bool(forKey: "private_notification_details") }
        set { d.set(newValue, forKey: "private_notification_details") }
    }

    static var requireBiometricsForRemoteControls: Bool {
        get { d.bool(forKey: "require_biometrics_for_remote_controls") }
        set { d.set(newValue, forKey: "require_biometrics_for_remote_controls") }
    }


    static func migrateLegacyPassword() {
        guard let legacy = d.string(forKey: "polestar_password"), !legacy.isEmpty else { return }
        do {
            if try Keychain.readPassword() == nil {
                try Keychain.savePassword(legacy)
            }


            d.removeObject(forKey: "polestar_password")
        } catch {


        }
    }
}


