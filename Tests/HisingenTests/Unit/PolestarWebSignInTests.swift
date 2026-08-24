import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PolestarWebSignInTests {

    private func makeAPI() -> PolestarAPI {
        let keyService = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keyService)
        return PolestarAPI(keychain: keychain)
    }

    @Test
    func testBeginWebAuthorizationURLConstruction() async throws {
        let api = makeAPI()

        let (authURL, redirectURI) = try await api.beginWebAuthorization()
        XCTAssertEqual(redirectURI.absoluteString, "https://www.polestar.com/sign-in-callback")

        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false) else {
            return XCTFail("Invalid auth URL components")
        }
        let items = components.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "client_id" })?.value, "l3oopkc_10")
        XCTAssertEqual(items.first(where: { $0.name == "redirect_uri" })?.value, "https://www.polestar.com/sign-in-callback")
        XCTAssertEqual(items.first(where: { $0.name == "response_type" })?.value, "code")
        XCTAssertEqual(items.first(where: { $0.name == "response_mode" })?.value, "query")
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertNotNil(items.first(where: { $0.name == "state" })?.value)
        XCTAssertNotNil(items.first(where: { $0.name == "code_challenge" })?.value)
    }

    @Test
    func testCompleteWebAuthorizationRejectsStateMismatch() async throws {
        let api = makeAPI()
        _ = try await api.beginWebAuthorization()

        let forgedCallback = URL(string: "https://www.polestar.com/sign-in-callback?code=testcode&state=wrongstate")!
        do {
            try await api.completeWebAuthorization(callbackURL: forgedCallback)
            XCTFail("Should have thrown authenticationRequired")
        } catch let error as PolestarError {
            guard case .authenticationRequired(let reason) = error else {
                return XCTFail("Unexpected PolestarError case: \(error)")
            }
            XCTAssertEqual(reason, .callbackRejected)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @Test
    func testCompleteWebAuthorizationHandlesErrorParam() async throws {
        let api = makeAPI()
        _ = try await api.beginWebAuthorization()

        let errorCallback = URL(string: "https://www.polestar.com/sign-in-callback?error=access_denied")!
        do {
            try await api.completeWebAuthorization(callbackURL: errorCallback)
            XCTFail("Should have thrown permissionDenied")
        } catch let error as PolestarError {
            guard case .permissionDenied(let op) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(op, "access_denied")
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}
