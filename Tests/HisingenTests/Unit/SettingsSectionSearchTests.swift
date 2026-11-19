import Testing
@testable import Hisingen

struct SettingsSectionSearchTests {
    @Test
    func authorizationSearchFindsTheAccountEditor() {
        for query in ["authorize", "authorization", "remote command", "remote commands", "commands", "  Authorize  "] {
            #expect(SettingsSection.accounts.matches(query))
            #expect(SettingsDestination.remoteAuthorization.matches(query))
        }
        #expect(!SettingsSection.features.matches("authorize"))
        #expect(SettingsDestination.remoteFeatures.matches("remote command"))
    }

    @Test
    func movedPreferencesKeepTheirSearchAliases() {
        #expect(SettingsDestination.privacy.matches("screenshot privacy"))
        #expect(SettingsDestination.vehicleReferences.matches("warranty date"))
        #expect(SettingsDestination.electricity.matches("PRICE ZONE"))
        #expect(SettingsDestination.plannerAlerts.matches("cheap window lead"))
        #expect(SettingsDestination.nowControls.matches("limit step"))
        #expect(SettingsDestination.chargingLayout.matches("charging order"))
        #expect(SettingsDestination.panel.matches("panel size"))
        #expect(SettingsDestination.updates.matches("app update check"))
        #expect(!SettingsDestination.appearance.matches("screenshot privacy"))
    }
}
