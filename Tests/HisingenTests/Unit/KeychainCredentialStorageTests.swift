import Foundation
import Testing
@testable import Hisingen


@MainActor
struct KeychainCredentialStorageTests {

    @Test
    func testEmailMigratesFromUserDefaultsIntoKeychain() throws {
        let service = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: service)
        let suiteName = "HisingenTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            try? keychain.deleteEmail()
            defaults.removePersistentDomain(forName: suiteName)
        }

        defaults.set("driver@example.invalid", forKey: "polestar_email")
        let preferences = PreferencesStore(defaults: defaults, keychain: keychain)

        #expect(preferences.email == "driver@example.invalid")
        #expect(defaults.string(forKey: "polestar_email") == nil)
        try #expect(keychain.readEmail() == "driver@example.invalid")

        preferences.email = "updated@example.invalid"
        try #expect(keychain.readEmail() == "updated@example.invalid")
        #expect(defaults.string(forKey: "polestar_email") == nil)

        preferences.email = ""
        try #expect(keychain.readEmail() == nil)
    }

    @Test
    func testInvalidateMemoryCacheDropsEntriesForAllKeyFamilies() throws {
        let service = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let reader = KeychainStore(service: service)
        let externalWriter = KeychainStore(service: service)
        defer {
            try? externalWriter.deleteSessionToken()
            try? externalWriter.deleteVolvoSessionToken()
            try? externalWriter.deleteHomeAssistantToken()
            try? externalWriter.deleteElectricityMapsKey()
            try? externalWriter.deleteChargerCredentials(vendor: "nexblue")
        }

        // Prime negative cache entries in `reader` across standard and integration key families.
        #expect(try reader.readSessionToken() == nil)
        #expect(try reader.readVolvoSessionToken() == nil)
        #expect(try reader.readHomeAssistantToken() == nil)
        #expect(try reader.readElectricityMapsKey() == nil)
        #expect(try reader.readChargerCredentials(vendor: "nexblue") == nil)

        try externalWriter.saveSessionToken("polestar-r1")
        try externalWriter.saveVolvoSessionToken("volvo-r1")
        try externalWriter.saveHomeAssistantToken("ha-token")
        try externalWriter.saveElectricityMapsKey("emaps-key")
        try externalWriter.saveChargerCredentials("charger-secret", vendor: "nexblue")

        // Dropping cached entries must not leave `.value(nil)` tombstones blocking reads.
        reader.invalidateMemoryCache()

        #expect(try reader.readSessionToken() == "polestar-r1")
        #expect(try reader.readVolvoSessionToken() == "volvo-r1")
        #expect(try reader.readHomeAssistantToken() == "ha-token")
        #expect(try reader.readElectricityMapsKey() == "emaps-key")
        #expect(try reader.readChargerCredentials(vendor: "nexblue") == "charger-secret")
    }

    @Test
    func testReadFreshObservesCrossInstanceTokenRotationWithoutFullInvalidation() throws {
        let service = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let appStore = KeychainStore(service: service)
        let cliStore = KeychainStore(service: service)
        defer {
            try? cliStore.deleteSessionToken()
            try? cliStore.deleteVolvoSessionToken()
        }

        try appStore.saveSessionToken("r1")
        try appStore.saveVolvoSessionToken("vr1")
        #expect(try appStore.readSessionToken() == "r1")
        #expect(try appStore.readVolvoSessionToken() == "vr1")

        try cliStore.saveSessionToken("r2")
        try cliStore.saveVolvoSessionToken("vr2")

        #expect(try appStore.readFreshSessionToken() == "r2")
        #expect(try appStore.readFreshVolvoSessionToken() == "vr2")
    }
}
