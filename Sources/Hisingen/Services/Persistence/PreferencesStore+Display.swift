import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    func lastVehicleLabel(for brand: VehicleBrand) -> String {
        guard !privacyRedactionEnabled else { return brand.displayName }
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
        if privacyRedactionEnabled { return model.isEmpty ? brand.displayName : model }
        let both: String?
        let order: [String]
        switch selected {
        case .registration: both = nil; order = [reg, nick, modelAndYear, model]
        case .nickname: both = nil; order = [nick, reg, modelAndYear, model]
        case .modelAndYear: both = nil; order = [modelAndYear, model, nick, reg]
        case .modelOnly: both = nil; order = [model, modelAndYear, nick, reg]
        case .nicknameAndRegistration:
            both = !nick.isEmpty && !reg.isEmpty ? "\(nick) (\(reg))" : nil
            order = [nick, reg, modelAndYear]
        case .registrationAndModel:
            both = !reg.isEmpty && !model.isEmpty ? "\(reg) · \(model)" : nil
            order = [reg, modelAndYear, nick]
        }
        // The first reading the owner has that the chosen format can show; the brand name when none.
        return both ?? order.first(where: { !$0.isEmpty }) ?? brand.displayName
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
    var nowReadingsPosition: NowReadingsPosition {
        get { d.string(forKey: "now_readings_position").flatMap(NowReadingsPosition.init(rawValue:)) ?? .below }
        set { d.set(newValue.rawValue, forKey: "now_readings_position") }
    }
    /// The control cards under the car on Now, in the order they draw. Unknown names from a later
    /// version are dropped rather than failing the whole list.
    var nowQuickControls: [NowQuickControl] {
        get {
            guard let raw = d.string(forKey: "now_quick_controls") else { return NowQuickControl.defaults }
            return raw.split(separator: ",").compactMap { NowQuickControl(rawValue: String($0)) }
        }
        set { d.set(newValue.map(\.rawValue).joined(separator: ","), forKey: "now_quick_controls") }
    }
    /// How far one press on Charge Limit or Current Limit raises the limit.
    var nowLimitStep: LimitStep {
        get { LimitStep(rawValue: d.integer(forKey: "now_limit_step")) ?? .five }
        set { d.set(newValue.rawValue, forKey: "now_limit_step") }
    }
    var nowFirstReading: NowFirstReading {
        get { d.string(forKey: "now_first_reading").flatMap(NowFirstReading.init(rawValue:)) ?? .battery }
        set { d.set(newValue.rawValue, forKey: "now_first_reading") }
    }
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

    var timeFormat: AppTimeFormat {
        get { d.string(forKey: AppTimeFormat.storageKey).flatMap(AppTimeFormat.init(rawValue:)) ?? .twentyFourHour }
        set { d.set(newValue.rawValue, forKey: AppTimeFormat.storageKey) }
    }

    var interfaceLanguage: InterfaceLanguage { get { InterfaceLanguage(rawValue: d.string(forKey: "interface_language") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "interface_language") } }
    var tintMenuBarIcon: Bool { get { d.object(forKey: "tint_menu_bar_icon") == nil || d.bool(forKey: "tint_menu_bar_icon") } set { d.set(newValue, forKey: "tint_menu_bar_icon") } }
    var launchAtLogin: Bool { get { d.bool(forKey: "launch_at_login") } set { d.set(newValue, forKey: "launch_at_login") } }
    /// Off by default: the bundle declares LSUIElement, so the Dock icon exists only when
    /// the reader asks for it. The warning badge needs this on to be visible at all.
    var showDockIcon: Bool { get { d.bool(forKey: "show_dock_icon") } set { d.set(newValue, forKey: "show_dock_icon") } }
    var appearanceMode: AppearanceMode { get { AppearanceMode(rawValue: d.string(forKey: "his_appearanceMode") ?? "") ?? .system } set { d.set(newValue.rawValue, forKey: "his_appearanceMode"); applyAppearance() } }

    func theme(for vin: String, brand: VehicleBrand? = nil) -> AppTheme {
        let key = vin.normalizedVIN
        let resolvedBrand = brand ?? (key.isEmpty ? activeBrand : (VehicleBrand.isVolvoVIN(key) ? .volvo : activeBrand))
        return ThemeChoice.resolve(vin: key, brand: resolvedBrand, defaults: d)
    }

    func setTheme(_ theme: AppTheme, for vin: String, brand: VehicleBrand? = nil) {
        let key = vin.normalizedVIN
        if !key.isEmpty {
            ThemeChoice.assign(theme, scope: .vehicle(key), defaults: d)
        }
        let targetBrand = brand ?? activeBrand
        ThemeChoice.assign(theme, scope: .brand(targetBrand), defaults: d)
    }

    func brandTheme(for brand: VehicleBrand) -> AppTheme {
        ThemeChoice.brandDefault(for: brand, defaults: d, allowsLegacyTheme: vin(for: brand).isEmpty && brand == activeBrand)
    }

    func setBrandTheme(_ theme: AppTheme, for brand: VehicleBrand) {
        d.set(theme.rawValue, forKey: "theme_for_\(brand.rawValue)")
        syncAppThemeStorageKey()
    }

    func vehicleThemeOverride(for vin: String) -> AppTheme? {
        ThemeChoice.vehicleOverride(for: vin, defaults: d)
    }

    func setVehicleTheme(_ theme: AppTheme?, for vin: String) {
        ThemeChoice.setVehicleOverride(theme, for: vin, defaults: d)
        syncAppThemeStorageKey()
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
