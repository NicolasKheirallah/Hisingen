import Testing
@testable import Hisingen

struct SettingsIntegrationTests {
    @Test
    func everySettingsDestinationHasSearchMetadata() {
        #expect(SettingsSection.allCases.count == 9)
        for section in SettingsSection.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbol.isEmpty)
        }
        #expect(SettingsSection.updates.matches("release"))
        #expect(SettingsSection.privacyData.matches("retention"))
    }

    @Test
    func capabilityFiltersPartitionEverySupportState() {
        let supports: [VehicleCapabilitySupport] = [.supported, .vehicleManaged, .unavailable, .backendDependent]
        for support in supports {
            #expect(CapabilityFilter.all.matches(support))
            #expect(CapabilityFilter.allCases.filter { $0 != .all && $0.matches(support) }.count == 1)
        }
    }

    @Test
    func remoteControlsRemainOutsideSafeBulkActions() {
        #expect(Set(AppFeature.safeBulkEnableCases).isDisjoint(with: AppFeature.remoteFeatures))
        #expect(AppFeature.userSelectableCases.contains(.vehicleErrors))
        #expect(AppFeature.userSelectableCases.contains(.realTimeUpdates))
    }
}
