import Foundation
import Testing
@testable import Hisingen

struct RequestConstructionTests {

    @Test
    @MainActor
    func volvoScopeTiersNarrowFromFullToCore() async throws {
        let suite = "HisingenVolvoScopeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        preferences.volvoRestrictedScopesEnabled = true
        let api = VolvoAPI(
            keychain: KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)"),
            preferences: preferences)
        await api.configure(clientID: "test-client", clientSecret: "test-secret",
                            vccApiKey: "test-key")

        func scopes(_ tier: VolvoAPI.ScopeTier) async throws -> Set<String> {
            let url = try await api.beginSignIn(tier: tier)
            let raw = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "scope" })?.value)
            return Set(raw.split(separator: " ").map(String.init))
        }

        let full = try await scopes(.full)
        #expect(full.contains("conve:lock"))
        #expect(full.contains("location:read"))
        #expect(full.contains("conve:climatization_start_stop"))

        let standard = try await scopes(.standard)
        #expect(!standard.contains("conve:lock"))
        #expect(!standard.contains("location:read"))
        #expect(standard.contains("conve:climatization_start_stop"))
        #expect(standard.contains("conve:battery_charge_level"))

        let core = try await scopes(.core)
        #expect(!core.contains("conve:lock"))
        #expect(!core.contains("conve:climatization_start_stop"))
        #expect(!core.contains("conve:commands"))
        #expect(core.contains("conve:battery_charge_level"))
        #expect(core.contains("conve:vehicle_relation"))
        #expect(core.contains("openid"))

        // A forged callback (wrong host) is rejected outright — and must leave the pending
        // sign-in retryable rather than consuming it (API-11).
        let forged = try #require(URL(string: "https://example.invalid/callback?error=invalid_scope"))
        do {
            try await api.completeSignIn(callbackURL: forged, preferredVIN: nil)
            Issue.record("A forged callback must be rejected")
        } catch VolvoError.authenticationRequired(.callbackRejected) {
            // expected
        }

        // `invalid_scope` on a genuine callback stays distinguishable so the coordinator
        // can cascade to the next scope tier.
        let retryURL = try await api.beginSignIn(tier: .core)
        let state = try #require(OAuthCallback.queryValue("state", from: retryURL))
        var callbackComponents = URLComponents(url: await api.redirectURI, resolvingAgainstBaseURL: false)!
        callbackComponents.queryItems = [
            URLQueryItem(name: "error", value: "invalid_scope"),
            URLQueryItem(name: "state", value: state)
        ]
        do {
            try await api.completeSignIn(callbackURL: try #require(callbackComponents.url), preferredVIN: nil)
            Issue.record("invalid_scope must reach the caller as permissionDenied(\"invalid_scope\")")
        } catch VolvoError.permissionDenied(let operation) {
            #expect(operation == "invalid_scope")
        }
    }
}
