import Foundation

/// Owns the security-sensitive lifetime of one PKCE authorization attempt. Verifier, state,
/// timeout, and invalidation generation move together so callers cannot clear only part of a
/// flow or accept a callback left behind by an earlier attempt.
struct PolestarAuthorizationFlow {
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
              Self.normalizedPath(callbackURL) == Self.normalizedPath(redirectURL),
              Self.queryValue("state", from: callbackURL) == pending.state else {
            throw rejected
        }
        self.pending = nil
        if let error = Self.queryValue("error", from: callbackURL) {
            isInProgress = false
            throw PolestarError.permissionDenied(operation: error)
        }
        guard let code = Self.queryValue("code", from: callbackURL) else {
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

    private var rejected: PolestarError { .authenticationRequired(.callbackRejected) }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    private static func queryValue(_ name: String, from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first(where: { $0.name == name })?.value
    }
}
