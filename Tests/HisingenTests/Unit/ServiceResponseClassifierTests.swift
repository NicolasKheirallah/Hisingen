import Foundation
import Testing
@testable import Hisingen

/// Retry-After parsing lives in one classifier for all three providers. The portal's
/// seconds-only copy once silently dropped HTTP-date support, so both header forms are
/// pinned here against a known positive control each.
@Suite("RetryAfter")
struct ServiceResponseClassifierRetryAfterTests {

    private func response(headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://example.test")!, statusCode: 429,
                        httpVersion: nil, headerFields: headers)!
    }

    @Test func deltaSecondsFormIsReadDirectly() {
        #expect(ServiceResponseClassifier.retryAfter(from: response(headers: ["Retry-After": "120"])) == 120)
        #expect(ServiceResponseClassifier.retryAfter(from: response(headers: ["Retry-After": "0"])) == 0)
    }

    @Test func httpDateFormBecomesANonNegativeDelay() {
        // A date far in the past clamps to zero rather than producing a negative delay.
        let past = ServiceResponseClassifier.retryAfter(
            from: response(headers: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"]))
        #expect(past == 0)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let future = Date().addingTimeInterval(3600)
        let parsed = ServiceResponseClassifier.retryAfter(
            from: response(headers: ["Retry-After": formatter.string(from: future)]))
        #expect(parsed != nil)
        #expect(parsed! > 3000 && parsed! <= 3600)
    }

    @Test func missingOrMalformedHeaderYieldsNil() {
        #expect(ServiceResponseClassifier.retryAfter(from: response(headers: [:])) == nil)
        #expect(ServiceResponseClassifier.retryAfter(from: response(headers: ["Retry-After": "soon"])) == nil)
    }

    @Test func theSharedLadderClassifiesEveryFamily() {
        #expect(ServiceResponseClassifier.failure(status: 200) == nil)
        #expect(ServiceResponseClassifier.failure(status: 204) == nil)
        #expect(ServiceResponseClassifier.failure(status: 401) == .authenticationRequired)
        #expect(ServiceResponseClassifier.failure(status: 403) == .permissionDenied(operation: "request"))
        #expect(ServiceResponseClassifier.failure(status: 403, forbiddenIsAuthentication: true)
                == .authenticationRequired)
        #expect(ServiceResponseClassifier.failure(status: 429, retryAfter: 9)
                == .rateLimited(retryAfter: 9))
        #expect(ServiceResponseClassifier.failure(status: 503) == .server(statusCode: 503))
        #expect(ServiceResponseClassifier.failure(status: 418)
                == .client(statusCode: 418, bodyCode: nil, message: nil))
    }
}
