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

/// Reader-made themes.
///
/// The database's `custom_themes` table is the durable copy: it lives in Application Support,
/// so themes survive app updates, a reinstalled app bundle and a reset preferences domain. The
/// preferences key `custom_themes_v1` is a mirror for fast reads (palette lookups happen on every
/// token read) and travels with a settings export. The first read of each launch reconciles the
/// two, so a theme missing from either side is copied across.
enum CustomThemeStore {
    static let key = "custom_themes_v1"

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var definitions: [String: [CustomThemeDefinition]] = [:]
        var palettes: [CustomThemeDefinition: Palette] = [:]
        var reconciled = false
    }

    /// The app's own database, only when running as the app. Tests and previews never reach the
    /// reader's real database by accident; they pass an in-memory one explicitly.
    static var appDatabase: VehicleDatabase? {
        Bundle.main.bundleIdentifier == "io.kheirallah.hisingen" ? VehicleDatabase.shared : nil
    }

    private static func database(for defaults: UserDefaults) -> VehicleDatabase? {
        defaults === UserDefaults.standard ? appDatabase : nil
    }

    private static let cache = Cache()

    private static func cacheKey(_ defaults: UserDefaults) -> String {
        defaults === UserDefaults.standard ? "standard" : String(describing: ObjectIdentifier(defaults))
    }

    static func all(defaults: UserDefaults = .standard) -> [CustomThemeDefinition] {
        if defaults === UserDefaults.standard { reconcileOnce() }
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
    static func save(_ definition: CustomThemeDefinition, defaults: UserDefaults = .standard,
                     database: VehicleDatabase? = nil) {
        (database ?? Self.database(for: defaults))?.customThemes.upsert(definition)
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
    static func delete(id: String, defaults: UserDefaults = .standard, database: VehicleDatabase? = nil) {
        (database ?? Self.database(for: defaults))?.customThemes.delete(id: id)
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

    /// Drops the cached lists, after something outside this store rewrote `custom_themes_v1`
    /// (a settings import). The next read decodes again and writes any new themes to the database.
    static func invalidate() {
        cache.lock.lock()
        cache.definitions = [:]
        cache.palettes = [:]
        cache.reconciled = false
        cache.lock.unlock()
    }

    private static func reconcileOnce() {
        cache.lock.lock()
        let pending = !cache.reconciled
        cache.reconciled = true
        cache.lock.unlock()
        guard pending, let database = appDatabase else { return }
        reconcile(defaults: .standard, database: database)
    }

    /// Makes the preferences mirror and the database agree. Themes only in the database come
    /// back into preferences (an update or reset cleared them); themes only in preferences, or
    /// newer there, are written to the database (themes made before the table existed).
    static func reconcile(defaults: UserDefaults, database: VehicleDatabase) {
        let mirrored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([CustomThemeDefinition].self, from: $0) } ?? []
        let stored = database.customThemes.all()
        for definition in mirrored where stored.first(where: { $0.id == definition.id }) != definition {
            database.customThemes.upsert(definition)
        }
        let merged = mirrored + stored.filter { saved in !mirrored.contains { $0.id == saved.id } }
        if merged != mirrored {
            write(merged, defaults: defaults)
        } else {
            cache.lock.lock()
            cache.definitions[cacheKey(defaults)] = merged
            cache.lock.unlock()
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
