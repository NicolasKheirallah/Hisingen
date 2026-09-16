import Foundation
import OSLog

/// Owns one provider's refresh-token lifetime: the renewal decision (including whether a refused
/// token still needs replacing at all), the single-flight grant, rotate-on-use persistence, and the
/// classification of a permanently dead grant.
///
/// The provider keeps its wire transport and its error vocabulary. It hands the lifecycle two
/// closures: `grant`, which performs the refresh request and returns the decoded tokens, and
/// `isDeadGrant`, which recognises its own identity provider's answer that the presented grant
/// can never work again. Those are the only genuinely per-provider parts.
///
/// Both stacks wrote this sequence twice, in two error vocabularies, and neither copy was
/// reachable through its interface – each provider's constructor built its own transport, so the
/// only way a test could reach the lifecycle was to mutate actor internals. Constructing it with
/// the closures and an injectable clock makes the whole sequence testable with a stub grant.
///
/// The invariants below live here rather than being remembered per provider:
///
/// - **Single-flight.** Parallel callers share one grant. Under a rotate-on-use identity
///   provider, two grants presenting the same stored token mean one replay fails and both persist
///   different rotated tokens, orphaning one of them.
/// - **A refused token is replaced once.** A caller that was refused presents the token it used;
///   if the session no longer holds that token, some other caller's grant already replaced it, and
///   asking again would spend a second grant on a session that is already fresh.
/// - **Rotate-on-use, in memory first.** A rotated refresh token replaces the previous one
///   immediately; persistence is best-effort. The server has already invalidated the previous
///   token, so a storage failure must not leave the app replaying a credential the identity
///   provider just killed. A failed persist costs a restart, not the session.
/// - **A dead grant is terminal.** A grant the identity provider rejects as permanently dead is
///   reported to the caller so it can drop the stored copy instead of replaying it on every
///   request, because each replay is a failed login and counts toward the account-lockout budget.
///
/// ## Synchronization
///
/// This is a reference type shared by the concurrent callers of one provider, and its `refresh`
/// runs on the caller's executor rather than on the provider actor – a nonisolated async function
/// is hopped off the actor that calls it. The decision and the in-flight registration therefore
/// have to be atomic against each other, or two callers both find no grant under way and start
/// one each. The state is a plain `NSLock`, which keeps the interface synchronous for the
/// provider's accessors; `@unchecked Sendable` rests on that lock.
final class TokenLifecycle: @unchecked Sendable {
    /// One successful refresh-token grant.
    struct Grant: Sendable, Equatable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: TimeInterval
    }

    /// Why a caller is asking for a grant.
    enum Reason: Sendable {
        /// The session's token is inside its renewal window, or there is none yet.
        case renewalWindow
        /// A caller presented `rejectedToken` and the server refused it, so waiting for the
        /// renewal window is not an option. `nil` means the caller cannot say which token was
        /// refused – Volvo's request path does not carry it back – and the provider's own
        /// `minimumRegrantInterval` is what bounds a burst.
        case serverRefused(rejectedToken: String?)
    }

    /// What a refresh call did.
    enum Outcome: Sendable, Equatable {
        /// A grant was applied, whether this call started it or awaited one already in flight.
        case refreshed
        /// The access token is still inside its renewal window, a grant landed just now, or the
        /// refused token has already been replaced.
        case notNeeded
        /// The identity provider permanently rejected the grant. Nothing was applied; the caller
        /// should drop the stored credential and report its own authentication failure.
        case deadGrant
    }

    /// When to refresh, per provider.
    struct Policy: Sendable {
        /// How long before expiry to renew. Both stacks scale this to the advertised lifetime: a
        /// flat five-minute margin can never be met by a five-minute token, which would force a
        /// grant (and account verification) on every request.
        var renewalMargin: @Sendable (TimeInterval) -> TimeInterval
        /// Swallow refresh requests arriving this soon after a successful grant, so a burst of
        /// near-simultaneous callers does not each earn a fresh grant. Zero disables it.
        var minimumRegrantInterval: TimeInterval

        init(
            renewalMargin: @escaping @Sendable (TimeInterval) -> TimeInterval,
            minimumRegrantInterval: TimeInterval = 0
        ) {
            self.renewalMargin = renewalMargin
            self.minimumRegrantInterval = minimumRegrantInterval
        }
    }

    let policy: Policy
    /// Used in log messages so an export can tell the two stacks apart without guessing.
    let providerName: String
    /// Persists a rotated refresh token. A throw is logged, never fatal.
    let persist: @Sendable (String) throws -> Void
    /// Recognises the identity provider's permanently-dead-grant answer in the provider's own
    /// error vocabulary.
    let isDeadGrant: @Sendable (Error) -> Bool

    private let lock = NSLock()
    private var storedAccessToken: String?
    private var storedRefreshToken: String?
    private var storedTokenExpiry: Date?
    private var storedTokenLifetime: TimeInterval = 0
    private var lastGrantAt: Date?
    private var inFlight: (id: UUID, task: Task<Grant, Error>)?
    private let logger: Logger

    init(
        policy: Policy,
        providerName: String,
        logger: Logger = AppLog.logger("token-lifecycle"),
        persist: @escaping @Sendable (String) throws -> Void,
        isDeadGrant: @escaping @Sendable (Error) -> Bool
    ) {
        self.policy = policy
        self.providerName = providerName
        self.logger = logger
        self.persist = persist
        self.isDeadGrant = isDeadGrant
    }

    // MARK: - Session state

    var accessToken: String? {
        get { locked { storedAccessToken } }
        set { locked { storedAccessToken = newValue } }
    }

    var refreshToken: String? {
        get { locked { storedRefreshToken } }
        set { locked { storedRefreshToken = newValue } }
    }

    var tokenExpiry: Date? {
        get { locked { storedTokenExpiry } }
        set { locked { storedTokenExpiry = newValue } }
    }

    var tokenLifetime: TimeInterval {
        get { locked { storedTokenLifetime } }
        set { locked { storedTokenLifetime = newValue } }
    }

    // MARK: - Refresh

    /// Renews the access token according to `reason`.
    ///
    /// `epochIsCurrent` is the caller's generation guard, consulted after every suspension so a
    /// grant that lands after the session was reset cannot be applied to the new one.
    func refresh(
        _ reason: Reason,
        now: Date = Date(),
        epochIsCurrent: @escaping @Sendable () async -> Bool,
        grant: @escaping @Sendable () async throws -> Grant
    ) async throws -> Outcome {
        enum Decision {
            case skip
            case join((id: UUID, task: Task<Grant, Error>))
            case start((id: UUID, task: Task<Grant, Error>))
        }

        // The decision and the registration are one atomic step: two callers that both looked
        // first would start two grants, and under rotate-on-use that orphans one rotated token.
        let decision: Decision = locked {
            if !needsGrant(reason, now: now) { return .skip }
            if let inFlight { return .join(inFlight) }
            let id = UUID()
            let entry = (id: id, task: Task { try await grant() })
            inFlight = entry
            return .start(entry)
        }

        switch decision {
        case .skip:
            return .notNeeded
        case .join(let entry):
            return try await apply(entry, now: now, epochIsCurrent: epochIsCurrent)
        case .start(let entry):
            defer {
                locked {
                    if inFlight?.id == entry.id { inFlight = nil }
                }
            }
            return try await apply(entry, now: now, epochIsCurrent: epochIsCurrent)
        }
    }

    /// Whether `reason` still calls for a grant, given the session as it stands.
    private func needsGrant(_ reason: Reason, now: Date) -> Bool {
        switch reason {
        case .renewalWindow:
            if let expiry = storedTokenExpiry, storedAccessToken != nil,
               expiry.timeIntervalSince(now) >= policy.renewalMargin(storedTokenLifetime) {
                return false
            }
        case .serverRefused(let rejectedToken):
            // The caller's token is no longer the session's, so somebody's grant already replaced
            // it — or a dead grant cleared it. Asking again would spend a second grant on a
            // session that is already dealt with.
            if let rejectedToken, storedAccessToken != rejectedToken {
                return false
            }
        }
        if policy.minimumRegrantInterval > 0, let lastGrantAt, storedAccessToken != nil,
           now.timeIntervalSince(lastGrantAt) < policy.minimumRegrantInterval {
            return false
        }
        return true
    }

    private func apply(
        _ entry: (id: UUID, task: Task<Grant, Error>),
        now: Date,
        epochIsCurrent: @Sendable () async -> Bool
    ) async throws -> Outcome {
        do {
            let grant = try await entry.task.value
            guard await epochIsCurrent() else { throw CancellationError() }
            try adopt(grant, now: now)
            return .refreshed
        } catch {
            // The epoch check comes first even for a failure: a rejected grant from a session the
            // app has already left must not clear the credential of the one that replaced it.
            guard await epochIsCurrent() else { throw CancellationError() }
            if isDeadGrant(error) { return .deadGrant }
            throw error
        }
    }

    /// Adopts a grant obtained outside `refresh`: the authorization-code exchange, where the
    /// identity provider has just issued a brand-new session instead of rotating an existing one.
    /// The same in-memory-first, best-effort-persist rules apply.
    func adopt(_ grant: Grant, now: Date = Date()) throws {
        let (renewableToken, previousRefreshToken) = locked { () -> (String?, String?) in
            let previous = storedRefreshToken
            let renewable = grant.refreshToken ?? storedRefreshToken
            storedAccessToken = grant.accessToken
            storedRefreshToken = renewable
            storedTokenLifetime = grant.expiresIn
            storedTokenExpiry = now.addingTimeInterval(grant.expiresIn)
            lastGrantAt = now
            return (renewable, previous)
        }
        guard let renewableToken, renewableToken != previousRefreshToken else { return }
        do {
            try persist(renewableToken)
        } catch {
            logger.error(
                "\(self.providerName, privacy: .public) rotated refresh token could not be persisted; the session will not survive a restart: \(String(describing: error), privacy: .public)"
            )
        }
    }

    // MARK: - Reset

    /// Clears the in-memory session and cancels any in-flight grant. `keepingRefreshToken` is for
    /// the re-sign-in path, which discards the access token but is about to reuse the credential.
    /// Persisted tokens are deliberately untouched: only `signOut` and a dead grant delete those.
    func reset(keepingRefreshToken: Bool = false) {
        cancelInFlightGrant()
        locked {
            storedAccessToken = nil
            storedTokenExpiry = nil
            storedTokenLifetime = 0
            lastGrantAt = nil
            if !keepingRefreshToken { storedRefreshToken = nil }
        }
    }

    /// Cancels an in-flight grant without touching the session. A new authorization is about to
    /// replace it, and its rotated token must not land afterwards.
    func cancelInFlightGrant() {
        let task = locked { () -> Task<Grant, Error>? in
            let task = inFlight?.task
            inFlight = nil
            return task
        }
        task?.cancel()
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
