import Foundation

/// One reading of a failed HTTP response, in a provider-neutral vocabulary. Each provider
/// maps this onto its own error enum in one small function; the status ladder and the
/// Retry-After header belong to HTTP, not to a provider, and used to be maintained as
/// three drifting copies (the portal's copy silently lost HTTP-date Retry-After support).
enum ServiceResponseFailure: Sendable, Equatable {
    /// 401, or 403 when a provider treats it as an identity failure.
    case authenticationRequired
    /// 403 on a resource the account can read but not control.
    case permissionDenied(operation: String)
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int)
    /// Anything else in the 4xx range. Body codes are provider vocabulary and stay with
    /// the provider's own decoding.
    case client(statusCode: Int, bodyCode: String?, message: String?)
}

enum ServiceResponseClassifier {
    /// The status ladder every provider shares: 2xx passes, 401 (or 403-as-auth) is
    /// authentication, 403 is permission, 429 is rate limiting, 5xx is server, the rest
    /// are client errors.
    static func failure(
        status: Int,
        retryAfter: TimeInterval? = nil,
        forbiddenIsAuthentication: Bool = false,
        operation: String = "request"
    ) -> ServiceResponseFailure? {
        if (200..<300).contains(status) { return nil }
        if status == 401 || (status == 403 && forbiddenIsAuthentication) {
            return .authenticationRequired
        }
        if status == 403 { return .permissionDenied(operation: operation) }
        if status == 429 { return .rateLimited(retryAfter: retryAfter) }
        if (500..<600).contains(status) { return .server(statusCode: status) }
        return .client(statusCode: status, bodyCode: nil, message: nil)
    }

    /// `Retry-After` in delta-seconds or HTTP-date form. HTTP-date support was lost once
    /// by a per-provider copy; the parsing lives here so it cannot drift again.
    static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) }
    }
}
