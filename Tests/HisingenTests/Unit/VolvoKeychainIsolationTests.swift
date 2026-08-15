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

        try XCTAssertEqual(store.readSessionToken(), "polestar-refresh-token-value")
        try XCTAssertEqual(store.readVolvoSessionToken(), "volvo-refresh-token-value")

        try store.deleteSessionToken()

        try XCTAssertNil(store.readSessionToken())
        try XCTAssertEqual(store.readVolvoSessionToken(), "volvo-refresh-token-value")
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

        try XCTAssertEqual(store.readVolvoClientSecret(), "secret-value")
        try XCTAssertEqual(store.readVolvoApiKey(), "api-key-value")

        try store.deleteVolvoClientSecret()
        try XCTAssertNil(store.readVolvoClientSecret())
        try XCTAssertEqual(store.readVolvoApiKey(), "api-key-value")
    }
}

