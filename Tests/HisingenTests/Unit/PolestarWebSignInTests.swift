import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PolestarWebSignInTests {

    private func makeAPI() async -> PolestarAPI {
        let keyService = "io.kheirallah.hisingen.tests.\(UUID().uuidString)"
        let keychain = KeychainStore(service: keyService)
        let api = PolestarAPI(keychain: keychain)
        await api.seedWebTestEndpoint()
        return api
    }

    @Test
    func testBeginWebAuthorizationURLConstruction() async throws {
        let api = await makeAPI()

        let (authURL, redirectURI) = try await api.beginWebAuthorization()
        #expect(redirectURI.absoluteString == "https://www.polestar.com/sign-in-callback")

        guard let components = URLComponents(url: authURL, resolvingAgainstBaseURL: false) else {
            Issue.record("Invalid auth URL components")
            return
        }
        let items = components.queryItems ?? []
        #expect(items.first(where: { $0.name == "client_id" })?.value == "l3oopkc_10")
        #expect(items.first(where: { $0.name == "redirect_uri" })?.value == "https://www.polestar.com/sign-in-callback")
        #expect(items.first(where: { $0.name == "response_type" })?.value == "code")
        #expect(items.first(where: { $0.name == "response_mode" })?.value == "query")
        #expect(items.first(where: { $0.name == "code_challenge_method" })?.value == "S256")
        #expect(items.first(where: { $0.name == "state" })?.value != nil)
        #expect(items.first(where: { $0.name == "code_challenge" })?.value != nil)
    }

    @Test
    func testCompleteWebAuthorizationRejectsStateMismatch() async throws {
        let api = await makeAPI()
        _ = try await api.beginWebAuthorization()

        let forgedCallback = URL(string: "https://www.polestar.com/sign-in-callback?code=testcode&state=wrongstate")!
        do {
            try await api.completeWebAuthorization(callbackURL: forgedCallback)
            Issue.record("Should have thrown authenticationRequired")
        } catch let error as PolestarError {
            guard case .authenticationRequired(let reason) = error else {
                Issue.record("Unexpected PolestarError case: \(error)")
                return
            }
            #expect(reason == .callbackRejected)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test
    func testCompleteWebAuthorizationHandlesErrorParam() async throws {
        let api = await makeAPI()
        let (authorizeURL, _) = try await api.beginWebAuthorization()
        let state = try #require(PolestarAPI.queryValue("state", from: authorizeURL))

        let errorCallback = URL(string: "https://www.polestar.com/sign-in-callback?error=access_denied&state=\(state)")!
        do {
            try await api.completeWebAuthorization(callbackURL: errorCallback)
            Issue.record("Should have thrown permissionDenied")
        } catch let error as PolestarError {
            guard case .permissionDenied(let op) = error else {
                Issue.record("Unexpected error: \(error)")
                return
            }
            #expect(op == "access_denied")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
}

private extension PolestarAPI {
    func seedWebTestEndpoint() {
        authorizationEndpoint = URL(string: "https://polestarid.eu.polestar.com/as/authorization.oauth2")!
    }
}
