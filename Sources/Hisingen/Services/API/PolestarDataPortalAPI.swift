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

    private let baseURL = URL(string: "https://pc-api.polestar.com/eu-north-1/data-portal/m2m")!

    var accountID: String?
    var clientID: String?
    var clientSecret: String?

    var session: URLSession
    let keychain: KeychainStore
    let imageCache: CarImageCache
    let preferences: PreferencesStore
    let diagnosticLog: APIDiagnosticLogStore

    private(set) var cars: [CarSummary] = []
    var selectedVIN: String?

    private var accessToken: String?
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

    func prepareSession() async throws {
        let configuredID = await MainActor.run { preferences.polestarDataPortalClientID }
        let storedID = try? keychain.readPolestarDataPortalClientID()
        let id = configuredID.isEmpty ? storedID : configuredID
        let secret = try? keychain.readPolestarDataPortalClientSecret()
        let configuredAccountID = await MainActor.run { preferences.polestarDataPortalAccountID }
        let storedAccountID = try? keychain.readPolestarDataPortalAccountID()
        let accID = configuredAccountID.isEmpty ? storedAccountID : configuredAccountID
        guard let id, !id.isEmpty, let secret, !secret.isEmpty else {
            throw PolestarDataPortalError.appNotConfigured
        }
        configure(accountID: accID, clientID: id, clientSecret: secret)
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
        return try decodeResponse(data: data, response: response, path: path)
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
        if response.statusCode != 200 {
            throw PolestarDataPortalError.client(statusCode: response.statusCode)
        }
        if let direct = try? JSONDecoder().decode(T.self, from: data) {
            return direct
        }
        if let envelope = try? JSONDecoder().decode(PolestarDataPortalEnvelope<T>.self, from: data),
           let content = envelope.data {
            return content
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

    func fetchVehicleState(vin: String, features: FeatureSelection) async throws -> VehicleState {
        _ = try await ensureAccessToken()

        let needsBattery = features.contains(.chargingDetails) || features.contains(.batteryDiagnostics)
        let needsExterior = features.contains(.exteriorStatus)
        let needsHealth = features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings)

        async let batteryDTO: PolestarDataPortalBatteryDTO? = needsBattery
            ? fetchTelemetry(path: "/v1/vehicles/\(vin)/telemetry/battery") : nil
        async let exteriorDTO: PolestarDataPortalExteriorDTO? = needsExterior
            ? fetchTelemetry(path: "/v1/vehicles/\(vin)/telemetry/exterior") : nil
        async let healthDTO: PolestarDataPortalHealthDTO? = needsHealth
            ? fetchTelemetry(path: "/v1/vehicles/\(vin)/telemetry/health") : nil
        async let availabilityDTO: PolestarDataPortalAvailabilityDTO? = features.contains(.vehicleAvailability)
            ? fetchTelemetry(path: "/v1/vehicles/\(vin)/telemetry/availability") : nil

        let (battery, exterior, health, availability) = await (batteryDTO, exteriorDTO, healthDTO, availabilityDTO)
        return assembleVehicleState(
            vin: vin,
            battery: battery,
            exterior: exterior,
            health: health,
            availability: availability
        )
    }

    private func fetchTelemetry<T: Decodable & Sendable>(path: String) async -> T? {
        do {
            return try await authenticatedGET(path)
        } catch {
            logger.warning("Optional Data Portal telemetry failed for \(path): \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private func assembleVehicleState(
        vin: String,
        battery: PolestarDataPortalBatteryDTO?,
        exterior: PolestarDataPortalExteriorDTO?,
        health: PolestarDataPortalHealthDTO?,
        availability: PolestarDataPortalAvailabilityDTO?
    ) -> VehicleState {
        let energy = battery?.toEnergySnapshot() ?? EnergyAndChargingSnapshot()
        let extSnapshot = exterior?.toExteriorSnapshot()
        let healthSnapshot = health?.toMaintenanceSnapshot() ?? MaintenanceAndHealthSnapshot()

        let availStatus: VehicleAvailability = {
            guard let availability else { return .available }
            if let status = availability.availabilityStatus?.uppercased() {
                if status.contains("UNAVAILABLE") || status.contains("OFFLINE") {
                    return .unavailable(reason: availability.unavailableReason)
                }
            }
            return .available
        }()

        let identity = VehicleIdentitySnapshot(
            availability: availStatus,
            availabilityReportedAt: availability?.timestamp?.date,
            modelName: "Polestar",
            vin: vin
        )

        var readingDates: [VehicleReading: Date] = [:]
        if let bDate = battery?.timestamp?.date { readingDates[.battery] = bDate }
        if let eDate = exterior?.timestamp?.date { readingDates[.openings] = eDate }
        if let hDate = health?.timestamp?.date { readingDates[.health] = hDate }

        let freshness = SnapshotFreshness(
            isCached: false,
            fetchedAt: Date(),
            vehicleReportedAt: readingDates.values.max(),
            readingDates: readingDates,
            unavailableFeatures: Array(AppFeature.remoteFeatures)
        )

        return VehicleState(
            energy: energy,
            identity: identity,
            maintenance: healthSnapshot,
            freshness: freshness,
            commandState: CommandPresentationState(),
            exteriorStatus: extSnapshot,
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
