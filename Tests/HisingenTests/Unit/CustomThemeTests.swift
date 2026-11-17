import Foundation
import Testing
@testable import Hisingen

struct CustomThemeTests {
    @Test func shippedAndCustomThemesRoundTripThroughTheirRawValue() throws {
        for theme in AppTheme.allCases + [.custom("ABC-123")] {
            #expect(AppTheme(rawValue: theme.rawValue) == theme)
            let data = try JSONEncoder().encode(theme)
            #expect(try JSONDecoder().decode(AppTheme.self, from: data) == theme)
        }
        #expect(AppTheme(rawValue: "custom:") == nil)
        #expect(AppTheme(rawValue: "unknown") == nil)
        #expect(!AppTheme.allCases.contains { $0.customID != nil })
    }

    /// Picked colours that would fail on their own: mid-grey and saturated backgrounds, and
    /// accents that vanish on white or on black.
    static let hostile: [CustomThemeDefinition] = {
        let accents = ["#FFFFFF", "#000000", "#FFFF00", "#00FFFF", "#FF0000", "#808080", "#B5770F", "#1E90FF"]
        let lights = ["#FFFFFF", "#808080", "#FFD400", "#2B2B2B", "#E8F0FF"]
        let darks = ["#000000", "#808080", "#FFFFFF", "#003366", "#1A1A1A"]
        var out: [CustomThemeDefinition] = []
        for accent in accents {
            for light in lights {
                for dark in darks {
                    out.append(CustomThemeDefinition(id: "t", name: "t", accentHex: accent,
                                                     lightBackgroundHex: light, darkBackgroundHex: dark))
                }
            }
        }
        return out
    }()

    @Test(arguments: hostile)
    func everyTextPairClearsAAInBothAppearances(_ definition: CustomThemeDefinition) {
        let c = CustomThemeColors.resolve(definition)
        for (canvas, ink, muted, accent, lift, sink) in [
            (c.canvasLight, c.inkLight, c.mutedLight, c.accentLight, 0.55, 0.05),
            (c.canvasDark, c.inkDark, c.mutedDark, c.accentDark, 0.16, 0.28)
        ] {
            let card = canvas.surface(lift: lift, sink: 0)
            let chip = canvas.surface(lift: lift, sink: sink)
            for surface in [canvas, card, chip] {
                #expect(ink.contrast(with: surface) >= 4.5)
                #expect(muted.contrast(with: surface) >= 4.5)
            }
            for surface in [canvas, card, canvas.mixed(with: accent, 0.12)] {
                #expect(accent.contrast(with: surface) >= 4.5, "\(definition.accentHex) on \(surface.hex)")
            }
        }
    }

    @Test func readableColoursAreKeptAsPicked() {
        let definition = CustomThemeDefinition(id: "t", name: "t", accentHex: "#A3390A",
                                               lightBackgroundHex: "#FFFFFF", darkBackgroundHex: "#000000")
        let c = CustomThemeColors.resolve(definition)
        #expect(c.canvasLight.hex == "#FFFFFF")
        #expect(c.canvasDark.hex == "#000000")
        #expect(c.accentLight.hex == "#A3390A")
    }

    @Test func storeSavesReplacesAndDeletesWithFallback() throws {
        let suite = "io.kheirallah.hisingen.tests.customthemes.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var definition = CustomThemeDefinition.blank(named: "Fjord")
        CustomThemeStore.save(definition, defaults: defaults)
        #expect(CustomThemeStore.all(defaults: defaults).map(\.name) == ["Fjord"])

        definition.name = "Fjord at night"
        CustomThemeStore.save(definition, defaults: defaults)
        #expect(CustomThemeStore.all(defaults: defaults).map(\.name) == ["Fjord at night"])

        ThemeChoice.assign(definition.theme, scope: .vehicle("VIN1"), defaults: defaults)
        ThemeChoice.assign(definition.theme, scope: .brand(.polestar), defaults: defaults)
        #expect(ThemeChoice.resolve(vin: "VIN1", brand: .polestar, defaults: defaults) == definition.theme)

        CustomThemeStore.delete(id: definition.id, defaults: defaults)
        #expect(CustomThemeStore.all(defaults: defaults).isEmpty)
        #expect(defaults.string(forKey: "app_theme") == AppTheme.hisingen.rawValue)
        #expect(ThemeChoice.resolve(vin: "VIN1", brand: .polestar, defaults: defaults) != definition.theme)
    }

    @Test func themesComeBackFromTheDatabaseWhenPreferencesAreCleared() throws {
        let suite = "io.kheirallah.hisingen.tests.customthemes.db.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()

        let fjord = CustomThemeDefinition.blank(named: "Fjord")
        CustomThemeStore.save(fjord, defaults: defaults, database: database)
        #expect(database.customThemes.all() == [fjord])

        // An update, a reinstall or a reset clears the preferences mirror.
        defaults.removeObject(forKey: CustomThemeStore.key)
        CustomThemeStore.invalidate()
        CustomThemeStore.reconcile(defaults: defaults, database: database)
        #expect(CustomThemeStore.all(defaults: defaults) == [fjord])

        CustomThemeStore.delete(id: fjord.id, defaults: defaults, database: database)
        #expect(database.customThemes.all().isEmpty)
    }

    @Test func themesMadeBeforeTheTableExistedMoveIntoTheDatabase() throws {
        let suite = "io.kheirallah.hisingen.tests.customthemes.legacy.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = VehicleDatabase.inMemory()

        let legacy = CustomThemeDefinition.blank(named: "Legacy")
        defaults.set(try JSONEncoder().encode([legacy]), forKey: CustomThemeStore.key)
        CustomThemeStore.reconcile(defaults: defaults, database: database)
        #expect(database.customThemes.all() == [legacy])
    }
}
