import Foundation
import Testing
@testable import Hisingen

@MainActor
struct FirstLaunchWelcomeTests {
    private let suite = "FirstLaunchWelcomeTests.\(UUID())"

    private func makePreferences() throws -> (PreferencesStore, UserDefaults) {
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (PreferencesStore(
            defaults: defaults,
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID())")), defaults)
    }

    @Test
    func markingIsIdempotentAndSurvivesADefaultsReload() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(!preferences.hasSeenFirstLaunchWelcome)
        preferences.markFirstLaunchWelcomeSeen()
        preferences.markFirstLaunchWelcomeSeen()
        #expect(PreferencesStore(defaults: defaults).hasSeenFirstLaunchWelcome)
    }

    @Test
    func theWelcomeFlagDoesNotTravelInASettingsTransfer() throws {
        let (preferences, defaults) = try makePreferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.markFirstLaunchWelcomeSeen()
        let propertyList = try #require(try? preferences.exportSettingsPropertyList())
        let imported = try #require(try? PropertyListSerialization.propertyList(
            from: propertyList, options: [], format: nil) as? [String: Any])
        #expect(imported["first_launch_welcome_seen"] == nil)
    }
}
