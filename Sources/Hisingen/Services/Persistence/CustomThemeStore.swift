import Foundation

/// A theme the reader made: a name and three colours. Everything else in its palette is derived
/// by ``Palette/custom(_:)``, which also adjusts the colours until text and accent stay readable.
struct CustomThemeDefinition: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var name: String
    /// `#RRGGBB`, as picked. The palette may darken or lighten it per appearance for contrast.
    var accentHex: String
    var lightBackgroundHex: String
    var darkBackgroundHex: String

    static func blank(named name: String) -> CustomThemeDefinition {
        CustomThemeDefinition(id: UUID().uuidString, name: name,
                              accentHex: "#B5770F", lightBackgroundHex: "#FFFFFF", darkBackgroundHex: "#000000")
    }

    var theme: AppTheme { .custom(id) }
}

/// Reader-made themes, kept as one JSON list in `custom_themes_v1`.
///
/// Palette lookups happen on every token read, so decoded definitions are cached and the cache
/// is replaced on every save.
enum CustomThemeStore {
    static let key = "custom_themes_v1"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var definitions: [String: [CustomThemeDefinition]] = [:]
        var palettes: [CustomThemeDefinition: Palette] = [:]
    }

    private static let cache = Cache()

    private static func cacheKey(_ defaults: UserDefaults) -> String {
        defaults === UserDefaults.standard ? "standard" : String(describing: ObjectIdentifier(defaults))
    }

    static func all(defaults: UserDefaults = .standard) -> [CustomThemeDefinition] {
        let key = cacheKey(defaults)
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let cached = cache.definitions[key] { return cached }
        let decoded = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([CustomThemeDefinition].self, from: $0) } ?? []
        cache.definitions[key] = decoded
        return decoded
    }

    static func definition(id: String, defaults: UserDefaults = .standard) -> CustomThemeDefinition? {
        all(defaults: defaults).first { $0.id == id }
    }

    /// Adds the definition, or replaces the one with the same id.
    static func save(_ definition: CustomThemeDefinition, defaults: UserDefaults = .standard) {
        var list = all(defaults: defaults)
        if let index = list.firstIndex(where: { $0.id == definition.id }) {
            list[index] = definition
        } else {
            list.append(definition)
        }
        write(list, defaults: defaults)
    }

    /// Removes the theme. Anything that pointed at it falls back to the default palette, and the
    /// global selection moves back to Hisingen so the panel never names a missing theme.
    static func delete(id: String, defaults: UserDefaults = .standard) {
        write(all(defaults: defaults).filter { $0.id != id }, defaults: defaults)
        let raw = AppTheme.custom(id).rawValue
        if defaults.string(forKey: "app_theme") == raw {
            defaults.set(AppTheme.hisingen.rawValue, forKey: "app_theme")
        }
        for brand in VehicleBrand.allCases where defaults.string(forKey: "theme_for_\(brand.rawValue)") == raw {
            defaults.removeObject(forKey: "theme_for_\(brand.rawValue)")
        }
        if var vehicles = defaults.dictionary(forKey: "vehicle_themes_v1") as? [String: String] {
            vehicles = vehicles.filter { $0.value != raw }
            defaults.set(vehicles, forKey: "vehicle_themes_v1")
        }
    }

    private static func write(_ list: [CustomThemeDefinition], defaults: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) {
            defaults.set(data, forKey: Self.key)
        }
        cache.lock.lock()
        cache.definitions[cacheKey(defaults)] = list
        cache.palettes = [:]
        cache.lock.unlock()
    }

    /// The palette for a definition, built once per distinct definition.
    static func palette(for definition: CustomThemeDefinition) -> Palette {
        cache.lock.lock()
        if let cached = cache.palettes[definition] {
            cache.lock.unlock()
            return cached
        }
        cache.lock.unlock()
        let built = Palette.custom(definition)
        cache.lock.lock()
        cache.palettes[definition] = built
        cache.lock.unlock()
        return built
    }
}
