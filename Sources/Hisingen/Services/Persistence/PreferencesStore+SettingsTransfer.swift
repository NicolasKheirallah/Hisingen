import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
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
            "update_check_interval",
            "show_warning_badge", "grid_carbon_intensity_g_per_kwh", "tab_composition_v1"
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
}
