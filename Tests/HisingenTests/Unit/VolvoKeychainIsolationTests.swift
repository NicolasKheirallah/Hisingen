import Foundation
import Testing
@testable import Hisingen


struct VolvoKeychainIsolationTests {

    @Test
    func testPolestarAndVolvoSessionTokensDoNotCollide() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deleteSessionToken()
            try? store.deleteVolvoSessionToken()
        }
        try store.saveSessionToken("polestar-refresh-token-value")
        try store.saveVolvoSessionToken("volvo-refresh-token-value")

        try #expect(store.readSessionToken() == "polestar-refresh-token-value")
        try #expect(store.readVolvoSessionToken() == "volvo-refresh-token-value")

        try store.deleteSessionToken()

        try #expect(store.readSessionToken() == nil)
        try #expect(store.readVolvoSessionToken() == "volvo-refresh-token-value")
    }

    @Test
    func testVolvoClientSecretAndApiKeyAreIndependentlyStored() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deleteVolvoClientSecret()
            try? store.deleteVolvoApiKey()
        }
        try store.saveVolvoClientSecret("secret-value")
        try store.saveVolvoApiKey("api-key-value")

        try #expect(store.readVolvoClientSecret() == "secret-value")
        try #expect(store.readVolvoApiKey() == "api-key-value")

        try store.deleteVolvoClientSecret()
        try #expect(store.readVolvoClientSecret() == nil)
        try #expect(store.readVolvoApiKey() == "api-key-value")
    }
}


