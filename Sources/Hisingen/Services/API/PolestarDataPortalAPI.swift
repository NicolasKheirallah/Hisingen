/**
 * @file PolestarDataPortalAPI.swift
 * @description Official Polestar Developer Portal (EU Data Act) M2M & Telemetry API client
 * @author Nicolas Kheirallah <nicolas.kheirallah@gmail.com>
 * @version 1.0.0
 */

import AppKit
import Foundation
import OSLog

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

    // MARK: - Supported OAuth Scopes (EU Data Act)
    nonisolated static let supportedScopes = "pdp-telemetry/availability pdp-telemetry/battery pdp-telemetry/exterior pdp-telemetry/health pdp-telemetry/location pdp-telemetry/odometer pdp-telemetry/parkingClimatization pdp-telemetry/preCleaning pdp-charging/ampLimit pdp-charging/chargeLocations pdp-charging/overrideChargeTimer pdp-charging/globalChargeTimer pdp-charging/isAtChargeLocation pdp-charging/parkingClimateTimer pdp-charging/targetSoc"

    // MARK: - Daily Quota Tracking (10,000 calls/day limit)
    nonisolated static let dailyCallLimit = 10_000

    nonisolated static var dailyCallCount: Int {
        let (count, date) = readQuotaState()
        return isSameCalendarDay(date, Date()) ? count : 0
    }

    nonisolated var dailyCallCount: Int {
        Self.dailyCallCount
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

    private nonisolated static func readQuotaState() -> (count: Int, dateString: String) {
        let count = UserDefaults.standard.integer(forKey: "polestar_dataportal_daily_calls")
        let dateStr = UserDefaults.standard.string(forKey: "polestar_dataportal_daily_date") ?? ""
        return (count, dateStr)
    }

    private func recordApiCall(on date: Date = Date()) {
        let todayStr = Self.quotaDateFormatter().string(from: date)
        let (currentCount, lastDate) = Self.readQuotaState()
        let nextCount = (lastDate == todayStr) ? (currentCount + 1) : 1
        UserDefaults.standard.set(nextCount, forKey: "polestar_dataportal_daily_calls")
        UserDefaults.standard.set(todayStr, forKey: "polestar_dataportal_daily_date")
    }

    #if DEBUG
    nonisolated static func resetDailyQuotaForTesting() {
        UserDefaults.standard.removeObject(forKey: "polestar_dataportal_daily_calls")
        UserDefaults.standard.removeObject(forKey: "polestar_dataportal_daily_date")
    }

    nonisolated static func setDailyQuotaForTesting(count: Int, date: Date) {
        let dateStr = quotaDateFormatter().string(from: date)
        UserDefaults.standard.set(count, forKey: "polestar_dataportal_daily_calls")
        UserDefaults.standard.set(dateStr, forKey: "polestar_dataportal_daily_date")
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

    private var accessToken: String?
    /// When the portal answers `AUTHZ_VIN_UNAUTHORIZED`, the owner has withdrawn (or not yet
    /// granted) this client's access to the VIN — retrying cannot succeed, and every refused
    /// call still burns the 10k/day meter. For an hour after a denial, fail the refresh
    /// locally with the same error instead of hitting the network.
    private var vinAccessDeniedUntil: Date?
    private var tokenExpiry: Date?
    private var inFlightTokenTask: Task<String, Error>?

    @MainActor
    init(keychain: KeychainStore = .app, imageCache: CarImageCache = CarImageCache()) {
        self.init(keychain: keychain, imageCache: imageCache, preferences: .shared)
    }

    init(
        keychain: KeychainStore = .app,
        imageCache: CarImageCache = CarImageCache(),
        preferences: PreferencesStore,
        diagnosticLog: APIDiagnosticLogStore = .shared
    ) {
        self.keychain = keychain
        self.imageCache = imageCache
        self.preferences = preferences
        self.diagnosticLog = diagnosticLog
        self.session = Self.makeSession()
    }

    private func resolveCredential(configured: String, stored: String?, builtin: String) -> String {
        if !configured.isEmpty { return configured }
        if let stored, !stored.isEmpty { return stored }
        return builtin
    }

    func prepareSession() async throws {
        let prefID = await MainActor.run { preferences.polestarDataPortalClientID }
        let prefAccID = await MainActor.run { preferences.polestarDataPortalAccountID }
        let id = resolveCredential(
            configured: prefID,
            stored: try? keychain.readPolestarDataPortalClientID(),
            builtin: BuiltinPolestarSecrets.dataPortalClientID
        )
        let secret = resolveCredential(
            configured: "",
            stored: try? keychain.readPolestarDataPortalClientSecret(),
            builtin: BuiltinPolestarSecrets.dataPortalClientSecret
        )
        let accID = resolveCredential(
            configured: prefAccID,
            stored: try? keychain.readPolestarDataPortalAccountID(),
            builtin: BuiltinPolestarSecrets.dataPortalAccountID
        )
        guard !id.isEmpty, !secret.isEmpty else {
            throw PolestarDataPortalError.appNotConfigured
        }
        configure(accountID: accID.isEmpty ? nil : accID, clientID: id, clientSecret: secret)
    }


    func configure(accountID: String? = nil, clientID: String, clientSecret: String) {
        self.accountID = accountID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isConfigured: Bool {
        !(clientID?.isEmpty ?? true) && !(clientSecret?.isEmpty ?? true)
    }

    var hasWarmSession: Bool {
        isConfigured && !cars.isEmpty
    }

    func ensureAccessToken() async throws -> String {
        if let token = accessToken, let expiry = tokenExpiry, expiry.timeIntervalSinceNow > 60 {
            return token
        }
        if let inFlight = inFlightTokenTask {
            return try await inFlight.value
        }
        let task = Task<String, Error> {
            do {
                let token = try await requestAccessToken()
                inFlightTokenTask = nil
                return token
            } catch {
                inFlightTokenTask = nil
                throw error
            }
        }
        inFlightTokenTask = task
        return try await task.value
    }

    private func requestAccessToken() async throws -> String {
        guard let clientID, let clientSecret, !clientID.isEmpty, !clientSecret.isEmpty else {
            throw PolestarDataPortalError.appNotConfigured
        }
        let url = baseURL.appendingPathComponent("token")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["clientId": clientID, "clientSecret": clientSecret]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await HTTPExchange.data(
            for: request,
            using: session,
            limit: 256 * 1024,
            operation: "Polestar Data Portal token grant",
            provider: .polestar,
            diagnosticLog: diagnosticLog
        )
        recordApiCall()
        return try handleTokenResponse(data: data, response: response)
    }

    private func handleTokenResponse(data: Data, response: HTTPURLResponse) throws -> String {
        if response.statusCode == 400 || response.statusCode == 401 || response.statusCode == 403 {
            logger.error("Polestar Data Portal token request rejected (HTTP \(response.statusCode))")
            throw PolestarDataPortalError.authenticationRequired(.invalidCredentials)
        }
        if response.statusCode == 429 {
            throw PolestarDataPortalError.rateLimited(retryAfter: Self.parseRetryAfter(response))
        }
        if response.statusCode >= 500 {
            throw PolestarDataPortalError.server(statusCode: response.statusCode)
        }
        guard let tokenResponse = try? JSONDecoder().decode(PolestarDataPortalTokenResponse.self, from: data) else {
            throw PolestarDataPortalError.decoding(operation: "token response")
        }
        self.accessToken = tokenResponse.accessToken
        self.tokenExpiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try? keychain.savePolestarDataPortalToken(tokenResponse.accessToken)
        return tokenResponse.accessToken
    }

    private static func parseRetryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(raw)
    }

    private func apiURL(path: String) throws -> URL {
        let clean = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: clean, relativeTo: baseURL) else {
            throw PolestarDataPortalError.invalidResponse(operation: path)
        }
        return url.absoluteURL
    }

    private func authenticatedGET<T: Decodable & Sendable>(_ path: String) async throws -> T {
        // Hard-stop before the portal's own limiter does: refused calls still count against
        // the 10k/day meter, and the quota day rolls at UTC midnight.
        guard Self.dailyCallCount < Self.dailyCallLimit else {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let midnight = utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            throw PolestarDataPortalError.rateLimited(retryAfter: midnight.timeIntervalSinceNow)
        }
        let token = try await ensureAccessToken()
        let url = try apiURL(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let headerClientID = (accountID?.isEmpty == false) ? accountID! : (clientID ?? "")
        if !headerClientID.isEmpty {
            request.setValue(headerClientID, forHTTPHeaderField: "x-client-id")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await HTTPExchange.data(
            for: request,
            using: session,
            limit: 1_000_000,
            operation: "Data Portal: \(path)",
            provider: .polestar,
            diagnosticLog: diagnosticLog
        )
        recordApiCall()
        return try decodeResponse(data: data, response: response, path: path)
    }

    func testConnection() async throws -> (vehicleCount: Int, vins: [String]) {
        try await prepareSession()
        _ = try await requestAccessToken()
        let discovery: PolestarDataPortalVehiclesDTO = try await authenticatedGET("/v1/vehicles")
        return (discovery.vins.count, discovery.vins)
    }

    private func decodeResponse<T: Decodable & Sendable>(data: Data, response: HTTPURLResponse, path: String) throws -> T {
        if response.statusCode == 401 {
            self.accessToken = nil
            self.tokenExpiry = nil
            throw PolestarDataPortalError.authenticationRequired(.expiredSession)
        }
        if response.statusCode == 403 {
            if let apiError = try? JSONDecoder().decode(PolestarDataPortalAPIError.self, from: data) {
                if apiError.error.code == "AUTHZ_VIN_UNAUTHORIZED" {
                    throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry: \(path)")
                }
                throw PolestarDataPortalError.client(statusCode: 403, message: apiError.error.message)
            }
            throw PolestarDataPortalError.permissionDenied(operation: path)
        }
        if response.statusCode == 429 {
            throw PolestarDataPortalError.rateLimited(retryAfter: Self.parseRetryAfter(response))
        }
        if response.statusCode >= 500 {
            throw PolestarDataPortalError.server(statusCode: response.statusCode)
        }
        if response.statusCode == 404 {
            // The portal's truthful "this vehicle reports no such data" is distinct from a
            // routing miss; only the body code earns that reading.
            if let apiError = try? JSONDecoder().decode(PolestarDataPortalAPIError.self, from: data),
               apiError.error.code == "DATA_NOT_AVAILABLE" {
                throw PolestarDataPortalError.dataNotAvailable(operation: path)
            }
            throw PolestarDataPortalError.client(statusCode: 404)
        }
        guard (200...299).contains(response.statusCode) else {
            throw PolestarDataPortalError.client(statusCode: response.statusCode)
        }
        if let envelope = try? JSONDecoder().decode(PolestarDataPortalEnvelope<T>.self, from: data),
           let content = envelope.data {
            return content
        }
        if let direct = try? JSONDecoder().decode(T.self, from: data) {
            return direct
        }
        throw PolestarDataPortalError.decoding(operation: path)
    }

    func discoverVehicles(preferredVIN: String?) async throws {
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
            self.cars = summaries
            let selected = (savedVIN != nil) ? (cars.first(where: { $0.vin == savedVIN }) ?? cars.first) : cars.first
            self.selectedVIN = selected?.vin
        } catch {
            logger.warning("Data Portal vehicle discovery error: \(String(describing: error), privacy: .private)")
            if let vin = savedVIN, !vin.isEmpty {
                let nickname = await MainActor.run { preferences.vehicleNickname(for: vin) }
                self.cars = [CarSummary(vin: vin, title: nickname.isEmpty ? "Polestar" : nickname)]
                self.selectedVIN = vin
            } else {
                self.cars = []
                self.selectedVIN = nil
                throw error
            }
        }
    }

    private struct TelemetryBundle: Sendable {
        let battery: PolestarDataPortalBatteryDTO?
        let exterior: PolestarDataPortalExteriorDTO?
        let health: PolestarDataPortalHealthDTO?
        let availability: PolestarDataPortalAvailabilityDTO?
        let odometer: PolestarDataPortalOdometerDTO?
        let location: PolestarDataPortalLocationDTO?
        let parkingClimatization: PolestarParkingClimatizationDTO?
        let preCleaning: PolestarPreCleaningDTO?
        let targetSoc: PolestarTargetSocDTO?
        let ampLimit: PolestarAmpLimitDTO?
        let chargeLocations: PolestarChargeLocationsDTO?
        let isAtChargeLocation: PolestarIsAtChargeLocationDTO?
        let globalChargeTimer: PolestarGlobalChargeTimerDTO?
        let parkingClimateTimer: PolestarParkingClimateTimerDTO?
        let chargeNow: PolestarChargeNowDTO?
        // No bundle entry for override-charge-timer: the portal defines it as POST/DELETE only,
        // so a per-refresh GET would burn quota on a guaranteed error with nothing to decode.
        // The synced read of the same override switch lives on the charge-now resource above.
    }

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        if let until = vinAccessDeniedUntil, Date() < until {
            throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry (access revoked; retrying hourly)")
        }
        do {
            return try await performFetch(vin: vin, features: features)
        } catch PolestarDataPortalError.permissionDenied {
            vinAccessDeniedUntil = Date().addingTimeInterval(3_600)
            throw PolestarDataPortalError.permissionDenied(operation: "VIN telemetry (owner access revoked; re-grant data sharing in the Polestar app)")
        }
    }

    private func performFetch(vin: String, features: FeatureSelection) async throws -> VehicleState {
        // The token grant POST is itself metered; refuse before spending it, not after.
        if vinAccessDeniedUntil == nil, Self.dailyCallCount >= Self.dailyCallLimit {
            var utcCalendar = Calendar(identifier: .gregorian)
            utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let midnight = utcCalendar.startOfDay(
                for: utcCalendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
            throw PolestarDataPortalError.rateLimited(retryAfter: midnight.timeIntervalSinceNow)
        }
        _ = try await ensureAccessToken()
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

        let needsBattery = features.contains(.chargingDetails) || features.contains(.batteryDiagnostics)
        let needsExterior = features.contains(.exteriorStatus)
        let needsHealth = features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings)
        let needsOdometer = features.contains(.vehicleHealth) || features.contains(.tripMeters)
        let needsLocation = features.contains(.vehicleLocation)
        let needsClimate = features.contains(.climateStatus) || features.contains(.remoteClimate)
        let needsPreCleaning = features.contains(.airQuality) || features.contains(.remotePreCleaning)
        let needsTargetSoc = features.contains(.chargingDetails) || features.contains(.remoteCharging)
        let needsAmpLimit = features.contains(.chargingDetails) || features.contains(.remoteCharging)
        let needsChargeNow = features.contains(.chargingDetails) || features.contains(.remoteCharging)
        let needsChargeLocations = features.contains(.chargingDetails) || features.contains(.chargingSchedule) || features.contains(.remoteSchedules)
        let needsIsAtChargeLocation = features.contains(.chargingDetails) || features.contains(.chargingSchedule) || features.contains(.vehicleLocation)
        let needsGlobalChargeTimer = features.contains(.chargingSchedule) || features.contains(.remoteSchedules) || features.contains(.chargingDetails)
        let needsParkingClimateTimer = features.contains(.climateStatus) || features.contains(.remoteClimate) || features.contains(.chargingSchedule)

        async let batteryDTO: PortalReading<PolestarDataPortalBatteryDTO>? = needsBattery
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/battery") : nil
        async let exteriorDTO: PortalReading<PolestarDataPortalExteriorDTO>? = needsExterior
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/exterior") : nil
        async let healthDTO: PortalReading<PolestarDataPortalHealthDTO>? = needsHealth
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/health") : nil
        async let availabilityDTO: PortalReading<PolestarDataPortalAvailabilityDTO>? = features.contains(.vehicleAvailability)
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/availability") : nil
        async let odometerDTO: PortalReading<PolestarDataPortalOdometerDTO>? = needsOdometer
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/odometer") : nil
        async let locationDTO: PortalReading<PolestarDataPortalLocationDTO>? = needsLocation
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/location") : nil
        async let parkingClimatizationDTO: PortalReading<PolestarParkingClimatizationDTO>? = needsClimate
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/parking-climatization") : nil
        async let preCleaningDTO: PortalReading<PolestarPreCleaningDTO>? = needsPreCleaning
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/telemetry/pre-cleaning") : nil
        async let targetSocDTO: PortalReading<PolestarTargetSocDTO>? = needsTargetSoc
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/target-soc") : nil
        async let ampLimitDTO: PortalReading<PolestarAmpLimitDTO>? = needsAmpLimit
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/amp-limit") : nil
        async let chargeLocationsDTO: PortalReading<PolestarChargeLocationsDTO>? = needsChargeLocations
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/charge-locations") : nil
        async let isAtChargeLocationDTO: PortalReading<PolestarIsAtChargeLocationDTO>? = needsIsAtChargeLocation
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/is-at-charge-location") : nil
        async let globalChargeTimerDTO: PortalReading<PolestarGlobalChargeTimerDTO>? = needsGlobalChargeTimer
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/global-charge-timer") : nil
        async let parkingClimateTimerDTO: PortalReading<PolestarParkingClimateTimerDTO>? = needsParkingClimateTimer
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/parking-climate-timer") : nil
        async let chargeNowDTO: PortalReading<PolestarChargeNowDTO>? = needsChargeNow
            ? fetchTelemetry(path: "/v1/vehicles/\(pathVIN)/charging/charge-now") : nil

        let bundle = TelemetryBundle(
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
            isAtChargeLocation: resolve(try await isAtChargeLocationDTO, serving: [.chargingDetails, .chargingSchedule, .vehicleLocation]),
            globalChargeTimer: resolve(try await globalChargeTimerDTO, serving: [.chargingSchedule, .remoteSchedules, .chargingDetails]),
            parkingClimateTimer: resolve(try await parkingClimateTimerDTO, serving: [.climateStatus, .remoteClimate, .chargingSchedule, .remoteSchedules]),
            chargeNow: resolve(try await chargeNowDTO, serving: [.chargingDetails, .remoteCharging])
        )
        return assembleVehicleState(vin: vin, bundle: bundle, failedFeatures: unavailable.features)
    }

    /// One portal reading: the decoded payload, or a failed-read marker when the endpoint
    /// miss should degrade. Refresh-fatal failures (dead token at the resource, rate limit,
    /// server outage, VIN-level authorization) throw out of this call and abort the whole
    /// refresh so the coordinator's backoff and the consumer fallback can engage.
    private struct PortalReading<T: Decodable & Sendable> {
        let value: T?
        let failedRead: Bool
    }

    private func fetchTelemetry<T: Decodable & Sendable>(path: String) async throws -> PortalReading<T> {
        do {
            return PortalReading(value: try await authenticatedGET(path), failedRead: false)
        } catch {
            logger.warning("Data Portal telemetry failed for \(path): \(String(describing: error), privacy: .public)")
            if let portalError = error as? PolestarDataPortalError {
                if portalError.isRefreshFatal { throw error }
                // A truthful "this vehicle has no such data" is not a miss: serve an empty
                // reading without marking the endpoint's features unavailable.
                if portalError.isDataNotAvailable {
                    logger.info("Data Portal reports no \(path, privacy: .public) data for this vehicle.")
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

    private func assembleAvailability(from dto: PolestarDataPortalAvailabilityDTO?) -> VehicleAvailability {
        // A missing frame must not flip a sleeping car to "Online": .unknown makes the
        // identity merge retain the previous availability until a real frame arrives.
        guard let dto, let status = dto.availabilityStatus?.uppercased() else {
            return .unknown
        }
        if status.contains("UNAVAILABLE") || status.contains("OFFLINE") {
            return .unavailable(reason: dto.unavailableReason)
        }
        return .available
    }

    private func assembleReadingDates(from bundle: TelemetryBundle) -> [VehicleReading: Date] {
        var readingDates: [VehicleReading: Date] = [:]
        if let bDate = bundle.battery?.timestamp?.date { readingDates[.battery] = bDate }
        if let eDate = bundle.exterior?.timestamp?.date { readingDates[.openings] = eDate }
        if let hDate = bundle.health?.timestamp?.date { readingDates[.health] = hDate }
        if let oDate = bundle.odometer?.timestamp?.date { readingDates[.odometer] = oDate }
        if let lDate = bundle.location?.timestamp?.date { readingDates[.location] = lDate }
        if let cDate = bundle.parkingClimatization?.timestamp?.date { readingDates[.climateStatus] = cDate }
        if let aDate = bundle.preCleaning?.timestamp?.date { readingDates[.airQuality] = aDate }
        if let avDate = bundle.availability?.timestamp?.date { readingDates[.availability] = avDate }
        if let cnDate = bundle.chargeNow?.syncedOverrideChargeTimer?.updatedAtTimestamp?.date { readingDates[.charging] = cnDate }
        return readingDates
    }

    /// Portal ingest times keyed like the vehicle report times above, so the freshness card
    /// can show where a domain sat in the delivery pipeline.
    private func assembleMetaReceivedDates(from bundle: TelemetryBundle) -> [VehicleReading: Date] {
        var received: [VehicleReading: Date] = [:]
        func ingest(_ raw: String?, for reading: VehicleReading) {
            guard let raw, let date = Self.parseMetaReceivedAt(raw) else { return }
            received[reading] = date
        }
        ingest(bundle.battery?.metaReceivedAt, for: .battery)
        ingest(bundle.exterior?.metaReceivedAt, for: .openings)
        ingest(bundle.health?.metaReceivedAt, for: .health)
        ingest(bundle.odometer?.metaReceivedAt, for: .odometer)
        ingest(bundle.location?.metaReceivedAt, for: .location)
        ingest(bundle.parkingClimatization?.metaReceivedAt, for: .climateStatus)
        ingest(bundle.preCleaning?.metaReceivedAt, for: .airQuality)
        ingest(bundle.availability?.metaReceivedAt, for: .availability)
        ingest(bundle.chargeNow?.metaReceivedAt, for: .charging)
        return received
    }

    /// Ten minutes is well above normal ingest jitter and well below anything a user would
    /// still call fresh, so only genuinely queued readings warn.
    private static let pipelineLagWarningThreshold: TimeInterval = 10 * 60

    private func assemblePipelineLagWarnings(from bundle: TelemetryBundle) -> [String] {
        let laggyDomains: [(String, vehicleReportedAt: Date?, metaReceivedAt: String?)] = [
            ("battery", bundle.battery?.timestamp?.date, bundle.battery?.metaReceivedAt),
            ("exterior", bundle.exterior?.timestamp?.date, bundle.exterior?.metaReceivedAt),
            ("health", bundle.health?.timestamp?.date, bundle.health?.metaReceivedAt),
            ("odometer", bundle.odometer?.timestamp?.date, bundle.odometer?.metaReceivedAt),
            ("location", bundle.location?.timestamp?.date, bundle.location?.metaReceivedAt),
            ("climate", bundle.parkingClimatization?.timestamp?.date, bundle.parkingClimatization?.metaReceivedAt),
            ("air quality", bundle.preCleaning?.timestamp?.date, bundle.preCleaning?.metaReceivedAt)
        ]
        return laggyDomains.compactMap { (domain: String, reportedAt: Date?, receivedAt: String?) -> String? in
            guard let reportedAt, let receivedAt,
                  let ingestedAt = Self.parseMetaReceivedAt(receivedAt) else { return nil }
            let interval = ingestedAt.timeIntervalSince(reportedAt)
            guard interval >= Self.pipelineLagWarningThreshold else { return nil }
            let lag = Int(interval / 60)
            return L10n.format("%@ data was delayed at the portal for %d min", domain, Int(lag))
        }
    }

    /// Wire form is RFC 3339, with fractional seconds on the live portal and without in
    /// recorded payloads.
    private static func parseMetaReceivedAt(_ value: String) -> Date? {
        if let date = isoFormatterWithFraction.date(from: value) { return date }
        return isoFormatter.date(from: value)
    }

    // ISO8601DateFormatter is state-mutable but only touched inside this actor's
    // parseMetaReceivedAt, which the actor serializes; nonisolated(unsafe) documents that.
    nonisolated(unsafe) private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let isoFormatter = ISO8601DateFormatter()

    private func assembleVehicleState(vin: String, bundle: TelemetryBundle, failedFeatures: [AppFeature] = []) -> VehicleState {
        var energy = bundle.battery?.toEnergySnapshot() ?? EnergyAndChargingSnapshot()
        if let target = bundle.targetSoc?.targetSocPercentage { energy.targetPercentage = target }
        if let amp = bundle.ampLimit?.ampLimit { energy.currentLimitAmps = amp }
        if let locs = bundle.chargeLocations { energy.locations = locs.toChargeLocations() }
        if let timers = bundle.globalChargeTimer { energy.schedules = timers.toSchedules() }
        if let isAt = bundle.isAtChargeLocation {
            energy.isAtChargeLocation = isAt.isAtChargeLocation
            // The is-at state carries only a locationId; resolve the display name against
            // the synced charge-locations list fetched in the same refresh.
            if let locationId = isAt.locationId {
                let matched = bundle.chargeLocations?.chargeLocations?.first(where: { $0.locationId == locationId })
                let alias = matched?.locationAlias ?? energy.locations.first(where: { $0.id == locationId })?.alias
                if let alias, !alias.isEmpty {
                    energy.currentChargeLocationName = alias
                }
                if let bidi = matched?.isBidirectionalChargingEnabled {
                    energy.diagnostics?.isBidirectionalChargingEnabled = bidi
                }
                if let opt = matched?.isOptimizedChargingEnabled {
                    energy.diagnostics?.isOptimizedChargingEnabled = opt
                }
                if let avail = matched?.availableOptimizedCharging {
                    energy.diagnostics?.availableOptimizedCharging = avail
                }
            }
            energy.arrivedAtLocationDate = isAt.arrivedAtTimestamp?.date
        }
        if let syncedOverride = bundle.chargeNow?.syncedOverrideChargeTimer {
            // Only the synced value counts: a pending override has not reached the car yet.
            energy.chargeNowActive = syncedOverride.override == true
        }
        // The backend queues setting changes behind the car's next wake; the pending copies
        // ride alongside the synced values so the controls card can say "queued" instead of
        // silently showing a number the car has not applied.
        if let pendingTarget = bundle.targetSoc?.pendingTargetSoc?.batteryChargeTargetLevel {
            energy.diagnostics?.pendingTargetPercentage = Int(pendingTarget.rounded())
        }
        if let pendingAmps = bundle.ampLimit?.pendingAmpLimit?.ampLimit {
            energy.diagnostics?.pendingLimitAmps = Int(pendingAmps.rounded())
        }
        energy.diagnostics?.targetSource = bundle.targetSoc?.targetSoc?.source
        energy.diagnostics?.limitSource = bundle.ampLimit?.syncedAmpLimit?.source
        if let increase = bundle.battery?.dischargeInfo?.energyAvailableIncrease {
            energy.diagnostics?.energyAvailableIncreaseKwh = increase
        }
        if let preconditioning = bundle.battery?.manualPreconditioning {
            energy.diagnostics?.batteryPreconditioningStatus = preconditioning.preconditioningStatus
            energy.diagnostics?.batteryPreconditioningEndsAt = preconditioning.endingAt?.date
        } else if let bpSetting = bundle.parkingClimateTimer?.timerSettings?.batteryPreconditioning,
                  bpSetting != "BP_UNDEFINED" && bpSetting != "BP_OFF" {
            energy.diagnostics?.batteryPreconditioningStatus = bpSetting
        }

        var extSnapshot = bundle.exterior?.toExteriorSnapshot()
        if let alarm = bundle.exterior?.alarm?.uppercased() {
            // The shared exterior mapper treats any value containing "ALARM" as an event,
            // which would flag the spec's ALARM_STATUS_IDLE as triggered. Only the
            // TRIGGERED spelling is an alarm event.
            extSnapshot?.alarmTriggered = alarm.contains("TRIGGERED")
        }

        var healthSnapshot = bundle.health?.toMaintenanceSnapshot() ?? MaintenanceAndHealthSnapshot()
        if let km = bundle.odometer?.calculatedOdometerKm { healthSnapshot.odometerKm = km }
        // The portal reports lifetime distance in metres; keep the sub-kilometre remainder
        // instead of letting only the rounded kilometre value carry it.
        healthSnapshot.odometerKmPrecise = bundle.odometer?.odometerMeters.map { $0 / 1000.0 }

        let tripComputer = bundle.odometer?.toTripComputerSnapshot() ?? TripComputerSnapshot()

        let availability = assembleAvailability(from: bundle.availability)
        let identity = VehicleIdentitySnapshot(
            availability: availability,
            availabilityReportedAt: bundle.availability?.timestamp?.date,
            // Deliberately nil: the M2M surface carries no model metadata, and a placeholder
            // here would win the state merge over the consumer API's real model name
            // ("Polestar" vs "Polestar 2"). A nil keeps the previously fetched name instead.
            modelName: nil,
            vin: vin,
            usageMode: bundle.availability?.usageMode,
            // A stale reason must not shadow an AVAILABLE report, so keep the raw wire
            // value only while the vehicle actually reads as unavailable.
            unavailableReason: {
                if case .unavailable = availability { return bundle.availability?.unavailableReason }
                return nil
            }()
        )
        let readingDates = assembleReadingDates(from: bundle)
        let freshness = SnapshotFreshness(
            isCached: false,
            fetchedAt: Date(),
            vehicleReportedAt: readingDates.values.max(),
            readingDates: readingDates,
            // metaReceivedAt is the portal's ingest time; a large gap to the vehicle's own
            // timestamp means the reading sat in the delivery pipeline and may be older
            // than its freshness suggests.
            metaReceivedDates: assembleMetaReceivedDates(from: bundle),
            dataWarnings: assemblePipelineLagWarnings(from: bundle),
            // The consumer-exclusive commands are never portal-served; the rest of the
            // list is what this refresh actually asked for and failed to read.
            unavailableFeatures: failedFeatures + [.remoteLocks, .remoteWindows, .remoteHonkFlash, .remoteOTA]
        )

        let timerSettings = bundle.parkingClimateTimer?.timerSettings
        func timerSeatLevel(_ raw: String?) -> Int? {
            switch raw?.uppercased() {
            case "I_OFF", "HEATING_INTENSITY_OFF", "OFF": return 0
            case "I_LEVEL1", "HEATING_INTENSITY_LOW", "LEVEL_1", "LOW": return 1
            case "I_LEVEL2", "HEATING_INTENSITY_MEDIUM", "LEVEL_2", "MEDIUM": return 2
            case "I_LEVEL3", "HEATING_INTENSITY_HIGH", "LEVEL_3", "HIGH": return 3
            default: return nil
            }
        }

        let climateStatus: VehicleClimateStatus? = {
            if let clim = bundle.parkingClimatization {
                var status = clim.toVehicleClimateStatus(batteryPreconditioning: bundle.battery?.manualPreconditioning)
                if status.requestedTemperatureCelsius == nil, let t = timerSettings?.requestedCompartmentTemperatureCelsius {
                    status = VehicleClimateStatus(
                        activity: status.activity,
                        timeRemainingMinutes: status.timeRemainingMinutes,
                        timerTriggered: status.timerTriggered,
                        interiorTemperatureCelsius: status.interiorTemperatureCelsius,
                        requestedTemperatureCelsius: t,
                        driverSeatHeatingLevel: status.driverSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowLeftSeat),
                        passengerSeatHeatingLevel: status.passengerSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowRightSeat),
                        steeringWheelHeatingLevel: status.steeringWheelHeatingLevel ?? timerSeatLevel(timerSettings?.steeringWheelHeatingIntensity),
                        rearLeftSeatHeatingLevel: status.rearLeftSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowLeftSeat),
                        rearRightSeatHeatingLevel: status.rearRightSeatHeatingLevel ?? timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowRightSeat),
                        ventilation: status.ventilation,
                        mainClimateRunningStatus: status.mainClimateRunningStatus,
                        sessionStartedAt: status.sessionStartedAt,
                        sessionEndsAt: status.sessionEndsAt,
                        errors: status.errors,
                        startReason: status.startReason
                    )
                }
                return status
            }
            if let precond = bundle.battery?.manualPreconditioning {
                let status = precond.preconditioningStatus?.uppercased()
                let isActive = status == "MANUAL_PRECONDITIONING_STATUS_ON" || status == "ACTIVE"
                let started = precond.startedAt?.date
                let ends = precond.endingAt?.date
                let remaining: Int? = {
                    guard let ends else { return nil }
                    let diff = ends.timeIntervalSinceNow
                    return diff > 0 ? max(1, Int(diff / 60)) : 0
                }()
                return VehicleClimateStatus(
                    activity: isActive ? .active : .idle,
                    timeRemainingMinutes: isActive ? remaining : nil,
                    timerTriggered: false,
                    requestedTemperatureCelsius: timerSettings?.requestedCompartmentTemperatureCelsius,
                    driverSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowLeftSeat),
                    passengerSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.frontRowRightSeat),
                    steeringWheelHeatingLevel: timerSeatLevel(timerSettings?.steeringWheelHeatingIntensity),
                    rearLeftSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowLeftSeat),
                    rearRightSeatHeatingLevel: timerSeatLevel(timerSettings?.seatHeatingIntensity?.rearRowRightSeat),
                    sessionStartedAt: started,
                    sessionEndsAt: ends
                )
            }
            if let timerSettings, let reqTemp = timerSettings.requestedCompartmentTemperatureCelsius {
                return VehicleClimateStatus(
                    activity: .idle,
                    timeRemainingMinutes: nil,
                    timerTriggered: false,
                    requestedTemperatureCelsius: reqTemp,
                    driverSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.frontRowLeftSeat),
                    passengerSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.frontRowRightSeat),
                    steeringWheelHeatingLevel: timerSeatLevel(timerSettings.steeringWheelHeatingIntensity),
                    rearLeftSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.rearRowLeftSeat),
                    rearRightSeatHeatingLevel: timerSeatLevel(timerSettings.seatHeatingIntensity?.rearRowRightSeat)
                )
            }
            return nil
        }()

        let airQuality = bundle.preCleaning?.toVehicleAirQuality()
        let climateTimers = bundle.parkingClimateTimer?.toClimateSchedules() ?? []

        return VehicleState(
            energy: energy,
            identity: identity,
            maintenance: healthSnapshot,
            freshness: freshness,
            commandState: CommandPresentationState(),
            exteriorStatus: extSnapshot,
            climateStatus: climateStatus,
            climateTimers: climateTimers,
            tripComputer: tripComputer,
            airQuality: airQuality,
            location: bundle.location?.toVehicleLocation(),
            powertrain: .bev
        )
    }


    func authenticate(email: String, password: String, preferredVIN: String?, features: FeatureSelection) async throws {
        throw PolestarDataPortalError.authenticationRequired(.callbackRejected)
    }

    func restoreSession(token: String, preferredVIN: String?, features: FeatureSelection) async throws {
        try await prepareSession()
        _ = try await ensureAccessToken()
        try await discoverVehicles(preferredVIN: preferredVIN)
        logger.info("Polestar Developer Portal session restored successfully")
    }

    func resetSession() async {
        vinAccessDeniedUntil = nil
        accessToken = nil
        tokenExpiry = nil
        inFlightTokenTask?.cancel()
        inFlightTokenTask = nil
        cars = []
        selectedVIN = nil
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
