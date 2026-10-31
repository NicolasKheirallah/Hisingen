import Testing
@testable import Hisingen

/// Settings search is section based, so a control that moved into Accounts has to answer the
/// word a reader types. "authorize" matched nothing before the grant row became reachable from
/// both pages, which is how the control stayed invisible on Features.
struct SettingsSectionSearchTests {
    @Test func authorizationTermsReachTheAccountsSection() {
        #expect(SettingsSection.accounts.matches("authorize"))
        #expect(SettingsSection.accounts.matches("authorization"))
        #expect(SettingsSection.accounts.matches("remote command"))
        #expect(SettingsSection.accounts.matches("remote commands"))
        #expect(SettingsSection.accounts.matches("commands"))
    }

    @Test func authorizationTermsReachTheFeaturesSection() {
        #expect(SettingsSection.features.matches("authorize"))
        #expect(SettingsSection.features.matches("authorization"))
        #expect(SettingsSection.features.matches("remote command"))
        #expect(SettingsSection.features.matches("remote commands"))
        #expect(SettingsSection.features.matches("commands"))
    }

    /// Search stays case- and whitespace-insensitive, so the new terms inherit the rule rather
    /// than adding a second one.
    @Test func authorizationTermsIgnoreCaseAndPadding() {
        #expect(SettingsSection.accounts.matches("  Authorize  "))
        #expect(SettingsSection.features.matches("  Authorize  "))
    }
}
