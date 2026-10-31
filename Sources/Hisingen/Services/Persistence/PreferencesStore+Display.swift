import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    func lastVehicleLabel(for brand: VehicleBrand) -> String {
        let value = vin(for: brand); guard !value.isEmpty else { return brand.displayName }
        let nick = vehicleNickname(for: value); return nick.isEmpty ? value : nick
    }

    var garageVehicleOrder: [String] {
        get { d.array(forKey: "garage_vehicle_order_v1") as? [String] ?? [] }
        set { d.set(newValue, forKey: "garage_vehicle_order_v1") }
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
    /// Size preset of the menu bar dropdown panel; applied live while the panel is open.
    var panelSize: PanelSize { get { PanelSize(rawValue: d.string(forKey: "panel_size") ?? "") ?? .standard } set { d.set(newValue.rawValue, forKey: "panel_size") } }
    /// Independent content zoom inside the dropdown; decoupled from the window size so
    /// a larger panel can show more content rather than the same content enlarged.
    var contentDensity: ContentDensity { get { ContentDensity(rawValue: d.string(forKey: "content_density") ?? "") ?? .standard } set { d.set(newValue.rawValue, forKey: "content_density") } }
    /// When on, the dropdown uses the independent width/height overrides below instead
    /// of the selected PanelSize preset's dimensions (the preset stays remembered).
    var customPanelSizeEnabled: Bool { get { d.bool(forKey: "custom_panel_size_enabled") } set { d.set(newValue, forKey: "custom_panel_size_enabled") } }
    var customPanelWidth: Double { get { d.double(forKey: "custom_panel_width") } set { d.set(newValue, forKey: "custom_panel_width") } }
    var customPanelHeight: Double { get { d.double(forKey: "custom_panel_height") } set { d.set(newValue, forKey: "custom_panel_height") } }
    /// Flow of mid-size dashboard cards on wide panels: stacked full width or
    /// side by side in two columns. Defaults to full width.
    var wideCardLayout: WideCardLayout { get { WideCardLayout(rawValue: d.string(forKey: "wide_card_layout") ?? "") ?? .fullWidth } set { d.set(newValue.rawValue, forKey: "wide_card_layout") } }
    /// Whether the dropdown closes automatically when another app takes focus, or stays
    /// open until the status item is clicked again. Default keeps the historical behavior.
    var panelCloseBehavior: PanelCloseBehavior {
        get { PanelCloseBehavior(rawValue: d.string(forKey: "panel_close_behavior") ?? "") ?? .keepOpen }
        set { d.set(newValue.rawValue, forKey: "panel_close_behavior") }
    }
    // The unset key must fall back to .frontThreeQuarter explicitly: a bare `?? 0` resolves to
    // CarRenderAngle.sideProfile (rawValue 0), making the written fallback unreachable and
    // rendering new installs in a view the Settings card never selects.
    var carRenderAngle: CarRenderAngle { get { CarRenderAngle(rawValue: d.object(forKey: "car_render_angle") as? Int ?? CarRenderAngle.frontThreeQuarter.rawValue) ?? .frontThreeQuarter } set { d.set(newValue.rawValue, forKey: "car_render_angle") } }
    var vehicleModelBadgePosition: VehicleModelBadgePosition { get { VehicleModelBadgePosition(rawValue: d.string(forKey: "vehicle_model_badge_position") ?? "") ?? .inlineHeader } set { d.set(newValue.rawValue, forKey: "vehicle_model_badge_position") } }
    var registrationBadgePosition: RegistrationNumberBadgePosition { get { RegistrationNumberBadgePosition(rawValue: d.string(forKey: "registration_badge_position") ?? "") ?? .belowGreeting } set { d.set(newValue.rawValue, forKey: "registration_badge_position") } }
    var vehicleLabelFormat: VehicleLabelFormat { get { VehicleLabelFormat(rawValue: d.string(forKey: "vehicle_label_format") ?? "") ?? .modelAndYear } set { d.set(newValue.rawValue, forKey: "vehicle_label_format") } }
    var distanceUnit: DistanceUnit { get { let raw = d.string(forKey: "distance_unit") ?? ""; return DistanceUnit(rawValue: raw) ?? (raw == "Miles (mi)" ? .miles : .kilometers) } set { d.set(newValue.rawValue, forKey: "distance_unit") } }
    var hasExplicitTemperatureUnit: Bool { d.object(forKey: "temperature_unit") != nil }
    var hasExplicitPressureUnit: Bool { d.object(forKey: "pressure_unit") != nil }
    var hasExplicitEnergyConsumptionUnit: Bool { d.object(forKey: "energy_consumption_unit") != nil }
    var temperatureUnit: TemperatureUnit { get { d.string(forKey: "temperature_unit").flatMap(TemperatureUnit.init) ?? (distanceUnit == .miles ? .fahrenheit : .celsius) } set { d.set(newValue.rawValue, forKey: "temperature_unit") } }
    var pressureUnit: PressureUnit { get { d.string(forKey: "pressure_unit").flatMap(PressureUnit.init) ?? (distanceUnit == .miles ? .psi : .kilopascals) } set { d.set(newValue.rawValue, forKey: "pressure_unit") } }
    var fuelVolumeUnit: FuelVolumeUnit { get { FuelVolumeUnit(rawValue: d.string(forKey: "fuel_volume_unit") ?? "") ?? .liters } set { d.set(newValue.rawValue, forKey: "fuel_volume_unit") } }
    var fuelEconomyUnit: FuelEconomyUnit { get { FuelEconomyUnit(rawValue: d.string(forKey: "fuel_economy_unit") ?? "") ?? .litersPer100Km } set { d.set(newValue.rawValue, forKey: "fuel_economy_unit") } }
    var energyConsumptionUnit: EnergyConsumptionUnit {
        get { d.string(forKey: "energy_consumption_unit").flatMap(EnergyConsumptionUnit.init) ?? (distanceUnit == .miles ? .milesPerKwh : .kwhPer100Km) }
        set { d.set(newValue.rawValue, forKey: "energy_consumption_unit") }
    }

    var interfaceLanguage: InterfaceLanguage { get { InterfaceLanguage(rawValue: d.string(forKey: "interface_language") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "interface_language") } }
    var tintMenuBarIcon: Bool { get { d.object(forKey: "tint_menu_bar_icon") == nil || d.bool(forKey: "tint_menu_bar_icon") } set { d.set(newValue, forKey: "tint_menu_bar_icon") } }
    var launchAtLogin: Bool { get { d.bool(forKey: "launch_at_login") } set { d.set(newValue, forKey: "launch_at_login") } }
    var appearanceMode: AppearanceMode { get { AppearanceMode(rawValue: d.string(forKey: "his_appearanceMode") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "his_appearanceMode"); applyAppearance() } }

    func theme(for vin: String, brand: VehicleBrand? = nil) -> AppTheme {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let resolvedBrand = brand ?? (key.isEmpty ? activeBrand : (key.hasPrefix("YV") ? .volvo : activeBrand))
        return ThemeChoice.resolve(vin: key, brand: resolvedBrand, defaults: d)
    }

    func setTheme(_ theme: AppTheme, for vin: String, brand: VehicleBrand? = nil) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !key.isEmpty {
            ThemeChoice.assign(theme, scope: .vehicle(key), defaults: d)
        }
        let targetBrand = brand ?? activeBrand
        ThemeChoice.assign(theme, scope: .brand(targetBrand), defaults: d)
    }

    var appTheme: AppTheme {
        get {
            ThemeChoice.resolve(vin: vin, brand: activeBrand, defaults: d)
        }
        set {
            if vin.isEmpty {
                ThemeChoice.assign(newValue, scope: .brand(activeBrand), defaults: d)
            } else {
                setTheme(newValue, for: vin, brand: activeBrand)
            }
        }
    }

    func syncAppThemeStorageKey() {
        d.set(appTheme.rawValue, forKey: "app_theme")
    }
    func applyAppearance() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        NSApplication.shared.appearance = appearanceMode.nsAppearance
    }
}
