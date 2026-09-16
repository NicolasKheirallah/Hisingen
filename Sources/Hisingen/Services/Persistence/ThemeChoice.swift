import Foundation

/// Resolves and assigns the application theme across explicit vehicle and brand scopes.
///
/// Separates theme resolution and assignment into a pure, testable module with explicit scoping
/// rather than scattering fallback logic and storage fan-out across callers.
struct ThemeChoice: Sendable {

    /// The target scope for a theme assignment.
    enum Scope: Sendable, Equatable {
        /// Assigned specifically to a vehicle identified by VIN.
        case vehicle(String)
        /// Assigned to an entire brand fleet (e.g. Polestar or Volvo).
        case brand(VehicleBrand)
    }

    /// Resolves the theme for a specific vehicle and brand context from UserDefaults.
    ///
    /// Resolution order:
    /// 1. Explicit theme mapped to this vehicle's VIN in `vehicle_themes_v1`
    /// 2. Brand-level default theme in `theme_for_<brand>`
    /// 3. Global `app_theme` setting
    /// 4. Default brand theme (`.volvo` for Volvo, `.polestar` for Polestar)
    static func resolve(
        vin: String,
        brand: VehicleBrand,
        defaults: UserDefaults = .standard
    ) -> AppTheme {
        let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !key.isEmpty,
           let values = defaults.dictionary(forKey: "vehicle_themes_v1") as? [String: String],
           let stored = values[key],
           let theme = AppTheme(rawValue: stored) {
            return theme
        }

        if let brandStored = defaults.string(forKey: "theme_for_\(brand.rawValue)"),
           let brandTheme = AppTheme(rawValue: brandStored) {
            return brandTheme
        }

        if key.isEmpty,
           let appStored = defaults.string(forKey: "app_theme"),
           let appTheme = AppTheme(rawValue: appStored) {
            return appTheme
        }

        return brand == .volvo ? .volvo : .polestar
    }

    /// Assigns a theme at an explicit scope.
    static func assign(
        _ theme: AppTheme,
        scope: Scope,
        defaults: UserDefaults = .standard
    ) {
        switch scope {
        case .vehicle(let vin):
            let key = vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !key.isEmpty {
                var values = defaults.dictionary(forKey: "vehicle_themes_v1") as? [String: String] ?? [:]
                values[key] = theme.rawValue
                defaults.set(values, forKey: "vehicle_themes_v1")
            }
            defaults.set(theme.rawValue, forKey: "app_theme")
        case .brand(let brand):
            defaults.set(theme.rawValue, forKey: "theme_for_\(brand.rawValue)")
            defaults.set(theme.rawValue, forKey: "app_theme")
        }
    }
}
