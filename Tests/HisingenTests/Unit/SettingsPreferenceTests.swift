import Foundation
import Testing
@testable import Hisingen

@MainActor
struct SettingsPreferenceTests {
    private func store() throws -> (PreferencesStore, UserDefaults, String) {
        let suite = "SettingsPreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
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
        #expect(!(relaunched.features.contains(.vehicleLocation)))
        #expect(!(relaunched.features.contains(.vehicleWeather)))
        #expect(!(relaunched.features.contains(.ownerGreeting)))
    }

    @Test
    func safeStreamingMigrationEnablesTheNewDefaultOnce() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set([AppFeature.vehicleIdentity.rawValue],
                     forKey: "enabled_features_v2")

        #expect(preferences.features.contains(.realTimeUpdates))
        var explicitlyDisabled = preferences.features
        explicitlyDisabled.set(.realTimeUpdates, enabled: false)
        preferences.features = explicitlyDisabled

        #expect(!(PreferencesStore(defaults: defaults).features.contains(.realTimeUpdates)))
    }

    @Test
    func safeBulkEnableNeverIncludesRemoteCommands() {
        #expect(!(AppFeature.safeBulkEnableCases.isEmpty))
        #expect(Set(AppFeature.safeBulkEnableCases).isDisjoint(with: AppFeature.remoteFeatures))
        #expect(AppFeature.remoteFeatures.allSatisfy { $0.isRemoteControl })
    }

    @Test
    func settingsSearchFindsWholeSectionsAndCanReturnNoResults() {
        #expect(SettingsSection.accounts.matches("VIN"))
        #expect(SettingsSection.privacyData.matches("backup"))
        #expect(SettingsSection.notifications.matches("quiet hours"))
        #expect(!(SettingsSection.appearance.matches("battery alert")))
    }

    @Test
    func panelPresetCanPersistentlyDisableCustomGeometry() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.customPanelSizeEnabled = true

        preferences.panelSize = .large
        preferences.customPanelSizeEnabled = false

        let relaunched = PreferencesStore(defaults: defaults)
        #expect(relaunched.panelSize == .large)
        #expect(!(relaunched.customPanelSizeEnabled))
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
        let archive = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(archive["polestar_email"] == nil)
        #expect(archive["polestar_vin"] == nil)
        #expect(archive["session_token"] == nil)
        #expect(archive["garage_vehicle_order_v1"] == nil)
        #expect(archive["panel_size"] as? String == PanelSize.large.rawValue)
        #expect(!((archive["enabled_features_v2"] as? [String] ?? []).contains(AppFeature.remoteLocks.rawValue)))

        preferences.panelSize = .compact
        preferences.notifySounds = true
        try preferences.importSettingsPropertyList(data)
        #expect(preferences.panelSize == .large)
        #expect(!(preferences.notifySounds))
        #expect(!(preferences.features.contains(.remoteLocks)))
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
    func anyNotificationAlertEnabledTracksEveryIndividualToggle() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Every alert type ships default-on.
        #expect(preferences.anyNotificationAlertEnabled)

        let flags: [ReferenceWritableKeyPath<PreferencesStore, Bool>] = [
            \.notifyChargingStarted, \.notifyChargingComplete, \.notifyChargingProblem,
            \.notifyLowBattery, \.notifySoftwareUpdates, \.notifyVehicleWarnings,
            \.notifyRainWithWindowsOpen, \.notifyEveningUnlocked, \.notifyOpeningsLeftOpen,
            \.notifyServiceDue, \.notifyStaleTelemetry, \.notifySlowCharging,
            \.notifyPlugInReminder, \.notifyChargerConnection, \.notifyClimateChanges,
        ]

        for flag in flags { preferences[keyPath: flag] = false }
        #expect(!(preferences.anyNotificationAlertEnabled), "with every alert type off, nothing is enabled")

        // Each flag on its own must be enough — catches a flag dropped from the OR chain.
        for flag in flags {
            for other in flags { preferences[keyPath: other] = false }
            preferences[keyPath: flag] = true
            #expect(preferences.anyNotificationAlertEnabled)
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
        #expect(preferences.historySampleRetentionDays == 90)
        #expect(preferences.openingsAlertDelayMinutes == 60)
        #expect(preferences.plugInReminderThreshold == 10)
        #expect(preferences.eveningUnlockedStartHour == 18)
    }

    @Test
    func updateCheckIntervalDefaultsToDailyAndSurvivesRelaunch() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(preferences.updateCheckInterval == .daily)

        preferences.updateCheckInterval = .everyHour
        let relaunched = PreferencesStore(defaults: defaults)
        #expect(relaunched.updateCheckInterval == .everyHour)
    }

    @Test
    func unknownStoredUpdateCheckIntervalFallsBackToDaily() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        // A removed case or hand-edited defaults must not break the updater.
        defaults.set("three_times_a_day", forKey: "update_check_interval")
        #expect(preferences.updateCheckInterval == .daily)
    }

    @Test
    func settingsArchiveCarriesTheUpdateCheckInterval() throws {
        let (preferences, defaults, suite) = try store()
        defer { defaults.removePersistentDomain(forName: suite) }
        preferences.updateCheckInterval = .weekly

        let data = try preferences.exportSettingsPropertyList()
        let archive = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(archive["update_check_interval"] as? String == UpdateCheckInterval.weekly.rawValue)

        preferences.updateCheckInterval = .daily
        try preferences.importSettingsPropertyList(data)
        #expect(preferences.updateCheckInterval == .weekly)
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
        #expect(Notifier.plugInReminderCondition(state, threshold: 40))
        #expect(!(Notifier.plugInReminderCondition(state, threshold: 30)))
    }
}
