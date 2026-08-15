import Foundation
import Testing
@testable import Hisingen


struct KeychainDraftTests {

    @Test
    func testPasswordDraftNeverCollidesWithCommittedPassword() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deletePassword()
            try? store.deletePasswordDraft()
        }
        try store.savePassword("committed-password")
        try store.savePasswordDraft("draft-in-progress")

        try XCTAssertEqual(store.readPassword(), "committed-password")
        try XCTAssertEqual(store.readPasswordDraft(), "draft-in-progress")


        try store.deletePasswordDraft()
        try XCTAssertNil(store.readPasswordDraft())
        try XCTAssertEqual(store.readPassword(), "committed-password")
    }

    @Test
    func testVolvoDraftsNeverCollideWithCommittedCredentials() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        defer {
            try? store.deleteVolvoClientSecret()
            try? store.deleteVolvoApiKey()
            try? store.deleteVolvoClientSecretDraft()
            try? store.deleteVolvoApiKeyDraft()
        }
        try store.saveVolvoClientSecret("committed-secret")
        try store.saveVolvoApiKey("committed-api-key")
        try store.saveVolvoClientSecretDraft("draft-secret")
        try store.saveVolvoApiKeyDraft("draft-api-key")

        try XCTAssertEqual(store.readVolvoClientSecret(), "committed-secret")
        try XCTAssertEqual(store.readVolvoApiKey(), "committed-api-key")
        try XCTAssertEqual(store.readVolvoClientSecretDraft(), "draft-secret")
        try XCTAssertEqual(store.readVolvoApiKeyDraft(), "draft-api-key")

        try store.deleteVolvoClientSecretDraft()
        try store.deleteVolvoApiKeyDraft()
        try XCTAssertNil(store.readVolvoClientSecretDraft())
        try XCTAssertNil(store.readVolvoApiKeyDraft())


        try XCTAssertEqual(store.readVolvoClientSecret(), "committed-secret")
        try XCTAssertEqual(store.readVolvoApiKey(), "committed-api-key")
    }

    @Test
    func testEmptyDraftReadsAsNilNotEmptyString() throws {
        let store = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")


        try XCTAssertNil(store.readPasswordDraft())
        try XCTAssertNil(store.readVolvoClientSecretDraft())
        try XCTAssertNil(store.readVolvoApiKeyDraft())
    }
}

