import Foundation

/// The two URIs Volvo may hand a sign-in result back on, and the one rule that decides whether an
/// inbound URL is one of them.
///
/// `hostedRedirectURL` is what the authorization request registers as `redirect_uri`, because Volvo
/// requires HTTPS. The page at that address finishes by navigating to `appCallbackURL`, so the code
/// Hisingen exchanges arrives on the app's own scheme. Both the browser presenter and the token
/// exchange ask this type, so a crafted redirect (another host, a deeper path, another scheme, an
/// explicit port, embedded credentials) is refused before its `code` reaches the token endpoint.
enum VolvoCallback {
    /// Registered under `CFBundleURLTypes`; what macOS hands back to the app.
    static let appCallbackURL = URL(string: "hisingen://oauth/volvo/callback")!
    /// The HTTPS page Volvo redirects to; it forwards the query to `appCallbackURL`.
    static let hostedRedirectURL = URL(string: "https://nicolaskheirallah.github.io/Hisingen/oauth-callback.html")!

    /// The registered URI `url` is, or nil when it is not one of them. Callers compare against the
    /// returned URL rather than re-deriving the expectation, so both gates stay one rule.
    static func registration(for url: URL) -> URL? {
        let expected = expectedRegistration(for: url)
        return refusal(for: url, expected: expected) == nil ? expected : nil
    }

    /// Why `url` is not a registered callback. Nil means it is one.
    static func refusal(for url: URL) -> Refusal? {
        refusal(for: url, expected: expectedRegistration(for: url))
    }

    /// A rejected callback, described well enough to diagnose a misrouted redirect and never enough
    /// to leak one: the query is where the authorization code travels, so no part of it is a
    /// component here, and every received value is bounded before it reaches a log line.
    enum Refusal: Equatable {
        case scheme(received: String?, expected: String?)
        case host(received: String?, expected: String?)
        case path(received: String, expected: String)
        case port(received: Int?, expected: Int?)
        case embeddedCredentials

        /// The sentence both gates log. Composed here so a refused callback reads the same way
        /// whichever gate caught it, and so a test pins the text instead of a copy of it.
        var logMessage: String {
            "Refused Volvo sign-in callback: \(reason)"
        }

        private var reason: String {
            switch self {
            case let .scheme(received, expected):
                return "scheme \(Self.quoted(received)) instead of \(Self.quoted(expected))"
            case let .host(received, expected):
                return "host \(Self.quoted(received)) instead of \(Self.quoted(expected))"
            case let .path(received, expected):
                return "path \(Self.quoted(received)) instead of \(Self.quoted(expected))"
            case let .port(received, expected):
                return "port \(received.map { String($0) } ?? "none") instead of \(expected.map { String($0) } ?? "none")"
            case .embeddedCredentials:
                return "embedded credentials"
            }
        }

        /// Keeps a crafted URL from filling the log: the component is truncated, not summarized.
        private static func quoted(_ value: String?) -> String {
            guard let value else { return "none" }
            let limit = 80
            let bounded = value.count > limit ? String(value.prefix(limit)) + "…" : value
            return "\"\(bounded)\""
        }
    }

    /// The registration an inbound URL is aiming at. The scheme names it; a URL carrying neither
    /// registered scheme is reported against the app callback, which is the one the app serves.
    private static func expectedRegistration(for url: URL) -> URL {
        url.scheme?.lowercased() == hostedRedirectURL.scheme ? hostedRedirectURL : appCallbackURL
    }

    private static func refusal(for url: URL, expected: URL) -> Refusal? {
        if url.user != nil || url.password != nil { return .embeddedCredentials }
        if url.scheme != expected.scheme { return .scheme(received: url.scheme, expected: expected.scheme) }
        if url.host != expected.host { return .host(received: url.host, expected: expected.host) }
        if url.port != expected.port { return .port(received: url.port, expected: expected.port) }
        // Same path tolerance the shared OAuth consumer applies, so the presenter and the exchange
        // cannot disagree about a trailing slash.
        let received = OAuthCallback.normalizedPath(url)
        let wanted = OAuthCallback.normalizedPath(expected)
        guard received == wanted else { return .path(received: received, expected: wanted) }
        return nil
    }
}
