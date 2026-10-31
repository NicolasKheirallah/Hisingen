/**
 * @file PolestarDataPortalAPI.swift
 * @description Official Polestar Developer Portal (EU Data Act) M2M & Telemetry API client
 * @author Nicolas Kheirallah <nicolas.kheirallah@gmail.com>
 * @version 1.0.0
 */

import AppKit
import Foundation
import OSLog

/// Get/set pair over the quota counter's backing store, so a test can isolate the
/// process-global defaults from concurrent suite traffic.
struct QuotaStateStore: Sendable {
    let get: @Sendable () -> (count: Int, dateString: String)
    let set: @Sendable (Int, String) -> Void
}

actor PolestarDataPortalAPI {
    nonisolated let brand: VehicleBrand = .polestar
    let logger = AppLog.logger("polestar-dataportal-api")

    private let baseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/data-portal/m2m/")!

    var accountID: String?
    var clientID: String?
    var clientSecret: String?

    var session: URLSession
    let keychain: KeychainStore
    let imageCache: CarImageCache
    let preferences: PreferencesStore
    let diagnosticLog: APIDiagnosticLogStore
    private let now: @Sendable () -> Date
    private let timeZone: TimeZone
    private let credentialReader: @Sendable () throws -> (id: String?, secret: String?, account: String?)

    // MARK: - Daily Quota Tracking (10,000 calls/day limit)
    nonisolated static let dailyCallLimit = 10_000

    nonisolated static var dailyCallCount: Int { dailyCallCount(on: Date()) }

    private nonisolated static func dailyCallCount(on now: Date) -> Int {
        let (count, date) = readQuotaState()
        return isSameCalendarDay(date, now) ? min(max(0, count), dailyCallLimit) : 0
    }

    nonisolated var dailyCallCount: Int {
        Self.dailyCallCount(on: now())
    }

    private static func quotaDateFormatter() -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    private static func isSameCalendarDay(_ d1: String, _ d2: Date) -> Bool {
        d1 == quotaDateFormatter().string(from: d2)
    }

    /// The quota counter's backing store. Injectable so a test can own its state: the
    /// process-global defaults are shared by every portal call in every suite, and a
    /// concurrent test's recorded call would otherwise land inside another test's assert.
    /// Guards the store slot and the counter's read-modify-write. Recursive because
    /// `readQuotaState` reads the slot while a write already holds the lock.
    private nonisolated static let quotaLock = NSRecursiveLock()
    nonisolated(unsafe) private static var quotaStore: QuotaStateStore? = nil

    nonisolated static var quotaStateStore: QuotaStateStore? {
        get { quotaLock.withLock { quotaStore } }
        set { quotaLock.withLock { quotaStore = newValue } }
    }

    private nonisolated static func readQuotaState() -> (count: Int, dateString: String) {
        if let store = Self.quotaStateStore { return store.get() }
        let count = UserDefaults.standard.integer(forKey: "polestar_dataportal_daily_calls")
        let dateStr = UserDefaults.standard.string(forKey: "polestar_dataportal_daily_date") ?? ""
        return (count, dateStr)
    }

    private func reserveApiCall() throws {
        let todayStr = Self.quotaDateFormatter().string(from: now())
        try Self.quotaLock.withLock {
            let (currentCount, lastDate) = Self.readQuotaState()
            let used = lastDate == todayStr ? max(0, currentCount) : 0
            guard used < Self.dailyCallLimit else { throw PolestarDataPortalError.rateLimited(retryAfter: nil) }
            let nextCount = used + 1
            if let store = Self.quotaStateStore {
                store.set(nextCount, todayStr)
                return
            }
            UserDefaults.standard.set(nextCount, forKey: "polestar_dataportal_daily_calls")
            UserDefaults.standard.set(todayStr, forKey: "polestar_dataportal_daily_date")
        }
    }

    #if DEBUG
    nonisolated static func setDailyQuotaForTesting(count: Int, date: Date) {
        let dateStr = quotaDateFormatter().string(from: date)
        quotaLock.withLock {
            if let store = quotaStateStore { store.set(count, dateStr); return }
            UserDefaults.standard.set(count, forKey: "polestar_dataportal_daily_calls")
            UserDefaults.standard.set(dateStr, forKey: "polestar_dataportal_daily_date")
        }
    }

    func setSessionForTesting(_ session: URLSession) {
        self.session = session
    }

    func setAccessTokenForTesting(_ token: String, expiry: Date = Date().addingTimeInterval(3600)) {
        self.accessToken = token
        self.tokenExpiry = expiry
    }
    #endif


    private(set) var cars: [CarSummary] = []
    var selectedVIN: String?

    private var accessToken: String? {
        get { portalTokens.accessToken }
        set { portalTokens.accessToken = newValue }
    }
    /// When the portal answers `AUTHZ_VIN_UNAUTHORIZED`, the owner has withdrawn (or not yet
    /// granted) this client's access to the VIN — retrying cannot succeed, and every refused
    /// call still burns the 10k/day meter. For an hour after a denial, fail the refresh
    /// locally with the same error instead of hitting the network.
    private var vinAccessDeniedUntil: [String: Date] = [:]

    private func epochIsCurrent(_ epoch: Int) -> Bool { sessionEpoch == epoch }
    private func checkEpoch(_ epoch: Int) throws {
        try Task.checkCancellation()
        guard sessionEpoch == epoch else { throw CancellationError() }
    }
    private var sessionEpoch = 0
    private var tokenExpiry: Date? {
        get { portalTokens.tokenExpiry }
        set { portalTokens.tokenExpiry = newValue }
    }
    /// The client-credentials grant's lifetime: reuse window, single-flight, and the terminal
    /// rejection of wrong credentials, owned by the shared token lifecycle rather than a
    /// hand-rolled task guard. Client credentials do not rotate, so persistence is a no-op.
    private let portalTokens: TokenLifecycle

    @MainActor
    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache()) {
        self.init(keychain: keychain, imageCache: imageCache, preferences: .shared)
    }

    init(
        keychain: KeychainStore = .app,
        imageCache: CarImageCache = CarImageCache(),
        preferences: PreferencesStore,
        diagnosticLog: APIDiagnosticLogStore = .shared,
        now: @escaping @Sendable () -> Date = { Date() },
        timeZone: TimeZone = .current,
        credentialReader: (@Sendable () throws -> (id: String?, secret: String?, account: String?))? = nil
    ) {
        self.keychain = keychain
        self.imageCache = imageCache
        self.preferences = preferences
        self.diagnosticLog = diagnosticLog
        self.now = now
        self.timeZone = timeZone
        self.credentialReader = credentialReader ?? {
            (try keychain.readPolestarDataPortalClientID(), try keychain.readPolestarDataPortalClientSecret(), try keychain.readPolestarDataPortalAccountID())
        }
        self.session = Self.makeSession()
        self.portalTokens = TokenLifecycle(
            // A refused call still burns quota, so renew a minute before expiry rather than
            // landing on the portal's limiter.
            policy: .init(renewalMargin: { _ in 60 }),
            providerName: "Polestar Data Portal",
            logger: AppLog.logger("polestar-dataportal-api"),
            persist: { _ in },
            isDeadGrant: { error in
                if case PolestarDataPortalError.authenticationRequired(.invalidCredentials) = error { return true }
                return false
            }
        )
    }

    private func resolveCredential(configured: String, stored: String?, builtin: String) -> String {
        if !configured.isEmpty { return configured }
        if let stored, !stored.isEmpty { return stored }
        return builtin
    }

    /// Paired resolution: a custom client ID must pair with a custom secret.
    /// Mixing custom ID + builtin secret (or vice versa) guarantees invalidCredentials.
    /// Returns nil when the pair is mixed and must be treated as not configured.
    private func resolvePairedCredentials(prefID: String, storedID: String?, storedSecret: String?) -> (id: String, secret: String)? {
        let hasCustomID = !prefID.isEmpty || (storedID?.isEmpty == false)
        let customID = !prefID.isEmpty ? prefID : (storedID ?? "")
        let customSecret = storedSecret ?? ""
        if hasCustomID {
            // Custom app: both halves must be custom. Builtins must not fill the gap.
            guard !customID.isEmpty, !customSecret.isEmpty else { return nil }
            return (customID, customSecret)
        }
        // No custom app: fall back to builtins as a pair.
        let builtinID = BuiltinPolestarSecrets.dataPortalClientID
        let builtinSecret = BuiltinPolestarSecrets.dataPortalClientSecret
        guard !builtinID.isEmpty, !builtinSecret.isEmpty else { return nil }
        return (builtinID, builtinSecret)
    }

    func prepareSession() async throws {
        let epoch = sessionEpoch
        let prefID = await MainActor.run { preferences.polestarDataPortalClientID }
        let prefAccID = await MainActor.run { preferences.polestarDataPortalAccountID }
        let storedID: String?
        let storedSecret: String?
        let storedAccount: String?
        do {
            let stored = try credentialReader()
            storedID = stored.id
            storedSecret = stored.secret
            storedAccount = stored.account
        } catch {
            throw PolestarDataPortalError.secureStorage
        }
        guard let paired = resolvePairedCredentials(prefID: prefID, storedID: storedID, storedSecret: storedSecret) else {
            throw PolestarDataPortalError.appNotConfigured
        }
        let accID = resolveCredential(configured: prefAccID, stored: storedAccount, builtin: BuiltinPolestarSecrets.dataPortalAccountID)
        try checkEpoch(epoch)
        configure(accountID: accID.isEmpty ? nil : accID, clientID: paired.id, clientSecret: paired.secret)
    }


    func configure(accountID: String? = nil, clientID: String, clientSecret: String) {
        let account = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.accountID != account || self.clientID != id || self.clientSecret != secret {
            sessionEpoch &+= 1
            portalTokens.reset()
            vinAccessDeniedUntil.removeAll()
            cars = []
            selectedVIN = nil
            weatherCache = [:]
        }
        self.accountID = account
        self.clientID = id
        self.clientSecret = secret
    }

    var isConfigured: Bool {
        !(clientID?.isEmpty ?? true) && !(clientSecret?.isEmpty ?? true)
    }

    var hasWarmSession: Bool {
        isConfigured && !cars.isEmpty
    }

    func ensureAccessToken() async throws -> String {
        let epoch = sessionEpoch
        let outcome = try await portalTokens.refresh(
            .renewalWindow,
            now: now(),
            epochIsCurrent: { [self] in await epochIsCurrent(epoch) },
            grant: { [self] in try await requestTokenGrant() }
        )
        try checkEpoch(epoch)
        switch outcome {
        case .refreshed, .notNeeded:
            guard let token = portalTokens.accessToken else {
                throw PolestarDataPortalError.appNotConfigured
            }
            return token
        case .deadGrant:
            // The configured credentials are wrong; nothing a retry can fix.
            throw PolestarDataPortalError.authenticationRequired(.invalidCredentials)
        }
    }

    private func requestTokenGrant() async throws -> TokenLifecycle.Grant {
        guard let clientID, let clientSecret, !clientID.isEmpty, !clientSecret.isEmpty else {
            throw PolestarDataPortalError.appNotConfigured
        }
        let url = baseURL.appendingPathComponent("token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["clientId": clientID, "clientSecret": clientSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try reserveApiCall()
        let (data, response) = try await portalExchange(
            for: request,
            using: session,
            limit: 256 * 1024,
            operation: "Polestar Data Portal token grant",
            provider: .polestar,
            diagnosticLog: diagnosticLog,
            logicalOperationID: UUID(),
            attempt: 1
        )
        return try tokenGrant(from: data, response: response)
    }

    private func tokenGrant(from data: Data, response: HTTPURLResponse) throws -> TokenLifecycle.Grant {
        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            logger.error("Polestar Data Portal token request rejected (HTTP \(response.statusCode))")
            throw PolestarDataPortalError.authenticationRequired(.invalidCredentials)
        }
        if response.statusCode == 429 {
            throw PolestarDataPortalError.rateLimited(
                retryAfter: ServiceResponseClassifier.retryAfter(from: response))
        }
        if response.statusCode >= 500 {
            throw PolestarDataPortalError.server(statusCode: response.statusCode)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw PolestarDataPortalError.invalidResponse(operation: "token response")
        }
        let tokenResponse: PolestarDataPortalTokenResponse
        do {
            tokenResponse = try JSONDecoder().decode(PolestarDataPortalTokenResponse.self, from: data)
        } catch {
            PolestarDecoding.log(error, operation: "Data Portal token response", logger: logger)
            throw PolestarDataPortalError.decoding(operation: "token response")
        }
        guard !tokenResponse.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...31_536_000).contains(tokenResponse.expiresIn),
              tokenResponse.tokenType.caseInsensitiveCompare("Bearer") == .orderedSame else {
            throw PolestarDataPortalError.decoding(operation: "token response")
        }
        // Access token is memory-only by design (short-lived bearer). Previously it
        // was also written to Keychain but never read back – dead write expanding
        // the blast radius. Removed.
        return TokenLifecycle.Grant(accessToken: tokenResponse.accessToken,
                                    refreshToken: nil,
                                    expiresIn: TimeInterval(tokenResponse.expiresIn))
    }


    private func portalExchange(for request: URLRequest, using session: URLSession, limit: Int, operation: String, provider: VehicleBrand, diagnosticLog: APIDiagnosticLogStore, logicalOperationID: UUID? = nil, attempt: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await HTTPExchange.data(for: request, using: session, limit: limit, operation: operation, provider: provider, diagnosticLog: diagnosticLog, logicalOperationID: logicalOperationID, attempt: attempt)
        } catch let error as PolestarError {
            switch error {
            case .network(let cause):
                if cause.code == .cancelled { throw CancellationError() }
                throw PolestarDataPortalError.network(cause)
            case .responseTooLarge(let operation): throw PolestarDataPortalError.responseTooLarge(operation: operation)
            case .invalidResponse(let operation): throw PolestarDataPortalError.invalidResponse(operation: operation)
            default: throw error
            }
        }
    }

    private func apiURL(path: String) throws -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: clean, relativeTo: baseURL) else {
            throw PolestarDataPortalError.invalidResponse(operation: path)
        }
        return url.absoluteURL
    }

    private func authenticatedGET<T: Decodable & Sendable>(_ path: String, expectedVIN: String? = nil) async throws -> T {
        // Hard-stop before the portal's own limiter does: refused calls still count against
        // the 10k/day meter, and the quota day rolls at UTC midnight.
        guard dailyCallCount < Self.dailyCallLimit else {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let midnight = utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 1, to: now()) ?? now())
            throw PolestarDataPortalError.rateLimited(retryAfter: midnight.timeIntervalSince(now()))
        }
        let epoch = sessionEpoch
        let token = try await ensureAccessToken()
        try checkEpoch(epoch)
        let url = try apiURL(path: path)
        func makeRequest(token: String) throws -> URLRequest {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let headerClientID = accountID.flatMap { $0.isEmpty ? nil : $0 } ?? clientID ?? ""
            if !headerClientID.isEmpty {
                request.setValue(headerClientID, forHTTPHeaderField: "x-client-id")
            }
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        let logicalOperationID = UUID()
        for attempt in 0...1 {
            let request = try makeRequest(token: attempt == 0 ? token : (try await refreshFor401(replacing: token)))
            try checkEpoch(epoch)
            try reserveApiCall()
            let (data, response) = try await portalExchange(
                for: request,
                using: session,
                limit: 1_000_000,
                operation: "Data Portal: \(path)",
                provider: .polestar,
                diagnosticLog: diagnosticLog,
                logicalOperationID: logicalOperationID,
                attempt: attempt + 1
            )
            try checkEpoch(epoch)
            if response.statusCode == 401, attempt == 0 {
                continue
            }
            return try decodeResponse(data: data, response: response, path: path, expectedVIN: expectedVIN)
        }
        throw PolestarDataPortalError.authenticationRequired(.expiredSession)
    }

    private func refreshFor401(replacing token: String) async throws -> String {
        // Invalidate the refused token via the lifecycle so a concurrent grant
        // is joined instead of minting a second one.
        let epoch = sessionEpoch
        let outcome = try await portalTokens.refresh(
            .serverRefused(rejectedToken: token),
            now: now(),
            epochIsCurrent: { [self] in await epochIsCurrent(epoch) },
            grant: { [self] in try await requestTokenGrant() }
        )
        try checkEpoch(epoch)
        if case .deadGrant = outcome { throw PolestarDataPortalError.authenticationRequired(.invalidCredentials) }
        guard let token = portalTokens.accessToken else {
            throw PolestarDataPortalError.authenticationRequired(.expiredSession)
        }
        return token
    }

    func testConnection() async throws -> (vehicleCount: Int, vins: [String]) {
        try await prepareSession()
        // A fresh grant on purpose: `configure` may have just replaced the credentials, and a
        // token minted by the previous ones would fake a pass. Route through the lifecycle
        // so concurrent callers single-flight instead of minting twice.
        let epoch = sessionEpoch
        let outcome = try await portalTokens.refresh(
            .serverRefused(rejectedToken: nil),
            now: now(),
            epochIsCurrent: { [self] in await epochIsCurrent(epoch) },
            grant: { [self] in try await requestTokenGrant() }
        )
        try checkEpoch(epoch)
        if case .deadGrant = outcome { throw PolestarDataPortalError.authenticationRequired(.invalidCredentials) }
        let discovery: PolestarDataPortalVehiclesDTO = try await authenticatedGET("/v1/vehicles")
        try checkEpoch(epoch)
        return (discovery.vins.count, discovery.vins)
    }

    private func decodeResponse<T: Decodable & Sendable>(data: Data, response: HTTPURLResponse, path: String, expectedVIN: String?) throws -> T {
        if response.statusCode == 401 {
            // Token already refreshed by the caller retry; do not clear here to avoid
            // wiping a just-minted token during an in-flight grant.
            throw PolestarDataPortalError.authenticationRequired(.expiredSession)
        }
        let apiError = try? JSONDecoder().decode(PolestarDataPortalAPIError.self, from: data)
        if response.statusCode == 403 {
            if let code = apiError?.error.code {
                if code == "AUTHZ_VIN_UNAUTHORIZED" {
                    throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry: \(path)")
                }
                throw PolestarDataPortalError.client(statusCode: 403, message: apiError?.error.message)
            }
            // A body-less 403 is a missing scope or a gateway refusal, not proof that the
            // owner revoked this VIN. Treating every one as `permissionDenied` armed the
            // hour-long VIN block and suppressed battery/exterior along with the one domain
            // that actually failed.
            throw PolestarDataPortalError.client(statusCode: 403)
        }
        if response.statusCode == 404 {
            // The portal's truthful "this vehicle reports no such data" is distinct from a
            // routing miss; only the body code earns that reading.
            if apiError?.error.code == "DATA_NOT_AVAILABLE" {
                throw PolestarDataPortalError.dataNotAvailable(operation: path)
            }
            throw PolestarDataPortalError.client(statusCode: 404)
        }
        // 401, 403 and 404 carry body-code semantics above; the shared ladder owns the rest.
        switch ServiceResponseClassifier.failure(status: response.statusCode,
                                                 retryAfter: ServiceResponseClassifier.retryAfter(from: response),
                                                 operation: path) {
        case nil: break
        case .rateLimited(let retryAfter):
            throw PolestarDataPortalError.rateLimited(retryAfter: retryAfter)
        case .server(let statusCode):
            throw PolestarDataPortalError.server(statusCode: statusCode)
        case .client(let statusCode, _, _):
            throw PolestarDataPortalError.client(statusCode: statusCode)
        case .authenticationRequired, .permissionDenied:
            throw PolestarDataPortalError.client(statusCode: response.statusCode)
        }
        if let expectedVIN,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let meta = object["meta"] as? [String: Any]
            let payload = (object["data"] as? [String: Any]) ?? object
            for vin in [meta?["vin"] as? String, payload["vin"] as? String].compactMap({ $0 }) {
                guard vin.caseInsensitiveCompare(expectedVIN) == .orderedSame else {
                    throw PolestarDataPortalError.invalidResponse(operation: path)
                }
            }
        }
        if let envelope = try? JSONDecoder().decode(PolestarDataPortalEnvelope<T>.self, from: data),
           let content = envelope.data {
            return content
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            PolestarDecoding.log(error, operation: "Data Portal response", logger: logger)
            throw PolestarDataPortalError.decoding(operation: path)
        }
    }

    func discoverVehicles(preferredVIN: String?) async throws {
        let epoch = sessionEpoch
        let savedVIN = await MainActor.run {
            let pref = preferences.vin(for: .polestar)
            return preferredVIN ?? (pref.isEmpty ? nil : pref)
        }
        do {
            let discovery: PolestarDataPortalVehiclesDTO = try await authenticatedGET("/v1/vehicles")
            var summaries: [CarSummary] = []
            for vin in discovery.vins {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                summaries.append(CarSummary(
                    vin: vin,
                    title: nickname.isEmpty ? "Polestar" : nickname
                ))
            }
            if summaries.isEmpty, let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                summaries.append(CarSummary(vin: vin, title: nickname.isEmpty ? "Polestar" : nickname))
            }
            try checkEpoch(epoch)
            self.cars = summaries
            let selected = (savedVIN != nil) ? (cars.first(where: { $0.vin == savedVIN }) ?? cars.first) : cars.first
            self.selectedVIN = selected?.vin
        } catch {
            try checkEpoch(epoch)
            if error is CancellationError { throw error }
            if let portalError = error as? PolestarDataPortalError, portalError.isRefreshFatal { throw error }
            logger.warning("Data Portal vehicle discovery error: \(String(describing: error), privacy: .private)")
            if let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                try checkEpoch(epoch)
                self.cars = [CarSummary(vin: vin, title: nickname.isEmpty ? "Polestar" : nickname)]
                self.selectedVIN = vin
            } else {
                self.cars = []
                self.selectedVIN = nil
                throw error
            }
        }
    }


    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        let epoch = sessionEpoch
        if let until = vinAccessDeniedUntil[vin] {
            guard now() >= until else {
                throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry (access revoked; retrying hourly)")
            }
            // The hour has passed. Clear the stamp so the quota guard below applies again.
            vinAccessDeniedUntil[vin] = nil
        }
        do {
            return try await performFetch(vin: vin, features: features)
        } catch PolestarDataPortalError.permissionDenied {
            try checkEpoch(epoch)
            vinAccessDeniedUntil[vin] = now().addingTimeInterval(3_600)
            throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry (owner access revoked; re-grant data sharing in the Polestar app)")
        }
    }

    /// How many portal GETs this refresh may spend.
    ///
    /// The portal allows 10 000 calls per UTC day. A charging refresh at the 120 s cadence
    /// fans out to 14 reads, which is 10 080 before manual refreshes or a second car — the
    /// old path hit the local hard stop and went dark until midnight. Spread the remaining
    /// quota across the refreshes left in the day instead, so the core readings survive and
    /// only optional domains thin out.
    static func refreshCallBudget(remainingCalls: Int, secondsUntilMidnight: TimeInterval) -> Int {
        let remaining = max(0, remainingCalls)
        guard remaining > 0 else { return 0 }
        // 120 s is the fastest cadence any feature asks for; do not budget for more
        // refreshes than can actually happen.
        let refreshesLeft = max(1, Int(max(60, secondsUntilMidnight) / 120))
        return max(1, min(PolestarPortalFetchPlan.maximumCost, remaining / refreshesLeft))
    }

    static func currentRefreshCallBudget(now: Date = Date()) -> Int {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let midnight = utcCalendar.startOfDay(
            for: utcCalendar.date(byAdding: .day, value: 1, to: now) ?? now)
        return refreshCallBudget(
            remainingCalls: dailyCallLimit - dailyCallCount(on: now),
            secondsUntilMidnight: midnight.timeIntervalSince(now)
        )
    }

    private func performFetch(vin: String, features: FeatureSelection) async throws -> VehicleState {
        // The token grant POST is itself metered; refuse before spending it, not after.
        if dailyCallCount >= Self.dailyCallLimit {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let midnight = utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 1, to: now()) ?? now())
            throw PolestarDataPortalError.rateLimited(retryAfter: midnight.timeIntervalSince(now()))
        }
        let epoch = sessionEpoch
        _ = try await ensureAccessToken()
        try checkEpoch(epoch)
        let pathVIN = Self.encodePathComponent(vin)
        var unavailable = SnapshotAssembly.UnavailableFeatures()
        // A portal reading that failed marks every feature it serves unavailable, so the
        // merge keeps the previous values instead of reading the nil as "the car reports
        // nothing". Refresh-fatal failures (auth, rate limit, server outage, revoked VIN
        // access) throw and abort the whole refresh so backoff and fallback can engage.
        func resolve<T>(_ reading: PortalReading<T>?, serving: [AppFeature]) -> T? {
            guard let reading else { return nil }
            unavailable.mark(serving, when: reading.failedRead)
            return reading.value
        }

        // Rotate requested domains when the budget cannot cover them all; skipped readings
        // have no fetch observation and cannot confirm a command.
        let planTime = now()
        var rotationCalendar = Calendar(identifier: .gregorian)
        rotationCalendar.timeZone = timeZone
        let plan = PolestarPortalFetchPlan(features: features, budget: Self.currentRefreshCallBudget(now: planTime), rotation: rotationCalendar.component(.hour, from: planTime))
        let needsBattery = plan.needsBattery
        let needsExterior = plan.needsExterior
        let needsHealth = plan.needsHealth
        let needsOdometer = plan.needsOdometer
        let needsLocation = plan.needsLocation
        let needsAvailability = plan.needsAvailability
        let needsClimate = plan.needsClimate
        let needsTargetSoc = plan.needsTargetSoc
        let needsAmpLimit = plan.needsAmpLimit
        let needsChargeNow = plan.needsChargeNow
        let needsChargeLocations = plan.needsChargeLocations
        let needsGlobalChargeTimer = plan.needsGlobalChargeTimer
        let needsParkingClimateTimer = plan.needsParkingClimateTimer
        let needsPreCleaning = plan.needsPreCleaning

        let fetchStartedAt = now()
        async let batteryDTO: PortalReading<PolestarDataPortalBatteryDTO>? = needsBattery
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/battery") : nil
        async let exteriorDTO: PortalReading<PolestarDataPortalExteriorDTO>? = needsExterior
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/exterior") : nil
        async let healthDTO: PortalReading<PolestarDataPortalHealthDTO>? = needsHealth
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/health") : nil
        async let availabilityDTO: PortalReading<PolestarDataPortalAvailabilityDTO>? = needsAvailability
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/availability") : nil
        async let odometerDTO: PortalReading<PolestarDataPortalOdometerDTO>? = needsOdometer
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/odometer") : nil
        async let locationDTO: PortalReading<PolestarDataPortalLocationDTO>? = needsLocation
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/location") : nil
        async let parkingClimatizationDTO: PortalReading<PolestarParkingClimatizationDTO>? = needsClimate
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/parking-climatization") : nil
        async let preCleaningDTO: PortalReading<PolestarPreCleaningDTO>? = needsPreCleaning
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/telemetry/pre-cleaning") : nil
        async let targetSocDTO: PortalReading<PolestarTargetSocDTO>? = needsTargetSoc
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/target-soc") : nil
        async let ampLimitDTO: PortalReading<PolestarAmpLimitDTO>? = needsAmpLimit
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/amp-limit") : nil
        async let chargeLocationsDTO: PortalReading<PolestarChargeLocationsDTO>? = needsChargeLocations
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/charge-locations") : nil
        async let globalChargeTimerDTO: PortalReading<PolestarGlobalChargeTimerDTO>? = needsGlobalChargeTimer
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/global-charge-timer") : nil
        async let parkingClimateTimerDTO: PortalReading<PolestarParkingClimateTimerDTO>? = needsParkingClimateTimer
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/parking-climate-timer") : nil
        async let chargeNowDTO: PortalReading<PolestarChargeNowDTO>? = needsChargeNow
            ? fetchTelemetry(vin: vin, path: "/v1/vehicles/\(pathVIN)/charging/charge-now") : nil

        let bundle = PolestarPortalTelemetryBundle(
            battery: resolve(try await batteryDTO, serving: [.chargingDetails, .batteryDiagnostics]),
            exterior: resolve(try await exteriorDTO, serving: [.exteriorStatus]),
            health: resolve(try await healthDTO, serving: [.vehicleHealth, .tyreAndWarnings]),
            availability: resolve(try await availabilityDTO, serving: [.vehicleAvailability]),
            odometer: resolve(try await odometerDTO, serving: [.vehicleHealth, .tripMeters]),
            location: resolve(try await locationDTO, serving: [.vehicleLocation]),
            parkingClimatization: resolve(try await parkingClimatizationDTO, serving: [.climateStatus, .remoteClimate]),
            preCleaning: resolve(try await preCleaningDTO, serving: [.airQuality, .remotePreCleaning]),
            targetSoc: resolve(try await targetSocDTO, serving: [.chargingDetails, .remoteCharging]),
            ampLimit: resolve(try await ampLimitDTO, serving: [.chargingDetails, .remoteCharging]),
            chargeLocations: resolve(try await chargeLocationsDTO, serving: [.chargingDetails, .chargingSchedule, .remoteSchedules, .vehicleLocation]),
            globalChargeTimer: resolve(try await globalChargeTimerDTO, serving: [.chargingSchedule, .remoteSchedules, .chargingDetails]),
            parkingClimateTimer: resolve(try await parkingClimateTimerDTO, serving: [.climateStatus, .remoteClimate, .chargingSchedule, .remoteSchedules]),
            chargeNow: resolve(try await chargeNowDTO, serving: [.chargingDetails, .remoteCharging])
        )
        let weather = features.contains(.vehicleWeather)
            ? await weather(atVehicleLocation: bundle.location, vin: vin)
            : nil
        try checkEpoch(epoch)
        var state = PolestarPortalSnapshotAssembler.assembleVehicleState(vin: vin, bundle: bundle, weather: weather, failedFeatures: unavailable.features, now: now(), timeZone: timeZone)
        let observation = VehicleReadingObservation(fetchedAt: fetchStartedAt, source: .polestarPortal)
        var observations: [VehicleReading: VehicleReadingObservation] = [:]
        if state.energy.batteryPercentage != nil { observations[.battery] = observation }
        if state.energy.rangeKm != nil { observations[.range] = observation }
        if bundle.battery != nil, state.energy.chargingState.isRecognised {
            observations[.charging] = observation
        }
        if bundle.exterior != nil { observations[.openings] = observation }
        if let lock = bundle.exterior?.centralLock?.uppercased(), ["LOCKED", "UNLOCKED", "LOCK_STATUS_LOCKED", "LOCK_STATUS_UNLOCKED"].contains(lock) { observations[.locks] = observation }
        if bundle.health != nil { observations[.health] = observation }
        if bundle.odometer?.calculatedOdometerKm != nil { observations[.odometer] = observation }
        if bundle.location?.latitude != nil, bundle.location?.longitude != nil { observations[.location] = observation }
        if case .unknown = state.identity.availability { } else { observations[.availability] = observation }
        if let status = bundle.parkingClimatization?.runningStatus, ["RUNNING_STATUS_ON", "RUNNING_STATUS_OFF"].contains(status) { observations[.climateStatus] = observation }
        if let status = bundle.preCleaning?.runningStatus, ["RUNNING_STATUS_ON", "RUNNING_STATUS_OFF"].contains(status) { observations[.airQuality] = observation }
        state.freshness.readingObservations = observations
        var commandObservations: [CommandDisplayField: VehicleReadingObservation] = [:]
        if bundle.targetSoc?.targetSocPercentage != nil { commandObservations[.chargeTarget] = observation }
        if bundle.ampLimit?.ampLimit != nil { commandObservations[.chargingCurrentLimit] = observation }
        if let charging = observations[.charging] { commandObservations[.chargingState] = charging }
        if let climate = observations[.climateStatus] { commandObservations[.climateStatus] = climate }
        if let airQuality = observations[.airQuality] { commandObservations[.airQuality] = airQuality }
        if let exterior = observations[.openings] { commandObservations[.exterior] = exterior }
        state.freshness.commandObservations = commandObservations
        return state
    }

    /// Five minutes, the same weather cadence the consumer adapter's capability cache uses:
    /// current conditions do not move faster than the polling interval between portal refreshes.
    private static let weatherCacheLifetime: TimeInterval = 300

    private var weatherCache: [String: (value: VehicleWeather, fetchedAt: Date)] = [:]

    /// Neither provider exposes a weather resource on the M2M surface, so current conditions
    /// come from Open-Meteo at the vehicle's last reported position - the same source the
    /// Polestar ID adapter uses. A failed lookup stays uncached so the next refresh retries,
    /// and `nil` weather lets the merge honestly retain the previous reading.
    private func weather(atVehicleLocation location: PolestarLocationDTO?, vin: String) async -> VehicleWeather? {
        guard let latitude = location?.latitude, let longitude = location?.longitude,
              abs(latitude) > 0.001, abs(longitude) > 0.001 else { return nil }
        if let cached = weatherCache[vin], now().timeIntervalSince(cached.fetchedAt) < Self.weatherCacheLifetime {
            return cached.value
        }
        let epoch = sessionEpoch
        let value = await OpenMeteoWeatherClient(session: session, diagnosticLog: diagnosticLog)
            .weatherWithForecast(latitude: latitude, longitude: longitude)
        if let value, sessionEpoch == epoch, !Task.isCancelled {
            weatherCache[vin] = (value, now())
        }
        return value
    }

    /// One portal reading: the decoded payload, or a failed-read marker when the endpoint
    /// miss should degrade. Refresh-fatal failures (dead token at the resource, rate limit,
    /// server outage, VIN-level authorization) throw out of this call and abort the whole
    /// refresh so the coordinator's backoff and the consumer fallback can engage.
    private struct PortalReading<T: Decodable & Sendable> {
        let value: T?
        let failedRead: Bool
    }

    private func fetchTelemetry<T: Decodable & Sendable>(vin: String, path: String) async throws -> PortalReading<T> {
        do {
            return PortalReading(value: try await authenticatedGET(path, expectedVIN: vin), failedRead: false)
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            // Paths carry the VIN and the error can echo one, so both stay private.
            logger.warning("Data Portal telemetry failed for \(path, privacy: .private): \(String(describing: error), privacy: .private)")
            if let portalError = error as? PolestarDataPortalError {
                if portalError.isRefreshFatal { throw error }
                // A truthful "this vehicle has no such data" is not a miss: serve an empty
                // reading without marking the endpoint's features unavailable.
                if portalError.isDataNotAvailable {
                    logger.info("Data Portal reports no \(path, privacy: .private) data for this vehicle.")
                    return PortalReading(value: nil, failedRead: false)
                }
            }
            return PortalReading(value: nil, failedRead: true)
        }
    }

    /// VINs are interpolated into URL paths; a stray space, "#" or "?" would otherwise
    /// truncate or redirect the request.
    nonisolated private static func encodePathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._"))) ?? raw
    }

    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        throw PolestarDataPortalError.authenticationRequired(.callbackRejected)
    }

    /// The portal is self-configuring: it resolves its own client credentials from storage
    /// inside `prepareSession`, so resume takes no token from the caller.
    func restoreSession(preferredVIN: String?, features: FeatureSelection) async throws {
        try await prepareSession()
        _ = try await ensureAccessToken()
        try await discoverVehicles(preferredVIN: preferredVIN)
        logger.info("Polestar Developer Portal session restored successfully")
    }

    func resetSession() async {
        sessionEpoch &+= 1
        portalTokens.cancelInFlightGrant()
        vinAccessDeniedUntil.removeAll()
        portalTokens.reset()
        accessToken = nil
        tokenExpiry = nil
        cars = []
        selectedVIN = nil
        weatherCache = [:]
        session.invalidateAndCancel()
        session = Self.makeSession()
    }

    func signOut() async throws {
        await resetSession()
        accountID = nil
        clientID = nil
        clientSecret = nil
        try keychain.deletePolestarDataPortalCredentials()
        try keychain.deletePolestarDataPortalToken()
    }

    func resolvedVIN(preferred: String?) -> String? {
        if let preferred, !preferred.isEmpty { return preferred }
        if let selectedVIN, !selectedVIN.isEmpty { return selectedVIN }
        return cars.first?.vin
    }

    func reloadVehicleMetadata(vin: String, features: FeatureSelection) async throws {
        _ = try await ensureAccessToken()
    }

    /// The EU Data Act M2M surface is read-only (verified live 2026-09-18: write routes sit
    /// behind an AWS IAM authorizer the M2M JWT cannot satisfy). Controls belong to the
    /// consumer gRPC path via PolestarAugmentedProvider; this conformance exists so the
    /// registry can hand the portal provider to read-only sessions.
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult {
        throw RemoteCommandError.unsupported
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

extension PolestarDataPortalAPI: VehicleProviding {}
