import Foundation
import Testing
@testable import Hisingen

@MainActor
struct SettingsPreferenceTests {
    private func store() throws -> (PreferencesStore, UserDefaults, String) {
        let suite = "SettingsPreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return (PreferencesStore(defaults: defaults), defaults, suite)
    }

    @Test
    func savedFeatureOptOutsSurviveAReadAndRelaunch() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        var selection = FeatureSelection.default
        selection.set(.vehicleLocation, enabled: false)
        selection.set(.vehicleWeather, enabled: false)
        selection.set(.ownerGreeting, enabled: false)
        preferences.features = selection

        let relaunched = PreferencesStore(defaults: defaults)
        XCTAssertFalse(relaunched.features.contains(.vehicleLocation))
        XCTAssertFalse(relaunched.features.contains(.vehicleWeather))
        XCTAssertFalse(relaunched.features.contains(.ownerGreeting))
    }

    @Test
    func safeBulkEnableNeverIncludesRemoteCommands() {
        XCTAssertFalse(AppFeature.safeBulkEnableCases.isEmpty)
        XCTAssertTrue(Set(AppFeature.safeBulkEnableCases).isDisjoint(with: AppFeature.remoteFeatures))
        XCTAssertTrue(AppFeature.remoteFeatures.allSatisfy(\.isRemoteControl))
    }

    @Test
    func settingsSearchFindsWholeSectionsAndCanReturnNoResults() {
        XCTAssertTrue(SettingsSection.accounts.matches("VIN"))
        XCTAssertTrue(SettingsSection.privacyData.matches("backup"))
        XCTAssertTrue(SettingsSection.notifications.matches("quiet hours"))
        XCTAssertFalse(SettingsSection.appearance.matches("battery alert"))
    }

    @Test
    func panelPresetCanPersistentlyDisableCustomGeometry() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.customPanelSizeEnabled = true

        preferences.panelSize = .large
        preferences.customPanelSizeEnabled = false

        let relaunched = PreferencesStore(defaults: defaults)
        XCTAssertEqual(relaunched.panelSize, .large)
        XCTAssertFalse(relaunched.customPanelSizeEnabled)
    }

    @Test
    func settingsArchiveExcludesIdentityAndRestoresSafePreferences() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("driver@example.invalid", forKey: "polestar_email")
        defaults.set("YSM12345678901234", forKey: "polestar_vin")
        defaults.set("secret-session", forKey: "session_token")
        preferences.garageVehicleOrder = ["YSM12345678901234"]
        preferences.panelSize = .large
        preferences.notifySounds = false
        var features = FeatureSelection.default
        features.set(.remoteLocks, enabled: true)
        preferences.features = features

        let data = try preferences.exportSettingsPropertyList()
        let archive = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        XCTAssertNil(archive["polestar_email"])
        XCTAssertNil(archive["polestar_vin"])
        XCTAssertNil(archive["session_token"])
        XCTAssertNil(archive["garage_vehicle_order_v1"])
        XCTAssertEqual(archive["panel_size"] as? String, PanelSize.large.rawValue)
        XCTAssertFalse((archive["enabled_features_v2"] as? [String] ?? []).contains(AppFeature.remoteLocks.rawValue))

        preferences.panelSize = .compact
        preferences.notifySounds = true
        try preferences.importSettingsPropertyList(data)
        XCTAssertEqual(preferences.panelSize, .large)
        XCTAssertFalse(preferences.notifySounds)
        XCTAssertFalse(preferences.features.contains(.remoteLocks))
    }

    @Test
    func settingsArchiveRejectsIdentityKeys() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["polestar_email": "attacker@example.invalid"],
            format: .xml,
            options: 0
        )
        #expect(throws: PreferencesStore.SettingsTransferError.self) {
            try preferences.importSettingsPropertyList(data)
        }
    }

    @Test
    func retentionAndNotificationThresholdsAreBounded() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.historySampleRetentionDays = 12
        preferences.openingsAlertDelayMinutes = 999
        preferences.plugInReminderThreshold = 1
        preferences.eveningUnlockedStartHour = 4
        XCTAssertEqual(preferences.historySampleRetentionDays, 90)
        XCTAssertEqual(preferences.openingsAlertDelayMinutes, 60)
        XCTAssertEqual(preferences.plugInReminderThreshold, 10)
        XCTAssertEqual(preferences.eveningUnlockedStartHour, 18)
    }

    @Test
    func customNotificationConditionsHonorThresholds() {
        let state = VehicleState(
            batteryPercentage: 35, rangeKm: 200, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .none, chargerConnection: .disconnected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: nil, vin: "YSM12345678901234", ownerFirstName: nil,
            odometerKm: 1_000, imageData: nil, fetchedAt: Date(),
            vehicleReportedAt: Date(), dataWarnings: []
        )
        XCTAssertTrue(Notifier.plugInReminderCondition(state, threshold: 40))
        XCTAssertFalse(Notifier.plugInReminderCondition(state, threshold: 30))
    }
}
