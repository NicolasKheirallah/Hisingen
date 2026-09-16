import Foundation
import Testing
@testable import Hisingen

struct ThemeChoiceTests {

    private func makeDefaults() throws -> (UserDefaults, String) {
        let suiteName = "HisingenThemeChoiceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, suiteName)
    }

    @Test
    func testResolveDefaultsByBrand() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(ThemeChoice.resolve(vin: "", brand: .polestar, defaults: defaults) == .polestar)
        #expect(ThemeChoice.resolve(vin: "", brand: .volvo, defaults: defaults) == .volvo)
    }

    @Test
    func testResolveFallsBackToGlobalAppTheme() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppTheme.aurora.rawValue, forKey: "app_theme")
        #expect(ThemeChoice.resolve(vin: "", brand: .polestar, defaults: defaults) == .aurora)
        #expect(ThemeChoice.resolve(vin: "", brand: .volvo, defaults: defaults) == .aurora)
    }

    @Test
    func testResolveBrandThemeOverridesGlobal() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(AppTheme.hisingen.rawValue, forKey: "app_theme")
        defaults.set(AppTheme.swedishGold.rawValue, forKey: "theme_for_polestar")
        defaults.set(AppTheme.cyanRacing.rawValue, forKey: "theme_for_volvo")

        #expect(ThemeChoice.resolve(vin: "", brand: .polestar, defaults: defaults) == .swedishGold)
        #expect(ThemeChoice.resolve(vin: "", brand: .volvo, defaults: defaults) == .cyanRacing)
    }

    @Test
    func testResolvePerVehicleVINOverridesBrandAndGlobal() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let vin = "YS2E1234567890123"
        defaults.set(AppTheme.hisingen.rawValue, forKey: "app_theme")
        defaults.set(AppTheme.swedishGold.rawValue, forKey: "theme_for_polestar")
        defaults.set([vin: AppTheme.sandDune.rawValue], forKey: "vehicle_themes_v1")

        #expect(ThemeChoice.resolve(vin: vin, brand: .polestar, defaults: defaults) == .sandDune)
        // Another VIN without mapping still uses brand
        #expect(ThemeChoice.resolve(vin: "OTHERVIN", brand: .polestar, defaults: defaults) == .swedishGold)
    }

    @Test
    func testAssignVehicleScopeWritesVehicleAndAppTheme() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let vin = "YS2E1234567890123"
        ThemeChoice.assign(.forest, scope: .vehicle(vin), defaults: defaults)

        let values = defaults.dictionary(forKey: "vehicle_themes_v1") as? [String: String]
        #expect(values?[vin] == AppTheme.forest.rawValue)
        #expect(defaults.string(forKey: "app_theme") == AppTheme.forest.rawValue)
        // Brand theme should not have been overwritten
        #expect(defaults.string(forKey: "theme_for_polestar") == nil)
    }

    @Test
    func testAssignBrandScopeWritesBrandAndAppTheme() throws {
        let (defaults, suite) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        ThemeChoice.assign(.nordicNight, scope: .brand(.polestar), defaults: defaults)

        #expect(defaults.string(forKey: "theme_for_polestar") == AppTheme.nordicNight.rawValue)
        #expect(defaults.string(forKey: "app_theme") == AppTheme.nordicNight.rawValue)
        #expect(defaults.dictionary(forKey: "vehicle_themes_v1") == nil)
    }
}
