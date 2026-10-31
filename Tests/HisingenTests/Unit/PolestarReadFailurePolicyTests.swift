import Foundation
import Testing
@testable import Hisingen

struct PolestarReadFailurePolicyTests {
    @Test func requestFailuresAbortInsteadOfProducingAnEmptySuccess() {
        let failures: [any Error] = [
            CancellationError(), URLError(.cancelled), URLError(.notConnectedToInternet),
            PolestarError.network(URLError(.timedOut)), PolestarError.authenticationRequired(.expiredSession),
            PolestarError.rateLimited(retryAfter: 60), PolestarError.server(statusCode: 503),
            PolestarError.responseTooLarge(operation: "battery")
        ]
        for failure in failures { #expect(PolestarReadFailurePolicy.abortRefresh(failure)) }
    }

    @Test func serviceGapsRemainScopedToTheirReading() {
        let gaps: [any Error] = [
            PolestarError.grpcUnimplemented(service: "trips"),
            PolestarError.permissionDenied(operation: "health"),
            PolestarError.grpcUnavailable(service: "climate"),
            PolestarError.decoding(operation: "software")
        ]
        for gap in gaps { #expect(!PolestarReadFailurePolicy.abortRefresh(gap)) }
    }
}
