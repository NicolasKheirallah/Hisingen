import Foundation
import Testing
@testable import Hisingen

/// S31: every Volvo GET resource the adapter calls has one sanitized fixture that proves the
/// adapter's own decoding path, the live sweep iterates the same case list, and the endpoints
/// deliberately left without a file fixture are named with their reason.
@Suite("Volvo endpoint fixtures")
struct VolvoEndpointFixtureTests {
    @Test func everyCalledEndpointHasASanitizedFixture() throws {
        for endpoint in VolvoFixturedEndpoint.allCases {
            let url = try #require(
                Bundle.module.url(forResource: endpoint.fixtureName, withExtension: "json"),
                "\(endpoint.title) has no fixture (\(endpoint.fixtureName).json)")
            #expect(!url.path.isEmpty)
            let decoded = try endpoint.decodeFixture()
            #expect(decoded == endpoint.expectedProjection,
                    "\(endpoint.title) fixture no longer maps to the adapter model: \(decoded)")
        }
    }

    @Test func fixtureNamesAreUniqueAndMatchTheEndpointSet() {
        let names = VolvoFixturedEndpoint.allCases.map(\.fixtureName)
        #expect(names.count == VolvoFixturedEndpoint.allCases.count)
        #expect(Set(names).count == names.count)
        #expect(VolvoFixturedEndpoint.allCases.count == 19)
    }

    @Test func fixturePathsCoverTheConnectedVehicleAndEnergyFamilies() {
        let paths = Set(VolvoFixturedEndpoint.allCases.map(\.pathTemplate))
        #expect(paths.count == VolvoFixturedEndpoint.allCases.count)
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/engine"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/brakes"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/tyres"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/warnings"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/engine-status"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/command-accessibility"))
        #expect(paths.contains("/connected-vehicle/v2/vehicles/{vin}/commands"))
        #expect(paths.contains("/energy/v2/vehicles/{vin}/voc-subscription"))
    }

    @Test func fixturesCarryNoCredentialOrTokenShapedValues() throws {
        for endpoint in VolvoFixturedEndpoint.allCases {
            let text = String(decoding: try endpoint.fixtureData(), as: UTF8.self)
            #expect(!text.contains("Bearer "), "\(endpoint.fixtureName) contains a bearer token")
            #expect(!text.contains("access_token"), "\(endpoint.fixtureName) contains an access token")
            #expect(!text.contains("refresh_token"), "\(endpoint.fixtureName) contains a refresh token")
            #expect(!text.contains("eyJ"), "\(endpoint.fixtureName) contains a JWT-shaped value")
            #expect(!text.contains("vcc-api-key"), "\(endpoint.fixtureName) contains an API key header")
        }
    }

    @Test func everyFixturelessCalledEndpointHasAStatedReason() {
        // The exemption list is intentionally short and explicit: a new called endpoint that
        // needs a payload fixture cannot silently join a growing "no fixture" list.
        #expect(VolvoFixtureExemptions.entries.count == 4)
        for entry in VolvoFixtureExemptions.entries {
            #expect(!entry.reason.isEmpty)
            #expect(entry.reason.count > 30, "\(entry.endpoint) needs a concrete reason, not a label")
        }
    }
}
