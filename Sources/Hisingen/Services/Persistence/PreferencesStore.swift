import Foundation
import OSLog
import SwiftUI

/// The single source of preference state for an application composition.
/// Storage intentionally uses the legacy keys so existing installations migrate in place.
@MainActor
final class PreferencesStore {
    /// Process-wide instance for call sites outside the view hierarchy (App Intents,
    /// service wiring) that previously constructed throwaway stores — each of which also
    /// opened its own Keychain handle set.
    static let shared = PreferencesStore()

    private let d: UserDefaults
    private let keychain: KeychainStore
    private let logger = AppLog.logger("preferences")

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = .app) {
        d = defaults
        self.keychain = keychain
    }
    private var cachedEmail: String?
    private var cachedHasResumableSession: [VehicleBrand: Bool] = [:]

    func invalidateSessionCache() {
        cachedEmail = nil
        cachedHasResumableSession.removeAll()
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

    enum SettingsTransferError: LocalizedError {
        case invalidArchive
        var errorDescription: String? { L10n.text("The selected file is not a valid Hisingen settings archive.") }
    }

    /// Settings transfer deliberately excludes account identifiers, vehicle identifiers,
    /// Keychain material, and session/cache state. The exported property list is suitable
    /// for moving presentation and alert preferences between Macs without leaking identity.
    private static func isTransferableSettingsKey(_ key: String) -> Bool {
        let forbiddenFragments = ["email", "password", "secret", "api_key", "session", "token", "vin", "nickname"]
        guard !forbiddenFragments.contains(where: key.contains) else { return false }
        let exact: Set<String> = [
            "charging_stat_order", "floating_charging_panel",
            "privacy_redaction_enabled", "statusbar_display_option", "panel_size",
            "content_density", "custom_panel_size_enabled", "custom_panel_width",
            "custom_panel_height", "wide_card_layout", "panel_close_behavior",
            "car_render_angle", "vehicle_model_badge_position", "registration_badge_position",
            "vehicle_label_format", "distance_unit", "temperature_unit", "pressure_unit",
            "fuel_volume_unit", "fuel_economy_unit", "energy_consumption_unit",
            "history_sample_retention_days", "interface_language", "tint_menu_bar_icon",
            "launch_at_login", "his_appearanceMode", "app_theme", "enabled_features_v2",
            "store_charging_history", "private_notification_details",
            "low_battery_threshold",
            "automatically_check_for_updates", "automatically_download_updates",
            "show_warning_badge", "grid_carbon_intensity_g_per_kwh"
        ]
        return exact.contains(key)
            || ["notify_", "remote_", "night_", "electricity_", "theme_for_"].contains(where: key.hasPrefix)
    }

    func exportSettingsPropertyList() throws -> Data {
        var values = d.dictionaryRepresentation().filter { Self.isTransferableSettingsKey($0.key) }
        if let rawFeatures = values["enabled_features_v2"] as? [String] {
            values["enabled_features_v2"] = rawFeatures.filter {
                AppFeature(rawValue: $0)?.isRemoteControl == false
            }
        }
        return try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    func importSettingsPropertyList(_ data: Data) throws {
        guard data.count <= 1_000_000,
              let archive = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              archive.keys.allSatisfy(Self.isTransferableSettingsKey) else {
            throw SettingsTransferError.invalidArchive
        }
        for key in d.dictionaryRepresentation().keys where Self.isTransferableSettingsKey(key) {
            d.removeObject(forKey: key)
        }
        for (key, value) in archive {
            if key == "enabled_features_v2", let rawFeatures = value as? [String] {
                // Importing a convenience profile must not grant remote-command access.
                let safe = rawFeatures.filter { raw in
                    guard let feature = AppFeature(rawValue: raw) else { return false }
                    return !feature.isRemoteControl
                }
                d.set(safe, forKey: key)
            } else {
                d.set(value, forKey: key)
            }
        }
    }

    func resetTransferableSettings() {
        for key in d.dictionaryRepresentation().keys where Self.isTransferableSettingsKey(key) {
            d.removeObject(forKey: key)
        }
    }

    /// Remove the legacy UserDefaults mirrors that predate SQLite. A database erase must
    /// clear these too or an old snapshot can reappear and be migrated back into SQLite.
    /// Corrupt legacy payloads are removed wholesale because retaining an undecodable cache
    /// is less safe than requiring the affected vehicles to refresh again.
    func clearLegacyVehicleCaches(for vin: String?, includeBaselines: Bool = true) {
        func removeEntry<Value: Codable>(_ type: Value.Type, key: String) {
            guard let vin else {
                d.removeObject(forKey: key)
                return
            }
            guard let data = d.data(forKey: key),
                  var values = try? JSONDecoder().decode([String: Value].self, from: data) else {
                d.removeObject(forKey: key)
                return
            }
            values.removeValue(forKey: vin)
            if values.isEmpty {
                d.removeObject(forKey: key)
            } else if let encoded = try? JSONEncoder().encode(values) {
                d.set(encoded, forKey: key)
            } else {
                d.removeObject(forKey: key)
            }
        }

        removeEntry(VehicleState.self, key: "cached_vehicle_snapshots_v1")
        if includeBaselines {
            removeEntry(ChargingBaseline.self, key: "charging_baselines_v1")
        }
    }

    var email: String {
        get {
            if let cached = cachedEmail { return cached }
            let value: String
            if let secure = (try? keychain.readEmail()) ?? nil, !secure.isEmpty {
                d.removeObject(forKey: "polestar_email")
                value = secure
            } else if let legacy = d.string(forKey: "polestar_email"), !legacy.isEmpty {
                do {
                    try keychain.saveEmail(legacy)
                    d.removeObject(forKey: "polestar_email")
                } catch {}
                value = legacy
            } else {
                value = ""
            }
            cachedEmail = value
            return value
        }
        set {
            cachedEmail = newValue
            cachedHasResumableSession[.polestar] = nil
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
        set { d.set(newValue, forKey: "volvo_client_id"); cachedHasResumableSession[.volvo] = nil }
    }
    var volvoRestrictedScopesEnabled: Bool {
        get { d.bool(forKey: "volvo_restricted_scopes_enabled") }
        set { d.set(newValue, forKey: "volvo_restricted_scopes_enabled") }
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
        if let cached = cachedHasResumableSession[brand] { return cached }
        let result: Bool
        switch brand {
        case .polestar:
            if ((try? Keychain.readSessionToken()) ?? nil)?.isEmpty == false {
                result = true
            } else {
                result = !email.isEmpty && ((try? Keychain.readPassword()) ?? nil)?.isEmpty == false
            }
        case .volvo:
            guard !volvoClientID.isEmpty else {
                result = false
                break
            }
            result = ((try? Keychain.readVolvoSessionToken()) ?? nil)?.isEmpty == false
        }
        cachedHasResumableSession[brand] = result
        return result
    }

    /// Whether the Polestar *command* client — remote locks, climate, windows, cabin cleaning,
    /// and locate — has a stored authorization. This is a separate OAuth grant from the account
    /// session (`hasResumableSession`), obtained via Settings → Remote Controls → "Authorize
    /// Remote Commands". Backed by the Keychain item `PolestarAPI` writes on success and clears
    /// (`clearCommandAuthorization()`) when the grant is rejected. Charging, timers and OTA
    /// commands do not need it.
    var hasPolestarCommandAuthorization: Bool {
        ((try? keychain.readCommandSessionToken()) ?? nil)?.isEmpty == false
    }

    /// Preferred display order of the Charging card's detail rows. Identifiers not present
    /// keep their natural position after the ordered ones — so a partial list is safe.
    var chargingStatOrder: [String] {
        get {
            guard let raw = d.array(forKey: "charging_stat_order") as? [String] else { return [] }
            return raw
        }
        set { d.set(newValue, forKey: "charging_stat_order") }
    }

    var garageVehicleOrder: [String] {
        get { d.array(forKey: "garage_vehicle_order_v1") as? [String] ?? [] }
        set { d.set(newValue, forKey: "garage_vehicle_order_v1") }
    }

    /// Floating always-on-top panel while charging.
    var floatingChargingPanelEnabled: Bool {
        get { d.bool(forKey: "floating_charging_panel") }
        set { d.set(newValue, forKey: "floating_charging_panel") }
    }

    /// Screenshot privacy mode: when on, views marked `.privacySensitive()` (VIN, plate,
    /// coordinates) render as placeholders under SwiftUI's privacy redaction.
    var privacyRedactionEnabled: Bool {
        get { d.bool(forKey: "privacy_redaction_enabled") }
        set { d.set(newValue, forKey: "privacy_redaction_enabled") }
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
    var carRenderAngle: CarRenderAngle { get { CarRenderAngle(rawValue: d.object(forKey: "car_render_angle") as? Int ?? 0) ?? .frontThreeQuarter } set { d.set(newValue.rawValue, forKey: "car_render_angle") } }
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
    var persistLocationHistory: Bool { get { d.bool(forKey: "persist_location_history") } set { d.set(newValue, forKey: "persist_location_history") } }
    var historySampleRetentionDays: Int { get { let value = d.integer(forKey: "history_sample_retention_days"); return [30, 90, 180, 365].contains(value) ? value : 90 } set { d.set([30, 90, 180, 365].contains(newValue) ? newValue : 90, forKey: "history_sample_retention_days") } }
    /// When enabled, signing out — or switching to a different account — also erases the
    /// local SQLite history (charging sessions, telemetry, battery health, fuel entries…)
    /// for the affected vehicles. Off by default: a re-signed local build, a Keychain
    /// prompt dismissed by accident, or a stray sign-out should not discard months of
    /// history. The explicit "Erase local vehicle data" action in Settings → Privacy &
    /// Data is the deliberate way to remove it.
    var eraseHistoryOnSignOut: Bool { get { d.bool(forKey: "erase_history_on_sign_out") } set { d.set(newValue, forKey: "erase_history_on_sign_out") } }
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
    /// Remote-engine-start runtime the Controls tab last used, so the picker keeps the user's
    /// choice across panel opens instead of snapping back to 15 minutes each time.
    var remoteEngineRuntimeMinutes: Int { get { let value = d.integer(forKey: "remote_engine_runtime_minutes"); return [5, 10, 15].contains(value) ? value : 15 } set { d.set(newValue, forKey: "remote_engine_runtime_minutes") } }
    var calendarPreconditioningEnabled: Bool { get { d.bool(forKey: "calendar_preconditioning_enabled_v1") } set { d.set(newValue, forKey: "calendar_preconditioning_enabled_v1") } }
    var calendarPreconditioningLeadTimeMinutes: Int { get { let value = d.integer(forKey: "calendar_preconditioning_lead_minutes_v1"); return [5, 10, 15, 20, 30, 45, 60].contains(value) ? value : 20 } set { d.set(min(max(newValue, 1), 120), forKey: "calendar_preconditioning_lead_minutes_v1") } }
    var calendarPreconditioningCalendarIDs: Set<String> { get { Set(d.stringArray(forKey: "calendar_preconditioning_calendar_ids_v1") ?? []) } set { d.set(Array(newValue).sorted(), forKey: "calendar_preconditioning_calendar_ids_v1") } }
    var calendarPreconditioningFiredOccurrences: [String: Double] { get { d.dictionary(forKey: "calendar_preconditioning_fired_v1") as? [String: Double] ?? [:] } set { d.set(newValue, forKey: "calendar_preconditioning_fired_v1") } }
    var electricityPricePerKwh: Double { get { let value = d.double(forKey: "electricity_price_per_kwh"); return value > 0 ? value : 2.0 } set { d.set(newValue, forKey: "electricity_price_per_kwh") } }
    var smartChargingPriceArea: SwedishPriceArea { get { SwedishPriceArea(rawValue: d.string(forKey: "smart_charging_price_area_v1") ?? "") ?? .se3 } set { d.set(newValue.rawValue, forKey: "smart_charging_price_area_v1") } }
    var smartChargingPowerKW: Double { get { let value = d.double(forKey: "smart_charging_power_kw_v1"); return value > 0 ? min(max(value, 1.0), 50) : 11.0 } set { d.set(min(max(newValue, 1.0), 50), forKey: "smart_charging_power_kw_v1"); d.set(true, forKey: "smart_charging_power_customized_v1") } }
    var smartChargingPowerWasCustomized: Bool { d.bool(forKey: "smart_charging_power_customized_v1") }
    var currencySymbol: String { get { let value = d.string(forKey: "electricity_currency_symbol") ?? ""; return value.isEmpty ? (Locale.current.currencySymbol ?? "kr") : value } set { d.set(newValue, forKey: "electricity_currency_symbol") } }
    /// Off-peak/night tariff, disabled by default so charging-cost estimates match
    /// `electricityPricePerKwh` unchanged unless the user opts in to a two-rate schedule.
    var nightTariffEnabled: Bool { get { d.bool(forKey: "night_tariff_enabled") } set { d.set(newValue, forKey: "night_tariff_enabled") } }
    var nightElectricityPricePerKwh: Double { get { let value = d.double(forKey: "night_electricity_price_per_kwh"); return value > 0 ? value : electricityPricePerKwh } set { d.set(newValue, forKey: "night_electricity_price_per_kwh") } }
    var nightTariffStartHour: Int { get { let value = d.object(forKey: "night_tariff_start_hour") as? Int; return min(max(value ?? 22, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "night_tariff_start_hour") } }
    var nightTariffEndHour: Int { get { let value = d.object(forKey: "night_tariff_end_hour") as? Int; return min(max(value ?? 6, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "night_tariff_end_hour") } }
    var storeChargingHistory: Bool { get { d.bool(forKey: "store_charging_history") } set { d.set(newValue, forKey: "store_charging_history") } }
    /// Well-to-wheel grid carbon intensity used only for the History tab's indicative
    /// "emissions avoided vs petrol" figure. Defaults to a middle-of-the-road European blend;
    /// a Nordic grid is far cleaner, a coal-heavy one dirtier, hence it is user-adjustable.
    var gridCarbonIntensityGramsPerKwh: Double { get { let value = d.double(forKey: "grid_carbon_intensity_g_per_kwh"); return value > 0 ? value : 120 } set { d.set(min(max(newValue, 0), 1_200), forKey: "grid_carbon_intensity_g_per_kwh") } }
    var privateNotificationDetails: Bool { get { d.object(forKey: "private_notification_details") == nil || d.bool(forKey: "private_notification_details") } set { d.set(newValue, forKey: "private_notification_details") } }
    var requireBiometricsForRemoteControls: Bool { get { d.bool(forKey: "require_biometrics_for_remote_controls") } set { d.set(newValue, forKey: "require_biometrics_for_remote_controls") } }
    var lowBatteryThreshold: Int { get { let value = d.integer(forKey: "low_battery_threshold"); return value == 0 ? 20 : min(max(value, 5), 50) } set { d.set(min(max(newValue, 5), 50), forKey: "low_battery_threshold") } }

    /// The charging session the History tab last had open, per vehicle, so switching tabs or
    /// periods doesn't snap the curve back to the newest session every time.
    func selectedHistorySession(for vin: String) -> String? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return nil }
        return (d.dictionary(forKey: "history_selected_session_v1") as? [String: String])?[key]
    }

    func setSelectedHistorySession(_ sessionID: String?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = (d.dictionary(forKey: "history_selected_session_v1") as? [String: String]) ?? [:]
        if let sessionID { values[key] = sessionID } else { values.removeValue(forKey: key) }
        d.set(values, forKey: "history_selected_session_v1")
    }

    /// Derived trips the user has chosen to hide because segmentation combined or invented
    /// them. Stored per vehicle as trip-id strings; the dashboard filters these out.
    func hiddenTripIDs(for vin: String) -> Set<String> {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "history_hidden_trips_v1") as? [String: [String]] else { return [] }
        return Set(all[key] ?? [])
    }

    func setTripHidden(_ hidden: Bool, id: String, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var all = (d.dictionary(forKey: "history_hidden_trips_v1") as? [String: [String]]) ?? [:]
        var ids = Set(all[key] ?? [])
        if hidden { ids.insert(id) } else { ids.remove(id) }
        if ids.isEmpty { all.removeValue(forKey: key) } else { all[key] = Array(ids) }
        d.set(all, forKey: "history_hidden_trips_v1")
    }

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

    func vehicleSpecificationOverride(for vin: String) -> VehicleSpecificationOverride? {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty,
              let all = d.dictionary(forKey: "vehicle_specification_overrides_v1") as? [String: Data],
              let data = all[key],
              let value = try? JSONDecoder().decode(VehicleSpecificationOverride.self, from: data),
              !value.isEmpty else { return nil }
        return value
    }

    func setVehicleSpecificationOverride(_ value: VehicleSpecificationOverride?, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var all = d.dictionary(forKey: "vehicle_specification_overrides_v1") as? [String: Data] ?? [:]
        if let value, !value.isEmpty, let data = try? JSONEncoder().encode(value) {
            all[key] = data
        } else {
            all.removeValue(forKey: key)
        }
        d.set(all, forKey: "vehicle_specification_overrides_v1")
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
    var notifyOpeningsLeftOpen: Bool { get { boolDefaultTrue("notify_openings_left_open") } set { d.set(newValue, forKey: "notify_openings_left_open") } }
    var notifyServiceDue: Bool { get { boolDefaultTrue("notify_service_due") } set { d.set(newValue, forKey: "notify_service_due") } }
    var notifyStaleTelemetry: Bool { get { boolDefaultTrue("notify_stale_telemetry") } set { d.set(newValue, forKey: "notify_stale_telemetry") } }
    var notifySlowCharging: Bool { get { boolDefaultTrue("notify_slow_charging") } set { d.set(newValue, forKey: "notify_slow_charging") } }
    var notifyRainWithWindowsOpen: Bool { get { boolDefaultTrue("notify_rain_with_windows") } set { d.set(newValue, forKey: "notify_rain_with_windows") } }
    var notifyEveningUnlocked: Bool { get { boolDefaultTrue("notify_evening_unlocked") } set { d.set(newValue, forKey: "notify_evening_unlocked") } }
    var notifyChargerConnection: Bool { get { boolDefaultTrue("notify_charger_connection") } set { d.set(newValue, forKey: "notify_charger_connection") } }
    var notifyClimateChanges: Bool { get { boolDefaultTrue("notify_climate_changes") } set { d.set(newValue, forKey: "notify_climate_changes") } }

    /// True when at least one individual alert type is on. Used to decide whether asking the
    /// system for notification authorization is worthwhile.
    var anyNotificationAlertEnabled: Bool {
        notifyChargingStarted || notifyChargingComplete || notifyChargingProblem
            || notifyLowBattery || notifySoftwareUpdates || notifyVehicleWarnings
            || notifyRainWithWindowsOpen || notifyEveningUnlocked || notifyOpeningsLeftOpen
            || notifyServiceDue || notifyStaleTelemetry || notifySlowCharging
            || notifyPlugInReminder || notifyChargerConnection || notifyClimateChanges
    }
    var openingsAlertDelayMinutes: Int { get { let value = d.integer(forKey: "notify_openings_delay_minutes"); return min(max(value == 0 ? 15 : value, 5), 60) } set { d.set(min(max(newValue, 5), 60), forKey: "notify_openings_delay_minutes") } }
    var plugInReminderThreshold: Int { get { let value = d.integer(forKey: "notify_plugin_threshold"); return min(max(value == 0 ? 40 : value, 10), 80) } set { d.set(min(max(newValue, 10), 80), forKey: "notify_plugin_threshold") } }
    var eveningUnlockedStartHour: Int { get { let value = d.object(forKey: "notify_evening_unlocked_hour") as? Int; return min(max(value ?? 21, 18), 23) } set { d.set(min(max(newValue, 18), 23), forKey: "notify_evening_unlocked_hour") } }

    /// Update preferences are intentionally separate from vehicle notifications. The
    /// defaults follow macOS convention: check in the background, but do not download or
    /// install executable updates until the user asks Sparkle to do so.
    var automaticallyChecksForUpdates: Bool { get { boolDefaultTrue("automatically_check_for_updates") } set { d.set(newValue, forKey: "automatically_check_for_updates") } }
    var automaticallyDownloadsUpdates: Bool { get { d.bool(forKey: "automatically_download_updates") } set { d.set(newValue, forKey: "automatically_download_updates") } }

    /// Audible cue on urgent notifications (security, warnings, charging problems).
    /// Routine informational banners stay silent regardless.
    var notifySounds: Bool { get { boolDefaultTrue("notify_sounds") } set { d.set(newValue, forKey: "notify_sounds") } }

    /// Hold non-urgent notifications during the configured window; urgent security
    /// banners bypass it. Hours are wall-clock, start == end disables the window.
    var quietHoursEnabled: Bool { get { d.bool(forKey: "notify_quiet_hours_enabled") } set { d.set(newValue, forKey: "notify_quiet_hours_enabled") } }
    var quietHoursStartHour: Int { get { let value = d.object(forKey: "notify_quiet_hours_start") as? Int; return min(max(value ?? 22, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "notify_quiet_hours_start") } }
    var quietHoursEndHour: Int { get { let value = d.object(forKey: "notify_quiet_hours_end") as? Int; return min(max(value ?? 7, 0), 23) } set { d.set(min(max(newValue, 0), 23), forKey: "notify_quiet_hours_end") } }

    /// Per-VIN notification mute: baselines keep advancing while muted so un-muting
    /// never replays a burst of stale edge events.
    func isMuted(vin: String) -> Bool {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return false }
        return (d.array(forKey: "muted_vehicle_vins_v1") as? [String])?.contains(key) ?? false
    }
    func setMuted(_ muted: Bool, for vin: String) {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !key.isEmpty else { return }
        var values = d.array(forKey: "muted_vehicle_vins_v1") as? [String] ?? []
        if muted { if !values.contains(key) { values.append(key) } }
        else { values.removeAll { $0 == key } }
        d.set(values, forKey: "muted_vehicle_vins_v1")
    }

    /// Optional dock-tile badge with the number of vehicles that currently report
    /// active warnings or a triggered alarm. Off by default; the app runs as a menu-bar
    /// agent for most users, so the badge only shows when the dock icon does.
    var showWarningBadge: Bool { get { d.bool(forKey: "show_warning_badge") } set { d.set(newValue, forKey: "show_warning_badge") } }

    var features: FeatureSelection {
        get {
            if let values = d.array(forKey: "enabled_features_v2") as? [String] {
                // The stored selection is authoritative. Earlier versions force-enabled
                // three presentation features on every read, which made their Settings
                // toggles appear to work only until the next launch.
                return FeatureSelection(
                    enabled: Set(values.compactMap(AppFeature.init))
                        .intersection(AppFeature.permittedFeatures)
                )
            }
            // v1 installs predate the .notifications case; it shipped default-on, so the
            // migration must carry it forward or upgraders silently lose every alert.
            if let values = d.array(forKey: "enabled_features_v1") as? [String] { var set = Set(values.compactMap(AppFeature.init)); set.formUnion([.exteriorStatus, .tyreAndWarnings, .softwareUpdates, .chargingSchedule, .climateStatus, .tripMeters, .notifications]); let result = FeatureSelection(enabled: set.intersection(AppFeature.permittedFeatures)); d.set(result.enabled.map(\.rawValue).sorted(), forKey: "enabled_features_v2"); return result }
            var result = FeatureSelection.default; if d.bool(forKey: "show_vehicle_image") { result.set(.vehicleImage, enabled: true) }; return result
        }
        set { d.set(newValue.enabled.intersection(AppFeature.permittedFeatures).map(\.rawValue).sorted(), forKey: "enabled_features_v2"); d.removeObject(forKey: "enabled_features_v1"); d.removeObject(forKey: "show_vehicle_image") }
    }

    func theme(for vin: String, brand: VehicleBrand? = nil) -> AppTheme { let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); if let values = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String], let theme = values[key].flatMap(AppTheme.init) { return theme }; let resolved = brand ?? (key.isEmpty ? activeBrand : (key.hasPrefix("YV") ? .volvo : activeBrand)); if let theme = d.string(forKey: "theme_for_\(resolved.rawValue)").flatMap(AppTheme.init) { return theme }; return resolved == .volvo ? .volvo : .polestar }
    func setTheme(_ theme: AppTheme, for vin: String, brand: VehicleBrand? = nil) { let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(); if !key.isEmpty { var values = d.dictionary(forKey: "vehicle_themes_v1") as? [String: String] ?? [:]; values[key] = theme.rawValue; d.set(values, forKey: "vehicle_themes_v1") }; d.set(theme.rawValue, forKey: "theme_for_\((brand ?? activeBrand).rawValue)"); d.set(theme.rawValue, forKey: "app_theme") }
    var appTheme: AppTheme { get { vin.isEmpty ? (d.string(forKey: "theme_for_\(activeBrand.rawValue)").flatMap(AppTheme.init) ?? AppTheme(rawValue: d.string(forKey: "app_theme") ?? "") ?? (activeBrand == .volvo ? .volvo : .polestar)) : theme(for: vin, brand: activeBrand) } set { setTheme(newValue, for: vin, brand: activeBrand) } }
    func syncAppThemeStorageKey() { d.set(appTheme.rawValue, forKey: "app_theme") }
    func applyAppearance() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        NSApplication.shared.appearance = appearanceMode.nsAppearance
    }
    func migrateLegacyPassword() { guard let legacy = d.string(forKey: "polestar_password"), !legacy.isEmpty else { return }; do { if try Keychain.readPassword() == nil { try Keychain.savePassword(legacy) }; d.removeObject(forKey: "polestar_password") } catch { logger.error("Legacy Polestar password migration to Keychain failed: \(String(describing: error), privacy: .public)") } }

    /// Bundle identifiers the app shipped with before `CFBundleIdentifier` was collapsed to
    /// `io.kheirallah.hisingen`. Each was a distinct `UserDefaults` domain.
    static let legacyDefaultsDomains = ["io.kheirallah.hisingen-cc97f41c-af39-4eb1-a7e6-0014f6e1c80f"]

    /// One-time carry-over of stored preferences from a previous bundle identifier.
    /// `UserDefaults.standard` is keyed on `CFBundleIdentifier`, so without this the feature
    /// selection, per-VIN nickname and theme maps, unit choices and notification tuning would
    /// all silently reset on the update that changes the identifier. Keychain credentials and
    /// the SQLite database live outside the defaults domain and are unaffected regardless.
    /// Existing keys are never overwritten, so running this after real use is a no-op.
    func migrateLegacyDefaults(domains: [String] = PreferencesStore.legacyDefaultsDomains) {
        let flagKey = "defaults_domain_migrated_v1"
        guard !d.bool(forKey: flagKey) else { return }
        for domain in domains where domain != Bundle.main.bundleIdentifier {
            guard let legacy = d.persistentDomain(forName: domain), !legacy.isEmpty else { continue }
            var carried = 0
            for (key, value) in legacy where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
                carried += 1
            }
            if carried > 0 {
                logger.notice("Carried \(carried, privacy: .public) preference key(s) forward from \(domain, privacy: .public)")
            }
        }
        d.set(true, forKey: flagKey)
    }
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
