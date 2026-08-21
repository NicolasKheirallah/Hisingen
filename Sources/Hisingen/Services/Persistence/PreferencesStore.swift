import Foundation
import SwiftUI

/// The single source of preference state for an application composition.
/// Storage intentionally uses the legacy keys so existing installations migrate in place.
@MainActor
final class PreferencesStore {
    nonisolated(unsafe) private let d: UserDefaults
    private let keychain: KeychainStore

    nonisolated init(defaults: UserDefaults = .standard, keychain: KeychainStore = .app) {
        d = defaults
        self.keychain = keychain
    }

    struct AccountDraft {
        var polestarEmail = ""
        var polestarPassword = ""
        var polestarVIN = ""
        var polestarNickname = ""
        var volvoClientID = ""
        var volvoClientSecret = ""
        var volvoApiKey = ""
        var volvoVIN = ""
        var volvoNickname = ""
    }

    var accountDraft = AccountDraft()

    var email: String {
        get {
            if let secure = (try? keychain.readEmail()) ?? nil, !secure.isEmpty {
                d.removeObject(forKey: "polestar_email")
                return secure
            }
            guard let legacy = d.string(forKey: "polestar_email"), !legacy.isEmpty else { return "" }
            do {
                try keychain.saveEmail(legacy)
                d.removeObject(forKey: "polestar_email")
            } catch {
                // Keep the legacy value until Keychain becomes available so an
                // upgrade never silently loses the account identifier.
            }
            return legacy
        }
        set {
            if newValue.isEmpty {
                try? keychain.deleteEmail()
                d.removeObject(forKey: "polestar_email")
            } else {
                do {
                    try keychain.saveEmail(newValue)
                    d.removeObject(forKey: "polestar_email")
                } catch {
                    // Never write a new account identifier to UserDefaults.
                }
            }
        }
    }
    var activeBrand: VehicleBrand {
        get { VehicleBrand(rawValue: d.string(forKey: "active_vehicle_brand") ?? "") ?? .polestar }
        set { d.set(newValue.rawValue, forKey: "active_vehicle_brand"); syncAppThemeStorageKey() }
    }
    var volvoClientID: String {
        get { d.string(forKey: "volvo_client_id").flatMap { $0.isEmpty ? nil : $0 } ?? BuiltinVolvoSecrets.clientID }
        set { d.set(newValue, forKey: "volvo_client_id") }
    }
    private func vinKey(for brand: VehicleBrand) -> String { brand == .volvo ? "volvo_vin" : "polestar_vin" }
    var vin: String { get { d.string(forKey: vinKey(for: activeBrand)) ?? "" } set { d.set(newValue, forKey: vinKey(for: activeBrand)); syncAppThemeStorageKey() } }
    func vin(for brand: VehicleBrand) -> String { d.string(forKey: vinKey(for: brand)) ?? "" }
    func setVin(_ value: String, for brand: VehicleBrand) { d.set(value, forKey: vinKey(for: brand)); if brand == activeBrand { syncAppThemeStorageKey() } }

    func lastVehicleLabel(for brand: VehicleBrand) -> String {
        let value = vin(for: brand); guard !value.isEmpty else { return brand.displayName }
        let nick = vehicleNickname(for: value); return nick.isEmpty ? value : nick
    }
    func hasResumableSession(for brand: VehicleBrand) -> Bool {
        switch brand {
        case .polestar:
            if ((try? Keychain.readSessionToken()) ?? nil)?.isEmpty == false { return true }
            return !email.isEmpty && ((try? Keychain.readPassword()) ?? nil)?.isEmpty == false
        case .volvo:
            guard !volvoClientID.isEmpty else { return false }
            return ((try? Keychain.readVolvoSessionToken()) ?? nil)?.isEmpty == false
        }
    }
    func vehicleNickname(for vin: String) -> String {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); guard !key.isEmpty else { return "" }
        if let values = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String], let value = values[key] { return value }
        guard key == self.vin.uppercased() else { return "" }
        return d.string(forKey: "polestar_vehicle_nickname") ?? ""
    }
    func setVehicleNickname(_ nickname: String, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "polestar_vehicle_nicknames_v1") as? [String: String] ?? [:]
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { values.removeValue(forKey: key) } else { values[key] = value }
        d.set(values, forKey: "polestar_vehicle_nicknames_v1")
        if key == vin.uppercased() { d.removeObject(forKey: "polestar_vehicle_nickname") }
    }
    func formattedVehicleTitle(vin: String, modelName: String?, modelYear: String?, registrationNo: String?, fallbackBrand: VehicleBrand? = nil, format: VehicleLabelFormat? = nil) -> String {
        let selected = format ?? vehicleLabelFormat, brand = fallbackBrand ?? activeBrand
        let nick = vehicleNickname(for: vin).trimmingCharacters(in: .whitespacesAndNewlines)
        let reg = registrationNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let year = modelYear?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let modelAndYear = [model.isEmpty ? nil : model, year.isEmpty ? nil : year].compactMap { $0 }.joined(separator: " · ")
        switch selected {
        case .registration: return reg.isEmpty ? (nick.isEmpty ? (modelAndYear.isEmpty ? (model.isEmpty ? brand.displayName : model) : modelAndYear) : nick) : reg
        case .nickname: return nick.isEmpty ? (reg.isEmpty ? (modelAndYear.isEmpty ? (model.isEmpty ? brand.displayName : model) : modelAndYear) : reg) : nick
        case .modelAndYear: return modelAndYear.isEmpty ? (model.isEmpty ? (nick.isEmpty ? (reg.isEmpty ? brand.displayName : reg) : nick) : model) : modelAndYear
        case .modelOnly: return model.isEmpty ? (modelAndYear.isEmpty ? (nick.isEmpty ? (reg.isEmpty ? brand.displayName : reg) : nick) : modelAndYear) : model
        case .nicknameAndRegistration: return !nick.isEmpty && !reg.isEmpty ? "\(nick) (\(reg))" : (nick.isEmpty ? (reg.isEmpty ? (modelAndYear.isEmpty ? brand.displayName : modelAndYear) : reg) : nick)
        case .registrationAndModel: return !reg.isEmpty && !model.isEmpty ? "\(reg) · \(model)" : (reg.isEmpty ? (modelAndYear.isEmpty ? (nick.isEmpty ? brand.displayName : nick) : modelAndYear) : reg)
        }
    }

    var menuBarStyle: MenuBarStyle { get { let raw = d.string(forKey: "statusbar_display_option") ?? ""; if let value = MenuBarStyle(rawValue: raw) { return value }; switch raw { case "Range", "Range (km)": return .range; case "Charge Time": return .chargingAware; case "Battery and Range": return .batteryAndRange; case "Compact Charging": return .compactCharging; case "Battery and Power": return .batteryAndPower; default: return .battery } } set { d.set(newValue.rawValue, forKey: "statusbar_display_option") } }
    var carRenderAngle: CarRenderAngle { get { CarRenderAngle(rawValue: d.object(forKey: "car_render_angle") as? Int ?? 0) ?? .frontThreeQuarter } set { d.set(newValue.rawValue, forKey: "car_render_angle") } }
    var vehicleModelBadgePosition: VehicleModelBadgePosition { get { VehicleModelBadgePosition(rawValue: d.string(forKey: "vehicle_model_badge_position") ?? "") ?? .inlineHeader } set { d.set(newValue.rawValue, forKey: "vehicle_model_badge_position") } }
    var registrationBadgePosition: RegistrationNumberBadgePosition { get { RegistrationNumberBadgePosition(rawValue: d.string(forKey: "registration_badge_position") ?? "") ?? .belowGreeting } set { d.set(newValue.rawValue, forKey: "registration_badge_position") } }
    var vehicleLabelFormat: VehicleLabelFormat { get { VehicleLabelFormat(rawValue: d.string(forKey: "vehicle_label_format") ?? "") ?? .modelAndYear } set { d.set(newValue.rawValue, forKey: "vehicle_label_format") } }
    var distanceUnit: DistanceUnit { get { let raw = d.string(forKey: "distance_unit") ?? ""; return DistanceUnit(rawValue: raw) ?? (raw == "Miles (mi)" ? .miles : .kilometers) } set { d.set(newValue.rawValue, forKey: "distance_unit") } }
    var hasExplicitTemperatureUnit: Bool { d.object(forKey: "temperature_unit") != nil }
    var hasExplicitPressureUnit: Bool { d.object(forKey: "pressure_unit") != nil }
    var temperatureUnit: TemperatureUnit { get { d.string(forKey: "temperature_unit").flatMap(TemperatureUnit.init) ?? (distanceUnit == .miles ? .fahrenheit : .celsius) } set { d.set(newValue.rawValue, forKey: "temperature_unit") } }
    var pressureUnit: PressureUnit { get { d.string(forKey: "pressure_unit").flatMap(PressureUnit.init) ?? (distanceUnit == .miles ? .psi : .kilopascals) } set { d.set(newValue.rawValue, forKey: "pressure_unit") } }
    var fuelVolumeUnit: FuelVolumeUnit { get { FuelVolumeUnit(rawValue: d.string(forKey: "fuel_volume_unit") ?? "") ?? .liters } set { d.set(newValue.rawValue, forKey: "fuel_volume_unit") } }
    var fuelEconomyUnit: FuelEconomyUnit { get { FuelEconomyUnit(rawValue: d.string(forKey: "fuel_economy_unit") ?? "") ?? .litersPer100Km } set { d.set(newValue.rawValue, forKey: "fuel_economy_unit") } }
    var interfaceLanguage: InterfaceLanguage { get { InterfaceLanguage(rawValue: d.string(forKey: "interface_language") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "interface_language") } }
    var tintMenuBarIcon: Bool { get { d.object(forKey: "tint_menu_bar_icon") == nil || d.bool(forKey: "tint_menu_bar_icon") } set { d.set(newValue, forKey: "tint_menu_bar_icon") } }
    var launchAtLogin: Bool { get { d.bool(forKey: "launch_at_login") } set { d.set(newValue, forKey: "launch_at_login") } }
    var appearanceMode: AppearanceMode { get { AppearanceMode(rawValue: d.string(forKey: "his_appearanceMode") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "his_appearanceMode"); applyAppearance() } }
    var remoteClimateTemperature: Double { get { let value = d.double(forKey: "remote_climate_temperature_v2"); let legacy = d.integer(forKey: "remote_climate_temperature"); return min(max(value > 0 ? value : (legacy == 0 ? 21 : Double(legacy)), 16), 30) } set { let value = (min(max(newValue, 16), 30) * 2).rounded() / 2; d.set(value, forKey: "remote_climate_temperature_v2"); d.set(Int(value.rounded()), forKey: "remote_climate_temperature") } }
    var remoteDriverSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_driver_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_driver_seat_heating") } }
    var remoteFrontRightSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_front_right_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_front_right_seat_heating") } }
    var remoteRearLeftSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_left_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_rear_left_seat_heating") } }
    var remoteRearRightSeatHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_rear_right_seat_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_rear_right_seat_heating") } }
    var remoteSteeringWheelHeating: HeatingLevel { get { HeatingLevel(rawValue: d.integer(forKey: "remote_steering_heating")) ?? .unspecified } set { d.set(newValue.rawValue, forKey: "remote_steering_heating") } }
    var electricityPricePerKwh: Double { get { let value = d.double(forKey: "electricity_price_per_kwh"); return value > 0 ? value : 2.0 } set { d.set(newValue, forKey: "electricity_price_per_kwh") } }
    var currencySymbol: String { get { let value = d.string(forKey: "electricity_currency_symbol") ?? ""; return value.isEmpty ? (Locale.current.currencySymbol ?? "kr") : value } set { d.set(newValue, forKey: "electricity_currency_symbol") } }
    var storeChargingHistory: Bool { get { d.bool(forKey: "store_charging_history") } set { d.set(newValue, forKey: "store_charging_history") } }
    var privateNotificationDetails: Bool { get { d.object(forKey: "private_notification_details") == nil || d.bool(forKey: "private_notification_details") } set { d.set(newValue, forKey: "private_notification_details") } }
    var requireBiometricsForRemoteControls: Bool { get { d.bool(forKey: "require_biometrics_for_remote_controls") } set { d.set(newValue, forKey: "require_biometrics_for_remote_controls") } }
    var lowBatteryThreshold: Int { get { let value = d.integer(forKey: "low_battery_threshold"); return value == 0 ? 20 : min(max(value, 5), 50) } set { d.set(min(max(newValue, 5), 50), forKey: "low_battery_threshold") } }

    func warrantyInServiceDate(for vin: String) -> Date? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let value = d.dictionary(forKey: "vehicle_in_service_dates_v1")?[key] else { return nil }
        let interval: Double
        if let number = value as? NSNumber { interval = number.doubleValue }
        else if let double = value as? Double { interval = double }
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    func setWarrantyInServiceDate(_ date: Date?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "vehicle_in_service_dates_v1") ?? [:]
        if let date { values[key] = date.timeIntervalSince1970 } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "vehicle_in_service_dates_v1")
    }

    func dismissedSoftwareEventIdentifier(for vin: String) -> String? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        return (d.dictionary(forKey: "dismissed_software_events_v1") as? [String: String])?[key]
    }

    func setDismissedSoftwareEventIdentifier(_ identifier: String?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.dictionary(forKey: "dismissed_software_events_v1") as? [String: String] ?? [:]
        if let identifier { values[key] = identifier } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "dismissed_software_events_v1")
    }

    private func boolDefaultTrue(_ key: String) -> Bool { d.object(forKey: key) == nil || d.bool(forKey: key) }
    var notifyChargingStarted: Bool { get { boolDefaultTrue("notify_charging_started") } set { d.set(newValue, forKey: "notify_charging_started") } }
    var notifyChargingComplete: Bool { get { boolDefaultTrue("notify_charging_complete") } set { d.set(newValue, forKey: "notify_charging_complete") } }
    var notifyChargingProblem: Bool { get { boolDefaultTrue("notify_charging_problem") } set { d.set(newValue, forKey: "notify_charging_problem") } }
    var notifyLowBattery: Bool { get { boolDefaultTrue("notify_low_battery") } set { d.set(newValue, forKey: "notify_low_battery") } }
    var notifyPlugInReminder: Bool { get { boolDefaultTrue("notify_plugin_reminder") } set { d.set(newValue, forKey: "notify_plugin_reminder") } }
    var notifySoftwareUpdates: Bool { get { boolDefaultTrue("notify_software_updates") } set { d.set(newValue, forKey: "notify_software_updates") } }
    var notifyVehicleWarnings: Bool { get { boolDefaultTrue("notify_vehicle_warnings") } set { d.set(newValue, forKey: "notify_vehicle_warnings") } }
    var notifyRainWithWindowsOpen: Bool { get { boolDefaultTrue("notify_rain_with_windows") } set { d.set(newValue, forKey: "notify_rain_with_windows") } }
    var notifyEveningUnlocked: Bool { get { boolDefaultTrue("notify_evening_unlocked") } set { d.set(newValue, forKey: "notify_evening_unlocked") } }

    var features: FeatureSelection {
        get {
            if let values = d.array(forKey: "enabled_features_v2") as? [String] { var set = Set(values.compactMap(AppFeature.init)).intersection(AppFeature.permittedFeatures); set.formUnion([.vehicleLocation, .vehicleWeather, .ownerGreeting]); return FeatureSelection(enabled: set) }
            if let values = d.array(forKey: "enabled_features_v1") as? [String] { var set = Set(values.compactMap(AppFeature.init)); set.formUnion([.exteriorStatus, .tyreAndWarnings, .softwareUpdates, .chargingSchedule, .climateStatus, .tripMeters]); let result = FeatureSelection(enabled: set.intersection(AppFeature.permittedFeatures)); d.set(result.enabled.map(\.rawValue).sorted(), forKey: "enabled_features_v2"); return result }
            var result = FeatureSelection.default; if d.bool(forKey: "show_vehicle_image") { result.set(.vehicleImage, enabled: true) }; return result
        }
        set { d.set(newValue.enabled.intersection(AppFeature.permittedFeatures).map(\.rawValue).sorted(), forKey: "enabled_features_v2"); d.removeObject(forKey: "enabled_features_v1"); d.removeObject(forKey: "show_vehicle_image") }
    }

    func theme(for vin: String, brand: VehicleBrand? = nil) -> AppTheme { let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); if let values = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String], let theme = values[key].flatMap(AppTheme.init) { return theme }; let resolved = brand ?? (key.isEmpty ? activeBrand : (key.hasPrefix("YV") ? .volvo : activeBrand)); if let theme = d.string(forKey: "theme_for_\(resolved.rawValue)").flatMap(AppTheme.init) { return theme }; return resolved == .volvo ? .volvo : .polestar }
    func setTheme(_ theme: AppTheme, for vin: String, brand: VehicleBrand? = nil) { let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); if !key.isEmpty { var values = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String] ?? [:]; values[key] = theme.rawValue; d.set(values, forKey: "vehicle_themes_v1") }; d.set(theme.rawValue, forKey: "theme_for_\((brand ?? activeBrand).rawValue)"); d.set(theme.rawValue, forKey: "app_theme") }
    var appTheme: AppTheme { get { vin.isEmpty ? (d.string(forKey: "theme_for_\(activeBrand.rawValue)").flatMap(AppTheme.init) ?? AppTheme(rawValue: d.string(forKey: "app_theme") ?? "") ?? (activeBrand == .volvo ? .volvo : .polestar)) : theme(for: vin, brand: activeBrand) } set { setTheme(newValue, for: vin, brand: activeBrand) } }
    func syncAppThemeStorageKey() { d.set(appTheme.rawValue, forKey: "app_theme") }
    func applyAppearance() { NSApplication.shared.appearance = appearanceMode.nsAppearance }
    func migrateLegacyPassword() { guard let legacy = d.string(forKey: "polestar_password"), !legacy.isEmpty else { return }; do { if try Keychain.readPassword() == nil { try Keychain.savePassword(legacy) }; d.removeObject(forKey: "polestar_password") } catch {} }
}

private struct PreferencesStoreKey: EnvironmentKey {
    static let defaultValue: PreferencesStore? = nil
}

@MainActor
extension EnvironmentValues {
    var preferencesStore: PreferencesStore {
        get { self[PreferencesStoreKey.self] ?? PreferencesStore() }
        set { self[PreferencesStoreKey.self] = newValue }
    }
}
