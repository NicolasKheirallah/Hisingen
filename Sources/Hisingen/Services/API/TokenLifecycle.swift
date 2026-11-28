import CryptoKit
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

    /// Coordinates access tokens and cross-process refresh locking through a shared persistent store
    /// (typically `KeychainStore`) so `Hisingen.app` and `Hisingen cli` never race on a single-use
    /// refresh token.
    struct SharedSessionStore: Sendable {
        let readSession: @Sendable () throws -> StoredOAuthSession?
        let readRefreshToken: @Sendable () throws -> String?
        let writeSession: @Sendable (StoredOAuthSession) throws -> Void
        let withLock: @Sendable (@Sendable () async throws -> RefreshStepResult) async throws -> RefreshStepResult
    }

    enum SharedCredentialError: Error, Equatable {
        case replaced
    }

    struct ExplicitRestore: Sendable {
        let previousDurableToken: String?
    }

    enum RefreshStepResult: Sendable {
        case minted(Grant, baseGeneration: UInt64)
        case alreadyAdopted
    }

    let policy: Policy
    /// Used in log messages so an export can tell the two stacks apart without guessing.
    let providerName: String
    /// Persists a rotated refresh token. A throw is logged, never fatal.
    let persist: @Sendable (String) throws -> Void
    /// Optional cross-process session store. Nil keeps lifecycle purely in-memory + `persist`.
    private let sharedStore: SharedSessionStore?
    /// Recognises the identity provider's permanently-dead-grant answer in the provider's own
    /// error vocabulary.
    let isDeadGrant: @Sendable (Error) -> Bool

    private let lock = NSLock()
    private var storedAccessToken: String?
    private var storedRefreshToken: String?
    private var storedTokenExpiry: Date?
    private var storedTokenLifetime: TimeInterval = 0
    private var storedGeneration: UInt64 = 0
    private var storedPreviousRefreshTokenHashes: [Data] = []
    private var requiresDurableRefresh = false
    private var grantStorage: (id: UUID, expectedToken: String?)?
    private static let refreshTokenHistoryLimit = 8
    private var lastGrantAt: Date?
    /// The most recent grants that were applied, newest last. A caller that joined a grant and
    /// resumes late must still find it applied even when newer grants landed in between; one slot
    /// answered "not current" for it and turned a good grant into a cancellation.
    private var appliedFlights: [UUID] = []
    private static let appliedFlightMemory = 8
    private var inFlight: (id: UUID, task: Task<RefreshStepResult, Error>)?
    /// Grants in flight when a reset kept the refresh token. They run on to completion and are
    /// applied even by a caller whose epoch has since moved on: the identity provider rotates the
    /// token the moment it answers, so cancelling the request after it was sent can leave the
    /// only valid token in a response nobody reads.
    private var carriedFlights: Set<UUID> = []
    private let logger: Logger

    init(
        policy: Policy,
        providerName: String,
        logger: Logger = AppLog.logger("token-lifecycle"),
        persist: @escaping @Sendable (String) throws -> Void,
        sharedStore: SharedSessionStore? = nil,
        isDeadGrant: @escaping @Sendable (Error) -> Bool
    ) {
        self.policy = policy
        self.providerName = providerName
        self.logger = logger
        self.persist = persist
        self.sharedStore = sharedStore
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

    /// Reuses a shared access token when its refresh token belongs to the current grant.
    @discardableResult
    func hydrateFromSharedStoreIfValid(expectedRefreshToken: String, now: Date = Date()) -> Bool {
        guard let sharedStore,
              let session = try? sharedStore.readSession(),
              let durableRefresh = try? sharedStore.readRefreshToken(),
              durableRefresh == session.refreshToken,
              Self.continuesCredential(session, from: expectedRefreshToken),
              !session.accessToken.isEmpty,
              session.expiresAt.timeIntervalSince(now) >= policy.renewalMargin(session.lifetime) else {
            return false
        }
        return locked {
            storedAccessToken = session.accessToken
            if !session.refreshToken.isEmpty {
                storedRefreshToken = session.refreshToken
            }
            storedTokenLifetime = session.lifetime
            storedTokenExpiry = session.expiresAt
            storedGeneration = max(storedGeneration, session.generation)
            storedPreviousRefreshTokenHashes = session.previousRefreshTokenHashes ?? []
            requiresDurableRefresh = true
            return true
        }
    }

    /// `epochIsCurrent` prevents a grant from being applied to a new session after a local reset.
    func refresh(
        _ reason: Reason,
        now: Date = Date(),
        explicitRestore: ExplicitRestore? = nil,
        epochIsCurrent: @escaping @Sendable () async -> Bool,
        grant: @escaping @Sendable () async throws -> Grant
    ) async throws -> Outcome {
        enum Decision {
            case skip
            case join((id: UUID, task: Task<RefreshStepResult, Error>))
            case start((id: UUID, task: Task<RefreshStepResult, Error>))
        }

        // The decision and the registration are one atomic step: two callers that both looked
        // first would start two grants, and under rotate-on-use that orphans one rotated token.
        let decision: Decision = locked {
            if !needsGrant(reason, now: now) { return .skip }
            if let inFlight { return .join(inFlight) }
            let id = UUID()
            let knownGeneration = storedGeneration
            let knownRefresh = storedRefreshToken
            let knownRefreshHistory = storedPreviousRefreshTokenHashes
            let needsDurableRefresh = requiresDurableRefresh
            let entry = (id: id, task: Task {
                try await self.executeGrant(
                    entryID: id,
                    reason: reason,
                    now: now,
                    knownGeneration: knownGeneration,
                    knownRefresh: knownRefresh,
                    knownRefreshHistory: knownRefreshHistory,
                    needsDurableRefresh: needsDurableRefresh,
                    explicitRestore: explicitRestore,
                    epochIsCurrent: epochIsCurrent,
                    grant: grant
                )
            })
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
                    // A carried grant outlives the call that started it: a later caller adopts it.
                    if inFlight?.id == entry.id, !carriedFlights.contains(entry.id) { inFlight = nil }
                }
            }
            return try await apply(entry, now: now, epochIsCurrent: epochIsCurrent)
        }
    }

    private func executeGrant(
        entryID: UUID,
        reason: Reason,
        now: Date,
        knownGeneration: UInt64,
        knownRefresh: String?,
        knownRefreshHistory: [Data],
        needsDurableRefresh: Bool,
        explicitRestore: ExplicitRestore?,
        epochIsCurrent: @escaping @Sendable () async -> Bool,
        grant: @escaping @Sendable () async throws -> Grant
    ) async throws -> RefreshStepResult {
        guard let sharedStore else {
            return .minted(try await grant(), baseGeneration: knownGeneration)
        }
        return try await sharedStore.withLock {
            let freshRefresh = try sharedStore.readRefreshToken()
            let freshSession = try? sharedStore.readSession()
            let matchingSession = freshSession.flatMap { $0.refreshToken == freshRefresh ? $0 : nil }
            let explicitBaselineUnchanged = explicitRestore.map { $0.previousDurableToken == freshRefresh } == true
            if freshRefresh == nil, !explicitBaselineUnchanged,
               needsDurableRefresh || explicitRestore != nil {
                throw SharedCredentialError.replaced
            }
            let replacementRefresh: String?
            if let freshRefresh, freshRefresh != knownRefresh, !explicitBaselineUnchanged {
                if let knownRefresh, let matchingSession, Self.continuesCredential(matchingSession, from: knownRefresh) {
                    replacementRefresh = freshRefresh
                } else if knownRefreshHistory.contains(Self.refreshTokenHash(freshRefresh)) {
                    // A previous persistence failure can leave this same credential behind in Keychain.
                    replacementRefresh = nil
                } else {
                    throw SharedCredentialError.replaced
                }
            } else {
                replacementRefresh = nil
            }
            if let matchingSession, let knownRefresh, Self.continuesCredential(matchingSession, from: knownRefresh),
               Self.isSharedSessionValid(
                   matchingSession,
                   reason: reason,
                   knownGeneration: knownGeneration,
                   now: now,
                   policy: self.policy
               ) {
                let current = await epochIsCurrent()
                guard try sharedStore.readRefreshToken() == freshRefresh,
                      self.adoptSharedIfCurrent(matchingSession, entryID: entryID, now: now, epochIsCurrent: current) else {
                    throw CancellationError()
                }
                return .alreadyAdopted
            }
            let ready = self.locked {
                guard self.inFlight?.id == entryID, self.storedRefreshToken == knownRefresh else { return false }
                if let replacementRefresh {
                    self.storedRefreshToken = replacementRefresh
                }
                if let matchingSession, matchingSession.refreshToken == self.storedRefreshToken {
                    self.storedPreviousRefreshTokenHashes = matchingSession.previousRefreshTokenHashes ?? []
                }
                if freshRefresh != nil, !explicitBaselineUnchanged { self.requiresDurableRefresh = true }
                self.grantStorage = (entryID, freshRefresh)
                return true
            }
            guard ready else { throw CancellationError() }
            defer {
                self.locked {
                    if self.grantStorage?.id == entryID { self.grantStorage = nil }
                }
            }
            let baseGeneration = max(knownGeneration, matchingSession?.generation ?? 0)
            let obtained: Grant
            do {
                obtained = try await grant()
            } catch {
                if self.isDeadGrant(error) { try self.checkGrantStorage(entryID: entryID, sharedStore: sharedStore) }
                throw error
            }
            // Persist the rotated refresh token and SharedOAuthSession before releasing the
            // cross-process lock so another process waking on the lock sees the updated grant.
            let current = await epochIsCurrent()
            try self.checkGrantStorage(entryID: entryID, sharedStore: sharedStore)
            guard self.adoptIfCurrent(
                obtained,
                entryID: entryID,
                now: now,
                baseGeneration: baseGeneration,
                epochIsCurrent: current
            ) else {
                throw CancellationError()
            }
            return .alreadyAdopted
        }
    }

    private func checkGrantStorage(entryID: UUID, sharedStore: SharedSessionStore) throws {
        guard let storage = locked({ grantStorage }), storage.id == entryID else { throw CancellationError() }
        guard try sharedStore.readRefreshToken() == storage.expectedToken else {
            throw SharedCredentialError.replaced
        }
    }

    func markRefreshCredentialDurable() {
        locked { requiresDurableRefresh = true }
    }

    /// Retains a rotated credential before secondary verification, which may fail independently.
    func persistEarlyRotation(_ rotated: String, replacing previous: String,
                              persist save: (String) throws -> Void) throws {
        try locked {
            guard storedRefreshToken == previous else { throw CancellationError() }
            if let sharedStore {
                guard let grantStorage, grantStorage.id == inFlight?.id else { throw CancellationError() }
                guard try sharedStore.readRefreshToken() == grantStorage.expectedToken else {
                    throw SharedCredentialError.replaced
                }
                if rotated != previous { rememberRefreshToken(previous) }
            }
            storedRefreshToken = rotated
            try save(rotated)
            if sharedStore != nil {
                grantStorage?.expectedToken = rotated
                requiresDurableRefresh = true
            }
        }
    }

    private func rememberRefreshToken(_ token: String) {
        let hash = Self.refreshTokenHash(token)
        storedPreviousRefreshTokenHashes.removeAll { $0 == hash }
        storedPreviousRefreshTokenHashes.insert(hash, at: 0)
        if storedPreviousRefreshTokenHashes.count > Self.refreshTokenHistoryLimit {
            storedPreviousRefreshTokenHashes.removeLast()
        }
    }

    // The Keychain slots belong to the selected account. A different token needs proof of rotation.
    private static func continuesCredential(_ session: StoredOAuthSession, from previous: String) -> Bool {
        session.refreshToken == previous
            || session.previousRefreshTokenHashes?.contains(refreshTokenHash(previous)) == true
    }

    private static func refreshTokenHash(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private static func isSharedSessionValid(
        _ session: StoredOAuthSession,
        reason: Reason,
        knownGeneration: UInt64,
        now: Date,
        policy: Policy
    ) -> Bool {
        guard !session.accessToken.isEmpty else { return false }
        guard session.expiresAt.timeIntervalSince(now) >= policy.renewalMargin(session.lifetime) else {
            return false
        }
        switch reason {
        case .renewalWindow:
            return true
        case .serverRefused(let rejectedToken):
            if let rejectedToken {
                return session.accessToken != rejectedToken
            }
            return session.generation > knownGeneration
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
        _ entry: (id: UUID, task: Task<RefreshStepResult, Error>),
        now: Date,
        epochIsCurrent: @Sendable () async -> Bool
    ) async throws -> Outcome {
        let result = await entry.task.result
        switch result {
        case .success(.minted(let grant, let baseGeneration)):
            let current = await epochIsCurrent()
            guard adoptIfCurrent(grant, entryID: entry.id, now: now, baseGeneration: baseGeneration, epochIsCurrent: current) else {
                throw CancellationError()
            }
            return .refreshed
        case .success(.alreadyAdopted):
            let current = await epochIsCurrent()
            let accepted = locked { current || appliedFlights.contains(entry.id) }
            guard accepted else { throw CancellationError() }
            return .refreshed
        case .failure(let error):
            locked {
                carriedFlights.remove(entry.id)
                if inFlight?.id == entry.id { inFlight = nil }
            }
            // A rejection from an older epoch must never clear its replacement credential.
            guard await epochIsCurrent() else { throw CancellationError() }
            if isDeadGrant(error) { return .deadGrant }
            throw error
        }
    }

    private func adoptSharedIfCurrent(_ session: StoredOAuthSession, entryID: UUID, now: Date, epochIsCurrent: Bool) -> Bool {
        locked {
            guard epochIsCurrent || carriedFlights.contains(entryID) else { return false }
            if appliedFlights.contains(entryID) { return true }
            guard inFlight?.id == entryID else { return false }
            inFlight = nil
            carriedFlights.remove(entryID)
            appliedFlights.append(entryID)
            if appliedFlights.count > Self.appliedFlightMemory { appliedFlights.removeFirst() }
            storedAccessToken = session.accessToken
            if !session.refreshToken.isEmpty {
                storedRefreshToken = session.refreshToken
            }
            storedTokenLifetime = session.lifetime
            storedTokenExpiry = session.expiresAt
            storedGeneration = max(storedGeneration, session.generation)
            storedPreviousRefreshTokenHashes = session.previousRefreshTokenHashes ?? []
            requiresDurableRefresh = true
            lastGrantAt = now
            return true
        }
    }

    private func adoptIfCurrent(_ grant: Grant, entryID: UUID, now: Date, baseGeneration: UInt64, epochIsCurrent: Bool) -> Bool {
        locked {
            // The restore may have carried this grant while the caller checked its epoch.
            guard epochIsCurrent || carriedFlights.contains(entryID) else { return false }
            if appliedFlights.contains(entryID) { return true }
            guard inFlight?.id == entryID else { return false }
            inFlight = nil
            carriedFlights.remove(entryID)
            appliedFlights.append(entryID)
            if appliedFlights.count > Self.appliedFlightMemory { appliedFlights.removeFirst() }
            let previous = storedRefreshToken
            let renewable = grant.refreshToken ?? previous
            storedAccessToken = grant.accessToken
            storedRefreshToken = renewable
            storedTokenLifetime = grant.expiresIn
            let expiry = now.addingTimeInterval(grant.expiresIn)
            storedTokenExpiry = expiry
            let nextGeneration = max(storedGeneration, baseGeneration) &+ 1
            storedGeneration = nextGeneration
            lastGrantAt = now
            if let renewable, renewable != previous {
                if sharedStore != nil, let previous { rememberRefreshToken(previous) }
                do {
                    try persist(renewable)
                    if sharedStore != nil { requiresDurableRefresh = true }
                } catch {
                    logger.error("\(self.providerName, privacy: .public) refresh token persistence failed")
                }
            }
            if let sharedStore, !grant.accessToken.isEmpty {
                let shared = StoredOAuthSession(
                    accessToken: grant.accessToken,
                    refreshToken: renewable ?? "",
                    expiresAt: expiry,
                    lifetime: grant.expiresIn,
                    generation: nextGeneration,
                    previousRefreshTokenHashes: storedPreviousRefreshTokenHashes
                )
                do { try sharedStore.writeSession(shared) }
                catch { logger.error("\(self.providerName, privacy: .public) shared OAuth session persistence failed") }
            }
            return true
        }
    }

    /// Adopts a grant obtained outside `refresh`: the authorization-code exchange, where the
    /// identity provider has just issued a brand-new session instead of rotating an existing one.
    /// The same in-memory-first, best-effort-persist rules apply.
    func adopt(_ grant: Grant, now: Date = Date()) throws {
        let externalGeneration = (try? sharedStore?.readSession()?.generation) ?? 0
        let expiry = now.addingTimeInterval(grant.expiresIn)
        let (renewableToken, previousRefreshToken, nextGeneration) = locked { () -> (String?, String?, UInt64) in
            let previous = storedRefreshToken
            let renewable = grant.refreshToken ?? storedRefreshToken
            storedAccessToken = grant.accessToken
            storedRefreshToken = renewable
            storedTokenLifetime = grant.expiresIn
            storedTokenExpiry = expiry
            let generation = max(storedGeneration, externalGeneration) &+ 1
            storedGeneration = generation
            storedPreviousRefreshTokenHashes = []
            requiresDurableRefresh = false
            lastGrantAt = now
            return (renewable, previous, generation)
        }
        if let renewableToken, renewableToken != previousRefreshToken {
            do {
                try persist(renewableToken)
            } catch {
                logger.error(
                    "\(self.providerName, privacy: .public) rotated refresh token could not be persisted; the session will not survive a restart: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
        if let sharedStore, !grant.accessToken.isEmpty {
            if let renewableToken, (try? sharedStore.readRefreshToken()) == renewableToken {
                locked {
                    if storedRefreshToken == renewableToken { requiresDurableRefresh = true }
                }
            }
            let shared = StoredOAuthSession(
                accessToken: grant.accessToken,
                refreshToken: renewableToken ?? "",
                expiresAt: expiry,
                lifetime: grant.expiresIn,
                generation: nextGeneration
            )
            do { try sharedStore.writeSession(shared) }
            catch {
                logger.error(
                    "\(self.providerName, privacy: .public) shared OAuth session persistence failed: \(DiagnosticRedaction.redact(String(describing: error)), privacy: .public)"
                )
            }
        }
    }

    // MARK: - Reset

    /// Install the incoming credential before restore suspends. A grant can complete during
    /// discovery, so credential matching and initialization share the grant's lock.
    func prepareForRestore(refreshToken: String) {
        let task = locked {
            let sameCredential = storedRefreshToken == refreshToken
            let task = resetLocked(keepingRefreshToken: sameCredential, keepingAccessToken: sameCredential)
            storedRefreshToken = refreshToken
            return task
        }
        task?.cancel()
    }

    /// Clears the in-memory session and cancels any in-flight grant. `keepingRefreshToken` is for
    /// the re-sign-in path, which discards the access token but is about to reuse the credential;
    /// a grant in flight then is not cancelled but carried, and applied when it lands.
    /// `keepingAccessToken` keeps the live access token, expiry and lifetime as well, for a
    /// restore that re-establishes a session this process already holds: the credential has not
    /// changed, and a redundant `.serverRefused(nil)` grant rotates the refresh token for nothing.
    /// Persisted tokens are deliberately untouched: only `signOut` and a dead grant delete those.
    func reset(keepingRefreshToken: Bool = false, keepingAccessToken: Bool = false) {
        let task = locked {
            resetLocked(keepingRefreshToken: keepingRefreshToken, keepingAccessToken: keepingAccessToken)
        }
        task?.cancel()
    }

    private func resetLocked(keepingRefreshToken: Bool, keepingAccessToken: Bool) -> Task<RefreshStepResult, Error>? {
        var cancelled: Task<RefreshStepResult, Error>?
        if keepingRefreshToken, let flight = inFlight {
            // The identity provider may already have rotated the credential this reset keeps.
            carriedFlights.insert(flight.id)
        } else {
            cancelled = inFlight?.task
            inFlight = nil
            carriedFlights = []
            appliedFlights = []
        }
        lastGrantAt = nil
        if !keepingAccessToken {
            storedAccessToken = nil
            storedTokenExpiry = nil
            storedTokenLifetime = 0
        }
        if !keepingRefreshToken {
            storedRefreshToken = nil
            storedGeneration = 0
            storedPreviousRefreshTokenHashes = []
            requiresDurableRefresh = false
        }
        return cancelled
    }

    /// Cancels an in-flight grant without touching the session. A new authorization is about to
    /// replace it, and its rotated token must not land afterwards.
    func cancelInFlightGrant() {
        let task = locked { () -> Task<RefreshStepResult, Error>? in
            let task = inFlight?.task
            inFlight = nil
            carriedFlights = []
            appliedFlights = []
            return task
        }
        task?.cancel()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
