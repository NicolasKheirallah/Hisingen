import Foundation
import OSLog

struct PolestarGraphQLClient: Sendable {
    let endpoint: URL
    let session: URLSession
    let diagnosticLog: APIDiagnosticLogStore
    let appVersion: String
    let refresh: @Sendable (String) async throws -> String
    private var logger: Logger { AppLog.logger("polestar-api") }

    func query<Payload: Decodable, Variables: Encodable>(
        _ query: String, variables: Variables?, token: String, operation: String,
        isolation: isolated (any Actor)? = #isolation
    ) async throws -> GraphQLResponse<Payload> {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Hisingen/\(appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(GraphQLRequestBody(query: query, variables: variables))

        // One forced refresh is allowed: a rejected token on the first attempt is replaced and
        // the request is sent again; a rejection on the second attempt is final.
        let operationID = UUID()
        var bearerToken = token
        for attempt in 0...1 {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await HTTPExchange.data(
                for: request, using: session, limit: 2_000_000, operation: operation,
                provider: .polestar, diagnosticLog: diagnosticLog,
                logicalOperationID: operationID, attempt: attempt + 1)
            if response.statusCode == 401 || response.statusCode == 403 {
                if attempt == 0 {
                    bearerToken = try await refresh(bearerToken)
                    continue
                }
                logger.error("""
                    Polestar \(operation, privacy: .public) rejected after token refresh \
                    (HTTP \(response.statusCode, privacy: .public))
                    """)
                if response.statusCode == 401 {
                    throw PolestarError.authenticationRequired(.expiredSession)
                }
                throw PolestarError.permissionDenied(operation: operation)
            }
            if let failure = PolestarError.httpFailure(statusCode: response.statusCode, retryAfter: ServiceResponseClassifier.retryAfter(from: response), operation: operation) { throw failure }
            let decoded = try PolestarDecoding.decode(GraphQLResponse<Payload>.self, from: data,
                operation: operation, logger: logger)
            if decoded.data == nil, let errors = decoded.errors,
               PolestarAPI.containsAuthenticationError(errors) {
                if attempt == 0 {
                    bearerToken = try await refresh(bearerToken)
                    continue
                }
                // Server-supplied GraphQL messages are scrubbed before public logging –
                // they have been known to echo account details on auth failures.
                let authSummary = DiagnosticRedaction.redact(PolestarAPI.errorSummary(errors))
                logger.error("""
                    Polestar \(operation, privacy: .public) returned an authentication error after \
                    token refresh: \(authSummary, privacy: .public)
                    """)
                throw PolestarError.authenticationRequired(.expiredSession)
            }
            if decoded.data == nil, let errors = decoded.errors, !errors.isEmpty {
                let summary = DiagnosticRedaction.redact(PolestarAPI.errorSummary(errors))
                logger.error("""
                    Polestar \(operation, privacy: .public) failed: \
                    \(summary, privacy: .public)
                    """)
                throw PolestarError.graphQL(PolestarAPI.mapErrors(errors), hasPartialData: false)
            }
            return decoded
        }
        // Both attempts either return or throw above; the compiler cannot see that.
        throw PolestarError.authenticationRequired(.expiredSession)
    }
}
