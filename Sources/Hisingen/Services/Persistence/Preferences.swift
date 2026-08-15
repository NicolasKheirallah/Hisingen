

import Foundation


enum InterfaceLanguage: String, CaseIterable {
    case system
    case english
    case swedish
    case german
    case norwegian
    case danish
    case dutch

    var languageCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .swedish: return "sv"
        case .german: return "de"
        case .norwegian: return "nb"
        case .danish: return "da"
        case .dutch: return "nl"
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

    var title: String {
        switch self {
        case .battery: return L10n.text("Battery Percentage")
        case .batteryAndRange: return L10n.text("Battery and Range")
        case .chargingAware: return L10n.text("Charging Aware (Time to Full)")
        case .compactCharging: return L10n.text("Compact Charging")
        case .batteryAndPower: return L10n.text("Battery and Power")
        case .range: return L10n.text("Range")
        }
    }
}


enum AppTheme: String, CaseIterable, Codable, Sendable {
    case hisingen
    case polestar
    case volvo

    var title: String {
        switch self {
        case .hisingen: return L10n.text("Hisingen (Default)")
        case .polestar: return L10n.text("Polestar")
        case .volvo: return L10n.text("Volvo")
        }
    }

    var subtitle: String {
        switch self {
        case .hisingen: return L10n.text("Rounded cards, translucent materials, system accent color")
        case .polestar: return L10n.text("Unofficial — monochrome panels, sharp corners, no color accent")
        case .volvo: return L10n.text("Unofficial — Volvo's blue accent, soft panels, light/bold type contrast")
        }
    }
}

enum DistanceUnit: String, CaseIterable {
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

@MainActor
enum Preferences {
    private static let d = UserDefaults.standard

    static var email: String {
        get { d.string(forKey: "polestar_email") ?? "" }
        set { d.set(newValue, forKey: "polestar_email") }
    }


    static var activeBrand: VehicleBrand {
        get { VehicleBrand(rawValue: d.string(forKey: "active_vehicle_brand") ?? "") ?? .polestar }
        set { d.set(newValue.rawValue, forKey: "active_vehicle_brand") }
    }


    static var volvoClientID: String {
        get { d.string(forKey: "volvo_client_id") ?? "" }
        set { d.set(newValue, forKey: "volvo_client_id") }
    }


    static var vin: String {
        get { d.string(forKey: vinKey) ?? "" }
        set { d.set(newValue, forKey: vinKey) }
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


    static func lastVehicleLabel(for brand: VehicleBrand) -> String {
        let storedVIN = vin(for: brand)
        guard !storedVIN.isEmpty else { return brand.displayName }
        let nickname = vehicleNickname(for: storedVIN)
        return nickname.isEmpty ? storedVIN : nickname
    }


    static func hasResumableSession(for brand: VehicleBrand) -> Bool {
        switch brand {
        case .polestar:
            let hasToken = ((try? Keychain.readSessionToken()) ?? nil)?.isEmpty == false
            let hasPassword = !email.isEmpty && ((try? Keychain.readPassword()) ?? nil)?.isEmpty == false
            return hasToken || hasPassword
        case .volvo:
            return !volvoClientID.isEmpty
                && ((try? Keychain.readVolvoClientSecret()) ?? nil)?.isEmpty == false
                && ((try? Keychain.readVolvoApiKey()) ?? nil)?.isEmpty == false
                && ((try? Keychain.readVolvoSessionToken()) ?? nil)?.isEmpty == false
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

    static var distanceUnit: DistanceUnit {
        get {
            let raw = d.string(forKey: "distance_unit") ?? ""
            if let value = DistanceUnit(rawValue: raw) { return value }
            return raw == "Miles (mi)" ? .miles : .kilometers
        }
        set { d.set(newValue.rawValue, forKey: "distance_unit") }
    }

    static var appTheme: AppTheme {
        get { AppTheme(rawValue: d.string(forKey: "app_theme") ?? "") ?? .hisingen }
        set { d.set(newValue.rawValue, forKey: "app_theme") }
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


