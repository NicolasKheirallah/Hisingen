import Foundation

struct PolestarOIDCConfiguration: Sendable {
    let tokenEndpoint: URL
    let authorizationEndpoint: URL
    let userinfoEndpoint: URL?
    let revocationEndpoint: URL?
}

struct PolestarOIDCClient: Sendable {
    let providerURL: URL
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore

    private struct Discovery: Decodable {
        let issuer: String
        let tokenEndpoint: String
        let authorizationEndpoint: String
        let userinfoEndpoint: String?
        let revocationEndpoint: String?
        enum CodingKeys: String, CodingKey {
            case issuer
            case tokenEndpoint = "token_endpoint"
            case authorizationEndpoint = "authorization_endpoint"
            case userinfoEndpoint = "userinfo_endpoint"
            case revocationEndpoint = "revocation_endpoint"
        }
    }

    func discover() async throws -> PolestarOIDCConfiguration {
        let url = providerURL.appendingPathComponent(".well-known/openid-configuration")
        let (data, response) = try await HTTPExchange.data(for: URLRequest(url: url), using: session,
            limit: 2_000_000, operation: "HTTP request", provider: .polestar, diagnosticLog: diagnosticLog)
        if let failure = PolestarError.httpFailure(statusCode: response.statusCode,
            retryAfter: ServiceResponseClassifier.retryAfter(from: response), operation: "request") { throw failure }
        let discovery: Discovery
        do { discovery = try JSONDecoder().decode(Discovery.self, from: data) }
        catch {
            PolestarDecoding.log(error, operation: "OIDC discovery", logger: AppLog.logger("polestar-api"))
            throw PolestarError.incompatibleAPI(operation: "OIDC discovery")
        }
        guard let issuer = URL(string: discovery.issuer), issuer.scheme == providerURL.scheme,
              issuer.host == providerURL.host,
              issuer.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                  providerURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              let token = Self.validURL(discovery.tokenEndpoint),
              let authorization = Self.validURL(discovery.authorizationEndpoint) else {
            throw PolestarError.incompatibleAPI(operation: "OIDC discovery")
        }
        return PolestarOIDCConfiguration(tokenEndpoint: token, authorizationEndpoint: authorization,
            userinfoEndpoint: discovery.userinfoEndpoint.flatMap(Self.validURL),
            revocationEndpoint: discovery.revocationEndpoint.flatMap(Self.validURL))
    }

    private static func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme == "https", let host = url.host,
              host == "polestar.com" || host.hasSuffix(".polestar.com") else { return nil }
        return url
    }
}
