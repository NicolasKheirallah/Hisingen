import Foundation

/// Shared OAuth redirect-callback helpers. One normalizer/extractor for both provider stacks,
/// so a URI one flow accepts and the other rejects cannot diverge silently.
enum OAuthCallback {
    /// The app-scheme callback carries no path, which URL reports as "" here and "/" in some
    /// redirect forms — treat those as equal; longer paths compare without a trailing slash.
    static func normalizedPath(_ url: URL) -> String {
        let path = url.path
        guard path.count > 1 else { return path == "/" ? "" : path }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    static func queryValue(_ name: String, from url: URL?) -> String? {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        return components.queryItems?.first(where: { $0.name == name })?.value
    }
}

/// Owns the security-sensitive lifetime of one PKCE authorization attempt. Verifier, state,
/// timeout, and invalidation generation move together so callers cannot clear only part of a
/// flow or accept a callback left behind by an earlier attempt. The rejection and OAuth-error
/// mappings are supplied per provider so both stacks share the validation sequence.
struct AuthorizationFlow<Failure: Error> {
    struct Completion {
        let verifier: String
        let code: String
        let generation: UInt
    }

    private struct Pending {
        let verifier: String
        let state: String
        let startedAt: Date
    }

    let rejected: Failure
    /// Maps the callback's `error`/`error_description` pair onto the provider's error type.
    let oauthError: @Sendable (_ code: String, _ description: String?) -> Failure

    /// Explicit designated init: the synthesized memberwise init is private (private
    /// `pending`), so provider stacks in other files could not construct with arguments.
    init(rejected: Failure, oauthError: @escaping @Sendable (String, String?) -> Failure) {
        self.rejected = rejected
        self.oauthError = oauthError
    }

    private(set) var generation: UInt = 0
    private(set) var isInProgress = false
    private var pending: Pending?

    var pendingState: String? { pending?.state }

    @discardableResult
    mutating func begin(verifier: String, state: String, now: Date = Date()) -> UInt {
        invalidate()
        isInProgress = true
        pending = Pending(verifier: verifier, state: state, startedAt: now)
        return generation
    }

    mutating func consume(
        callbackURL: URL,
        redirectURL: URL,
        now: Date = Date(),
        maximumAge: TimeInterval? = nil
    ) throws -> Completion {
        guard let pending else { throw rejected }
        if let maximumAge, now.timeIntervalSince(pending.startedAt) > maximumAge {
            invalidate()
            throw rejected
        }
        guard callbackURL.scheme == redirectURL.scheme,
              callbackURL.host == redirectURL.host,
              OAuthCallback.normalizedPath(callbackURL) == OAuthCallback.normalizedPath(redirectURL),
              OAuthCallback.queryValue("state", from: callbackURL) == pending.state else {
            throw rejected
        }
        self.pending = nil
        if let error = OAuthCallback.queryValue("error", from: callbackURL) {
            isInProgress = false
            throw oauthError(
                error, OAuthCallback.queryValue("error_description", from: callbackURL))
        }
        guard let code = OAuthCallback.queryValue("code", from: callbackURL) else {
            isInProgress = false
            throw rejected
        }
        return Completion(verifier: pending.verifier, code: code, generation: generation)
    }

    mutating func finish(generation: UInt) {
        guard self.generation == generation else { return }
        isInProgress = false
    }

    mutating func invalidate() {
        generation &+= 1
        isInProgress = false
        pending = nil
    }

    func isCurrent(_ generation: UInt) -> Bool { self.generation == generation }
}

typealias PolestarAuthorizationFlow = AuthorizationFlow<PolestarError>

extension AuthorizationFlow where Failure == PolestarError {
    init() {
        self.init(
            rejected: .authenticationRequired(.callbackRejected),
            oauthError: { code, _ in PolestarError.permissionDenied(operation: code) }
        )
    }
}
