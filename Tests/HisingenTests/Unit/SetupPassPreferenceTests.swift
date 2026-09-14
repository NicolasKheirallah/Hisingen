import Foundation
import Testing
@testable import Hisingen

@MainActor
struct SetupPassPreferenceTests {
    private let suite = "SetupPassPreferenceTests.\(UUID())"

    private func makePreferences() throws -> (PreferencesStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())")), defaults)
    }

    @Test
    func flagIsAbsentUntilThePassCompletesAndSurvivesADefaultsReload() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        // Absent, not merely false: seeding distinguishes "never asked" from "declined".
        #expect(defaults.object(forKey: "setup_pass_completed") == nil)
        preferences.hasCompletedSetupPass = true
        let reloaded = PreferencesStore(defaults: defaults)
        #expect(reloaded.hasCompletedSetupPass)
    }

    @Test
    func seedingMarksAnInstallWithStoredSessionMaterialAsPastThePass() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.seedSetupPassForExistingInstall(hasSessionMaterial: { _ in true })
        #expect(preferences.hasCompletedSetupPass)
    }

    @Test
    func seedingLeavesAFreshInstallUntouchedSoThePassStillShows() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.seedSetupPassForExistingInstall(hasSessionMaterial: { _ in false })
        #expect(defaults.object(forKey: "setup_pass_completed") == nil)
    }

    @Test
    func seedingNeverOverridesAnExplicitDecision() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.hasCompletedSetupPass = false
        preferences.seedSetupPassForExistingInstall(hasSessionMaterial: { _ in true })
        #expect(preferences.hasCompletedSetupPass == false)
    }

    @Test
    func theFlagDoesNotTravelInASettingsTransfer() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.hasCompletedSetupPass = true
        let propertyList = try #require(try? preferences.exportSettingsPropertyList())
        let imported = try #require(try? PropertyListSerialization.propertyList(
            from: propertyList, options: [], format: nil) as? [String: Any])
        #expect(imported["setup_pass_completed"] == nil)
    }
}
