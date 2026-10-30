

import Foundation

// Adapted from simonbusborg/polaris (MIT, Copyright (c) 2026 Simon Busborg), since reworked:
// `Protobuf`, the frame reading now in `GRPCFrameReader`, the request now in `grpcRequest`,
// `fetchBattery` with `parseBattery` fields 6, 10, 11, 17 and 18, and `c3Host`.
// Polaris takes those message shapes from pypolestar (MIT, Copyright (c) 2023 Tuen Lee).
// Everything else in this file and in PolestarGRPCRemote and PolestarGRPCCapabilities is
// Hisingen's own. Full notices and license texts: THIRD_PARTY_NOTICES.md.

/// Availability plus the wire context Hisingen retains but does not yet decode: the frame
/// timestamp (field 1) and any field outside the decoded set (currently 5). Retained so a
/// future classification pass can name them from accumulated observations.
struct GrpcAvailabilityReport: Equatable, Sendable {
    let availability: VehicleAvailability
    let reportedAt: Date?
    let unknownFields: [VehicleRawWireField]
}

struct GrpcBatteryExtras: Codable, Equatable, Sendable {
    let reportedAt: Date?
    let batteryPercentage: Double?
    let rangeKm: Int?
    let estimatedChargingTimeToFullMinutes: Int?
    let chargingState: ChargingState?
    let chargerConnection: ChargerConnection
    let chargingType: ChargingType
    let chargingPowerWatts: Int?
    let chargingCurrentAmps: Int?
    let chargingVoltageVolts: Int?
    let diagnostics: BatteryDiagnostics
    /// Backend-reported usable pack capacity in kWh (field 12 in live captures).
    let reportedBatteryCapacityKwh: Double?
    /// Every wire field this parser does not decode semantically, captured raw.
    let unknownFields: [VehicleRawWireField]
}

struct PolestarInFlightRequest<Value: Sendable>: Sendable {
    let id: UUID
    let task: Task<Value, Error>
}

actor PolestarGRPC {

    private let discoveryURL = URL(string: "https://cnepmob.volvocars.com")!
    private let batteryPath = "/services.vehiclestates.battery.BatteryService/GetLatestBattery"
    private let batteryStreamPath = "/services.vehiclestates.battery.BatteryService/GetBattery"
    private let availabilityPath = "/services.vehiclestates.availability.AvailabilityService/GetLatestAvailability"
    private let targetSocPath = "/pccs.chronos.services.v1.TargetSocService/GetTargetSoc"
    private let ampLimitReadPath = "/pccs.chronos.services.v1.AmpLimitService/GetAmpLimit"


    private let pccsURL = URL(string: "https://api.pccs-prod.plstr.io:443")!

    private var c3BaseURL: URL?
    /// When the discovered host is looked up again. The app can run for weeks, and a host
    /// Volvo moves should be picked up without a relaunch.
    private var c3HostExpiry: Date?
    static let discoveredHostLifetime: TimeInterval = 12 * 60 * 60
    /// After a failed re-discovery the previous host keeps serving, and discovery is retried
    /// after this delay instead of on every call.
    static let discoveryRetryDelay: TimeInterval = 60 * 60
    private var c3DiscoveryTask: PolestarInFlightRequest<URL>?
    /// Supplies the app/command grant so discovery can retry a 406 with the other audience.
    /// `PolestarAPI` owns both grants and installs this before the first telemetry sweep.
    private var alternateAccessTokenProvider: (@Sendable () async -> String?)?

    /// Installs the second grant used by the discovery retry ladder. Idempotent to call.
    func setAlternateAccessTokenProvider(_ provider: @escaping @Sendable () async -> String?) {
        alternateAccessTokenProvider = provider
    }
    var exteriorCache: [String: ExteriorSnapshot] = [:]
    var otaSoftwareIDs: [String: String] = [:]
    /// Backend-advertised charging bounds per VIN (`GetMyCars`), used to validate
    /// charge-target and amp-limit writes against what the vehicle actually supports.
    var capabilityLimits: [String: VehicleOTACapabilities] = [:]
    /// Last observed OTA state per VIN. `InstallNow` is only meaningful for some of these, and
    /// the backend reports the rest in HTTP/2 trailers we cannot read – so the precondition is
    /// checked here instead of being discovered as an unexplained refusal.
    var otaSoftwareStates: [String: SoftwareUpdateState] = [:]
    /// Last observed raw OTA state per VIN, preserving the 15 vs 1 distinction.
    var otaRawSoftwareStates: [String: SoftwareStateRaw] = [:]
    /// Backend/VIN/path keys that answered a read with status 12 UNIMPLEMENTED.
    /// They are skipped for this vehicle and backend for 24 hours rather than
    /// re-attempted – and failing – on every refresh. The expiry lets a newly deployed backend
    /// capability recover without requiring the user to clear defaults.
    var unimplementedReadPaths: Set<String>
    var unimplementedReadPathExpirations: [String: Date]
    private static let unimplementedReadPathsKey = "polestar_unimplemented_grpc_paths_v3"
    private static let legacyUnimplementedReadPathsKey = "polestar_unimplemented_grpc_paths_v1"
    private static let unimplementedReadPathTTL: TimeInterval = 24 * 60 * 60
    private let defaults: UserDefaults
    let diagnosticLog: APIDiagnosticLogStore

    /// Single-flight guard for `fetchLocation`: one telemetry sweep asks for the vehicle's
    /// location directly *and* again inside `fetchWeather`, so without this the location RPC
    /// (which itself walks several candidate endpoints) ran twice per refresh.
    var locationInFlight: [String: PolestarInFlightRequest<VehicleLocation?>] = [:]
    var chargeLocationsInFlight: [String: PolestarInFlightRequest<Data>] = [:]
    var myCarsInFlight: [String: PolestarInFlightRequest<Data>] = [:]

    /// Maps a non-zero gRPC status on a *read* RPC to a typed `PolestarError` so that
    /// permanently unimplemented services (12), transient unavailability (14), a service-scoped
    /// authorization refusal (16 carrying the gateway's own `Access denied`), and an
    /// authentication failure (any other 16) each receive distinct handling.
    static func readStatusError(status: String, message: String? = nil, path: String) -> PolestarError {
        let service = path.split(separator: "/").first.map(String.init) ?? path
        let decoded = (message?.removingPercentEncoding ?? message)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = decoded?.lowercased()
        switch status {
        case "12": return .grpcUnimplemented(service: service)
        case "14" where detail?.contains("authorization failed") == true:
            // Some Chronos reads report a stable per-service authorization gap as UNAVAILABLE
            // rather than PERMISSION_DENIED. It is not a dead account token because sibling
            // RPCs succeed with the same bearer token; classify it as an unsupported optional
            // capability so the caller backs off for hours.
            return .permissionDenied(operation: service)
        case "14": return .grpcUnavailable(service: service)
        case "16" where detail?.contains("access denied") == true:
            // PCCS checks authorization before it resolves a method, so a Chronos read answers
            // `Access denied` when this client is not on that service's allowlist. That is a
            // per-service verdict, not a statement about the bearer token, and sibling RPCs
            // succeed with the same one. Reading it as an expired session tore down a live
            // session, showed "Sign in is required.", and spent a refresh-token grant on every
            // retry. Same treatment as the 14 above: withhold the capability and back off.
            return .permissionDenied(operation: service)
        case "16": return .authenticationRequired(.expiredSession)
        default:
            // Keep the server's own explanation. For INVALID_ARGUMENT (3) the message is the
            // only thing that separates a malformed request from a field this backend rejects,
            // and discarding it left the failure undiagnosable from a support export.
            let reason = decoded.flatMap { $0.isEmpty ? nil : $0 }.map { ": \($0.prefix(160))" } ?? ""
            return .invalidResponse(operation: "gRPC \(status) \(service)\(reason)")
        }
    }

    /// Applies `readStatusError` and, for UNIMPLEMENTED, remembers the path so it is not
    /// retried. Call from every read helper's non-zero-status branch.
    func readStatusFailure(status: String, message: String? = nil, path: String, vin: String, base: URL) -> PolestarError {
        let error = Self.readStatusError(status: status, message: message, path: path)
        let key = Self.readCapabilityKey(path: path, vin: vin, base: base)
        if case .grpcUnimplemented = error,
           unimplementedReadPaths.insert(key).inserted {
            unimplementedReadPathExpirations[key] = Date().addingTimeInterval(Self.unimplementedReadPathTTL)
            persistUnimplementedReadPaths()
        }
        return error
    }

    static func readCapabilityKey(path: String, vin: String, base: URL) -> String {
        "\(base.absoluteString)|\(vin)|\(path)"
    }

    func isReadPathUnimplemented(_ path: String, vin: String, base: URL) -> Bool {
        let key = Self.readCapabilityKey(path: path, vin: vin, base: base)
        guard unimplementedReadPaths.contains(key) else { return false }
        if let expiry = unimplementedReadPathExpirations[key], expiry > Date() { return true }
        unimplementedReadPaths.remove(key)
        unimplementedReadPathExpirations[key] = nil
        persistUnimplementedReadPaths()
        return false
    }

    static func canTryAlternativeEndpoint(after error: Error) -> Bool {
        switch error as? PolestarError {
        case .grpcUnimplemented, .incompatibleAPI: return true
        case .client(let status): return status == 404 || status == 405
        default: return false
        }
    }

    /// Classifies a discovery attempt that a later attempt in the ladder will retry. A 406 here
    /// is the endpoint refusing the presented Accept version or grant audience, both of which
    /// the ladder handles; recording it as an unclassified failure produced one phantom error
    /// per launch.
    static func expectedDiscoveryRetry(_ data: Data, status: Int) -> String? {
        status == 406 ? "expected:discovery-retry" : nil
    }

    private func persistUnimplementedReadPaths() {
        defaults.set(unimplementedReadPathExpirations.mapValues(\.timeIntervalSince1970),
                     forKey: Self.unimplementedReadPathsKey)
    }

    #if DEBUG
    /// Test hook: seeds vehicle-advertised charging bounds without a network round-trip.
    func setCapabilityLimitsForTesting(vin: String, _ capabilities: VehicleOTACapabilities) {
        capabilityLimits[vin] = capabilities
    }
    #endif

    func liveUpdates(
        vin: String, accessToken: String, purpose: VehicleLiveStreamPurpose
    ) async throws -> AsyncThrowingStream<VehicleLiveUpdate, Error> {
        let base = try await resolvedHost(.c3, accessToken: accessToken)
        let requestBody = Protobuf.stringField(1, UUID().uuidString) + Protobuf.stringField(2, vin)
        let stream: (path: String, parse: @Sendable (Data) -> VehicleLiveUpdate?)
        switch purpose {
        case .charging:
            // A malformed frame is skipped; the next full snapshot replaces it.
            stream = (batteryStreamPath, { body in
                guard let payload = try? Self.responsePayload(body),
                      let battery = try? Self.parseBattery(payload) else { return nil }
                return .battery(battery)
            })
        case .exteriorConfirmation:
            stream = ("/services.vehiclestates.exterior.ExteriorService/GetExterior", { body in
                guard let payload = Protobuf.fields(body)
                    .first(where: { $0.number == 3 && $0.wire == 2 })?.data,
                      let exterior = Self.parseExterior(payload) else { return nil }
                return .exterior(exterior, reportedAt: nil)
            })
        }

        // `bufferingNewest` bounds memory if the UI consumer stalls while the push stream
        // stays chatty; dropping stale frames is correct because each frame is a full
        // snapshot, not a delta.
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let worker = Task {
                do {
                    try await self.consumeLiveFrames(
                        base: base, path: stream.path,
                        message: requestBody, vin: vin, accessToken: accessToken,
                        onConnected: { continuation.yield(.connected(activeTransportStreams: 1)) }
                    ) { body in
                        if let update = stream.parse(body) { continuation.yield(update) }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    private func consumeLiveFrames(
        base: URL, path: String, message: Data, vin: String, accessToken: String,
        onConnected: @escaping @Sendable () -> Void,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        // `timeoutIntervalForRequest` is the maximum gap between received bytes. A parked,
        // sleeping vehicle legitimately pushes no battery/exterior frames for many minutes, so
        // a short value here turned "quiet" into a `-1001` drop and a reconnect every ~95 s.
        // 20 minutes still recovers a silently-dead connection promptly without churning on an
        // idle car.
        configuration.timeoutIntervalForRequest = 20 * 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let liveSession = URLSession(configuration: configuration)
        defer { liveSession.invalidateAndCancel() }

        let request = Self.grpcRequest(base: base, path: path, message: message,
                                       vin: vin, accessToken: accessToken)

        let startedAt = Date()
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await liveSession.bytes(for: request)
        } catch {
            await diagnosticLog.record(
                provider: .polestar, request: request, operation: "live gRPC \(path)",
                startedAt: startedAt, error: error)
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            let error = PolestarError.invalidResponse(operation: "live gRPC stream")
            await diagnosticLog.record(
                provider: .polestar, request: request, operation: "live gRPC \(path)",
                startedAt: startedAt, error: error)
            throw error
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            let error = PolestarError.authenticationRequired(.expiredSession)
            await diagnosticLog.record(
                provider: .polestar, request: request, operation: "live gRPC \(path)",
                statusCode: http.statusCode, startedAt: startedAt, error: error)
            throw error
        }
        guard http.statusCode == 200 else {
            let error = PolestarError.server(statusCode: http.statusCode)
            await diagnosticLog.record(
                provider: .polestar, request: request, operation: "live gRPC \(path)",
                statusCode: http.statusCode, startedAt: startedAt, error: error)
            throw error
        }
        if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
            let error = Self.readStatusError(status: status,
                                             message: http.value(forHTTPHeaderField: "grpc-message"),
                                             path: path)
            await diagnosticLog.record(
                provider: .polestar, request: request,
                operation: "live gRPC \(path)",
                grpcStatus: status,
                grpcMessage: http.value(forHTTPHeaderField: "grpc-message"),
                statusCode: http.statusCode, startedAt: startedAt, error: error)
            throw error
        }
        await diagnosticLog.record(
            provider: .polestar, request: request, operation: "live gRPC \(path) connected",
            statusCode: http.statusCode, startedAt: startedAt)
        onConnected()

        var reader = GRPCFrameReader(context: "live gRPC")
        for try await byte in bytes {
            try Task.checkCancellation()
            if let frame = try reader.consume(byte) { onFrame(frame) }
        }
        try Task.checkCancellation()
        throw PolestarError.grpcUnavailable(service: path)
    }
    let session: URLSession

    init(defaultsSuiteName: String? = nil, session: URLSession? = nil,
         diagnosticLog: APIDiagnosticLogStore = .shared) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.diagnosticLog = diagnosticLog
        let defaults = self.defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        self.session = session ?? URLSession(configuration: config)
        let now = Date()
        let persisted = (defaults.dictionary(forKey: Self.unimplementedReadPathsKey)
            as? [String: Double] ?? [:]).compactMapValues { epoch -> Date? in
                let expiry = Date(timeIntervalSince1970: epoch)
                return expiry > now ? expiry : nil
            }
        let expirations = persisted
        // Old entries have no vehicle or backend scope and cannot be reused safely.
        defaults.removeObject(forKey: "polestar_unimplemented_grpc_paths_v2")
        defaults.removeObject(forKey: Self.legacyUnimplementedReadPathsKey)
        unimplementedReadPathExpirations = expirations
        unimplementedReadPaths = Set(expirations.keys)
        defaults.set(expirations.mapValues(\.timeIntervalSince1970),
                     forKey: Self.unimplementedReadPathsKey)
    }


    func fetchBattery(vin: String, accessToken: String) async throws -> GrpcBatteryExtras {

        var message = Data()
        message.append(Protobuf.stringField(1, UUID().uuidString))
        message.append(Protobuf.stringField(2, vin))
        let body = try await firstMessage(path: batteryPath, message: message,
                                          vin: vin, accessToken: accessToken)
        do {
            guard let batteryBytes = try Self.responsePayload(body) else {
                throw PolestarError.invalidResponse(operation: "gRPC battery")
            }
            return try Self.parseBattery(batteryBytes)
        } catch is Protobuf.DecodeError {
            throw PolestarError.invalidResponse(operation: "malformed gRPC battery")
        }
    }

    /// The `GetLatest*` / Chronos response envelope `{1: id, 2: vin, 3: payload}`: returns the
    /// payload, or nil when the envelope is valid but carries none.
    static func responsePayload(_ body: Data) throws -> Data? {
        try ProtoMessage(body).bytes(3)
    }

    /// Wire fields of the availability payload whose meaning is decoded. Everything else is
    /// captured raw by `fetchAvailabilityReport`.
    static let decodedAvailabilityFields: Set<Int> = [1, 3, 4]

    func fetchAvailabilityReport(vin: String, accessToken: String) async throws -> GrpcAvailabilityReport {
        var message = Data()
        message.append(Protobuf.stringField(1, UUID().uuidString))
        message.append(Protobuf.stringField(2, vin))
        let body = try await firstMessage(path: availabilityPath, message: message,
                                          vin: vin, accessToken: accessToken)
        return Self.parseAvailabilityReport(body)
    }

    /// A malformed reply reads as `.unknown`, never as a partial availability.
    static func parseAvailabilityReport(_ body: Data) -> GrpcAvailabilityReport {
        let unknown = GrpcAvailabilityReport(availability: .unknown, reportedAt: nil, unknownFields: [])
        let message: ProtoMessage
        let reportedAt: Date?
        do {
            guard let payload = try responsePayload(body) else { return unknown }
            message = try ProtoMessage(payload)
            reportedAt = try message.timestamp(1)
        } catch {
            return unknown
        }
        let value: VehicleAvailability
        switch message.uint(3) {
        case 1: value = .available
        case 2: value = .unavailable(reason: unavailableReason(message.uint(4)))
        default: value = .unknown
        }
        let unknownFields = message.fields
            .filter { !decodedAvailabilityFields.contains($0.number) }
            .map(rawField)
        return GrpcAvailabilityReport(availability: value, reportedAt: reportedAt,
                                      unknownFields: unknownFields)
    }

    func fetchTargetSoc(vin: String, accessToken: String) async throws -> Int? {
        var chronos = Data()
        chronos.append(Protobuf.stringField(1, UUID().uuidString))
        chronos.append(Protobuf.stringField(2, vin))
        chronos.append(Protobuf.stringField(3, "RCS"))
        let offset = TimeZone.current.secondsFromGMT() / 60
        chronos.append(Protobuf.messageField(4, Protobuf.intField(1, offset)))
        let request = Protobuf.messageField(1, chronos)
        let body = try await firstMessage(path: targetSocPath, message: request,
                                          vin: vin, accessToken: accessToken, host: .pccs)
        return Self.parseTargetSoc(body)
    }

    /// nil (unknown) for a missing, out-of-range or malformed reply.
    static func parseTargetSoc(_ body: Data) -> Int? {
        guard let payload = try? responsePayload(body),
              let level = (try? ProtoMessage(payload))?.uint(1),
              level > 0, level <= 100 else { return nil }
        return Int(level)
    }

    func fetchAmpLimit(vin: String, accessToken: String) async throws -> Int? {
        let request = Self.chronosRequest(vin)
        let body = try await firstMessage(path: ampLimitReadPath, message: request,
                                          vin: vin, accessToken: accessToken, host: .pccs)
        return Self.fetchAmpLimitResponse(body)
    }


    /// nil (unknown) for a missing, out-of-range or malformed reply.
    static func fetchAmpLimitResponse(_ body: Data) -> Int? {
        guard let payload = try? responsePayload(body),
              let limit = (try? ProtoMessage(payload))?.uint(1),
              limit > 0, limit <= 64 else { return nil }
        return Int(limit)
    }


    /// The C3 host from the discovery document, or nil when the document does not carry a
    /// usable one. The host is checked as a bare DNS name so a malformed value cannot smuggle
    /// a path, credentials or another scheme into the request URL.
    static func c3URL(fromDiscovery data: Data) -> URL? {
        struct Discovery: Decodable {
            struct Endpoint: Decodable {
                let grpcHost: String
                let grpcPort: Int
            }
            let c3: Endpoint
        }
        guard let endpoint = (try? JSONDecoder().decode(Discovery.self, from: data))?.c3,
              (1...65_535).contains(endpoint.grpcPort),
              !endpoint.grpcHost.isEmpty,
              endpoint.grpcHost.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = endpoint.grpcHost
        components.port = endpoint.grpcPort
        return components.url
    }

    private func c3Host(accessToken: String) async throws -> URL {
        if let cached = c3BaseURL, let expiry = c3HostExpiry, expiry > Date() { return cached }
        if let c3DiscoveryTask { return try await c3DiscoveryTask.task.value }
        let discoveryURL = discoveryURL
        let session = session
        let diagnosticLog = diagnosticLog
        // Nothing may suspend between the single-flight check above and the assignment below.
        // An `await` in that window lets every concurrent reader (a telemetry fan-out is a dozen
        // at once) pass the check before any of them publishes a task, so each starts its own
        // discovery request and all but the last hit the `c3DiscoveryTask?.id` guard below as a
        // spurious `CancellationError`. The second grant is therefore resolved *inside* the task.
        let task = Task<URL, Error> {
            // The app/command grant is a second audience for the same IdP. Discovery answers 406
            // when the presented grant is not the one the endpoint expects, so the retry ladder
            // spans grant as well as Accept version.
            let alternateToken = await self.alternateAccessTokenProvider?()
            // The discovery document is version-dependent through the Accept header: v2 also
            // advertises the undocumented `vca-api-gateway` host, v3 answers 406, and a plain
            // `application/json` Accept returns a different shape entirely. A version-shape or
            // audience rejection (4xx or an unexpected body) retries; auth, network,
            // rate-limit, and server failures fail for every attempt alike and surface
            // immediately.
            let versions = ["application/volvo.cloud.cnepmob.v2+json",
                            "application/volvo.cloud.cnepmob.v1+json"]
            var tokens = [accessToken]
            if let alternateToken, !alternateToken.isEmpty, alternateToken != accessToken {
                tokens.append(alternateToken)
            }
            // Version first, then grant: the normal case resolves on the first grant's v1 and
            // never presents the second one.
            var attempts: [(token: String, accept: String)] = []
            for token in tokens {
                for accept in versions { attempts.append((token, accept)) }
            }
            var lastError: Error = PolestarError.invalidResponse(operation: "C3 discovery")
            for (index, attempt) in attempts.enumerated() {
                let isLast = index == attempts.count - 1
                var request = URLRequest(url: discoveryURL)
                request.setValue(attempt.accept, forHTTPHeaderField: "Accept")
                request.setValue("Bearer \(attempt.token)", forHTTPHeaderField: "Authorization")
                do {
                    // A rejection that a later attempt can clear is the fallback working as
                    // designed, not a failure. Classify it so a support export does not report
                    // one error per launch for a request that then succeeds.
                    let classifier: (@Sendable (Data, Int) -> String?)? =
                        isLast ? nil : Self.expectedDiscoveryRetry
                    let (data, response) = try await HTTPExchange.data(
                        for: request, using: session, limit: 256_000, operation: "C3 discovery",
                        provider: .polestar, diagnosticLog: diagnosticLog,
                        semanticError: classifier
                    )
                    if let failure = PolestarError.httpFailure(
                        statusCode: response.statusCode, operation: "C3 discovery"
                    ) { throw failure }
                    guard let url = Self.c3URL(fromDiscovery: data) else {
                        throw PolestarError.incompatibleAPI(operation: "C3 discovery (\(attempt.accept))")
                    }
                    return url
                } catch let error as PolestarError {
                    lastError = error
                    switch error {
                    case .client, .incompatibleAPI:
                        if !isLast { continue }
                        throw error
                    default:
                        throw error
                    }
                } catch {
                    // A body JSONSerialization could not parse is a shape mismatch: the older
                    // version still gets a try before this becomes the surfaced error.
                    lastError = error
                    if !isLast { continue }
                    throw error
                }
            }
            throw lastError
        }
        let requestID = UUID()
        c3DiscoveryTask = PolestarInFlightRequest(id: requestID, task: task)
        defer {
            if c3DiscoveryTask?.id == requestID { c3DiscoveryTask = nil }
        }
        let url: URL
        do {
            url = try await task.value
        } catch {
            // Sign-out clears `c3BaseURL`, so a stale host is only reused within one session.
            guard !(error is CancellationError), let stale = c3BaseURL,
                  c3DiscoveryTask?.id == requestID else { throw error }
            c3HostExpiry = Date().addingTimeInterval(Self.discoveryRetryDelay)
            return stale
        }
        guard c3DiscoveryTask?.id == requestID else { throw CancellationError() }
        c3BaseURL = url
        c3HostExpiry = Date().addingTimeInterval(Self.discoveredHostLifetime)
        return url
    }

    func invalidateDiscoveredHost() {
        c3BaseURL = nil
        c3HostExpiry = nil
        c3DiscoveryTask?.task.cancel()
        c3DiscoveryTask = nil
        // Session-scoped caches must not survive a sign-out: a different account signing in
        // on the same app instance must never inherit the previous account's OTA ids, states,
        // or vehicle-advertised charging limits.
        otaSoftwareIDs = [:]
        otaSoftwareStates = [:]
        otaRawSoftwareStates = [:]
        capabilityLimits = [:]
        exteriorCache = [:]
        locationInFlight.values.forEach { $0.task.cancel() }
        chargeLocationsInFlight.values.forEach { $0.task.cancel() }
        locationInFlight.removeAll()
        chargeLocationsInFlight.removeAll()
        // Negative service capabilities survive host rediscovery and relaunch. A provider
        // service that is not deployed should not be probed once per process forever.
    }


    /// The one request shape for every C3 and PCCS call: unary reads, commands and live
    /// streams. The headers match what the official app's grpc-java client sends, with
    /// `grpc-accept-encoding: identity` so the server answers with uncompressed frames.
    static func grpcRequest(base: URL, path: String, message: Data,
                            vin: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("trailers", forHTTPHeaderField: "TE")
        request.setValue("identity", forHTTPHeaderField: "grpc-accept-encoding")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.httpBody = Protobuf.grpcFrame(message)
        return request
    }

    func resolvedHost(_ host: GRPCHost, accessToken: String) async throws -> URL {
        switch host {
        case .c3: return try await c3Host(accessToken: accessToken)
        case .pccs: return pccsURL
        }
    }



    func firstMessage(path: String, message: Data, vin: String,
                      accessToken: String, host: GRPCHost = .c3) async throws -> Data {
        try Task.checkCancellation()
        let base = try await resolvedHost(host, accessToken: accessToken)
        if isReadPathUnimplemented(path, vin: vin, base: base) {
            throw PolestarError.grpcUnimplemented(service: path.split(separator: "/").first.map(String.init) ?? path)
        }
        var request = Self.grpcRequest(base: base, path: path, message: message,
                                       vin: vin, accessToken: accessToken)
        // PCCS Chronos reads normally answer in well under a second. The 10 s session budget
        // let one hung optional capability stall the whole telemetry sweep, so cap those reads
        // tighter: the sweep fails fast and `optionalCapability` backs the service off instead
        // of everyone waiting on it.
        if host == .pccs { request.timeoutInterval = 6 }

        let startedAt = Date()
        var httpStatus: Int?
        var grpcStatus: String?
        var grpcMessage: String?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "gRPC")
            }
            httpStatus = http.statusCode
            grpcStatus = http.value(forHTTPHeaderField: "grpc-status")
            grpcMessage = http.value(forHTTPHeaderField: "grpc-message")

            // Status checks come before frame parsing: a Trailers-Only rejection carries
            // its real status in headers with no body, and reporting it as "truncated
            // frame" would hide the one piece of information that explains the failure.
            if http.statusCode == 401 || http.statusCode == 403 {
                throw PolestarError.authenticationRequired(.expiredSession)
            }
            if let failure = PolestarError.httpFailure(
                statusCode: http.statusCode, retryAfter: ServiceResponseClassifier.retryAfter(from: http), operation: path
            ) { throw failure }
            if let grpcStatus, grpcStatus != "0" {
                throw readStatusFailure(status: grpcStatus, message: grpcMessage,
                                        path: path, vin: vin, base: base)
            }

            var reader = GRPCFrameReader(context: "gRPC")
            var frame: Data?
            for try await byte in bytes {
                if let complete = try reader.consume(byte) {
                    frame = complete
                    break
                }
            }
            guard let body = frame else {
                throw PolestarError.invalidResponse(operation: "truncated gRPC frame")
            }

            await diagnosticLog.record(
                provider: .polestar, request: request,
                operation: "gRPC \(path)",
                grpcStatus: grpcStatus, grpcMessage: grpcMessage,
                statusCode: http.statusCode, responseBytes: body.count,
                responseData: body, startedAt: startedAt
            )
            return body
        } catch {
            // Exactly one record per attempt: failures carry whatever HTTP/gRPC status
            // made it back before the failure. The success-path record above returns
            // immediately, so nothing reaches here twice.
            await diagnosticLog.record(
                provider: .polestar, request: request,
                operation: "gRPC \(path)",
                grpcStatus: grpcStatus, grpcMessage: grpcMessage,
                statusCode: httpStatus, startedAt: startedAt, error: error
            )
            throw error
        }
    }


    /// Turns a non-zero gRPC status on a write RPC into something the user can act on.
    /// Previously every status except 12 and 16 collapsed into "returned an unexpected
    /// response", which hid the one piece of information that explains the failure.
    /// `grpc-message` is percent-encoded per the gRPC HTTP/2 spec.
    static func commandError(status: String, message: String?, path: String) -> Error {
        let detail = message?.removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        let service = path.split(separator: "/").first.map(String.init) ?? path
        switch status {
        case "3":  // INVALID_ARGUMENT
            return RemoteCommandError.rejected(detail ?? L10n.text("The vehicle service rejected the request as invalid."))
        case "5":  // NOT_FOUND
            return RemoteCommandError.rejected(detail ?? L10n.text("The vehicle service has no such update to act on."))
        case "7":  // PERMISSION_DENIED
            return RemoteCommandError.rejected(detail ?? L10n.text("Your Polestar account is not permitted to run this command."))
        case "9":  // FAILED_PRECONDITION
            return RemoteCommandError.rejected(detail ?? L10n.text("The vehicle is not in a state where this command can run right now."))
        case "12": // UNIMPLEMENTED
            return PolestarError.grpcUnimplemented(service: service)
        case "14": // UNAVAILABLE
            return PolestarError.grpcUnavailable(service: service)
        case "16": // UNAUTHENTICATED
            return RemoteCommandError.rejected(detail ?? L10n.text("Polestar cloud backend requires official mobile app pairing for remote commands."))
        default:
            let base = L10n.format("The vehicle service refused the command (gRPC status %@).", status)
            return RemoteCommandError.rejected(detail.map { "\(base) \($0)" } ?? base)
        }
    }

    func lastMessage(path: String, message: Data, vin: String,
                     accessToken: String, host: GRPCHost = .c3) async throws -> Data {
        let base = try await resolvedHost(host, accessToken: accessToken)
        let request = Self.grpcRequest(base: base, path: path, message: message,
                                       vin: vin, accessToken: accessToken)

        let startedAt = Date()
        var httpStatus: Int?
        var grpcStatus: String?
        var grpcMessage: String?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "gRPC command")
            }
            httpStatus = http.statusCode
            grpcStatus = http.value(forHTTPHeaderField: "grpc-status")
            grpcMessage = http.value(forHTTPHeaderField: "grpc-message")

            if http.statusCode == 401 || http.statusCode == 403 {
                throw PolestarError.authenticationRequired(.expiredSession)
            }
            guard http.statusCode == 200 else { throw PolestarError.server(statusCode: http.statusCode) }
            if let grpcStatus, grpcStatus != "0" {
                throw Self.commandError(status: grpcStatus,
                                        message: grpcMessage,
                                        path: path)
            }

            var reader = GRPCFrameReader(context: "gRPC command")
            var latest: Data?
            var frameCount = 0
            var endedByTimeout = false
            var cappedByFrameLimit = false
            do {
                for try await byte in bytes {
                    guard let frame = try reader.consume(byte) else { continue }
                    latest = frame
                    if frame.isEmpty { continue }
                    frameCount += 1
                    guard frameCount < 32 else {
                        // The frame cap is a runaway-stream safety valve; the frames read
                        // so far are valid, so return the last one rather than reporting
                        // the command as refused.
                        cappedByFrameLimit = true
                        break
                    }
                }
            } catch let error as URLError where error.code == .timedOut && latest != nil {
                endedByTimeout = true
            }
            guard let latest, !reader.isReadingBody || endedByTimeout || cappedByFrameLimit else {
                // 200 OK with no message frame is how a *late* gRPC rejection reaches us: the
                // server opened the response, then put its real status in HTTP/2 trailers, which
                // URLSession does not expose. An immediate rejection arrives as Trailers-Only and
                // is caught above by the `grpc-status` header, so reaching here means the command
                // was refused for a reason the transport is hiding. Say that, rather than
                // reporting a generic malformed-response error.
                throw RemoteCommandError.rejected(
                    L10n.text("The vehicle service refused the command without giving a reason. This usually means the vehicle is not currently able to run it.")
                )
            }
            await diagnosticLog.record(
                provider: .polestar, request: request,
                operation: "gRPC \(path)",
                grpcStatus: grpcStatus, grpcMessage: grpcMessage,
                statusCode: http.statusCode, responseBytes: latest.count,
                responseData: latest, startedAt: startedAt
            )
            return latest
        } catch {
            await diagnosticLog.record(
                provider: .polestar, request: request,
                operation: "gRPC \(path)",
                grpcStatus: grpcStatus, grpcMessage: grpcMessage,
                statusCode: httpStatus, startedAt: startedAt, error: error
            )
            throw error
        }
    }


    /// Wire fields of the battery message whose meaning is not yet established. Kept in one
    /// place so the unknown-field capture and the coverage doc stay in agreement.
    static let unmappedBatteryFields: Set<Int> = [8, 12, 14, 15, 20, 21, 22, 23, 24, 25, 27, 28]

    /// Battery message field numbers. The decoded set and `unmappedBatteryFields` together are
    /// everything this parser knows about the message.
    enum BatteryField {
        static let reportedAt = 1             // Timestamp
        static let percentage = 2             // double
        static let averageConsumption = 3     // double
        static let rangeKm = 4
        static let minutesToFull = 5
        static let chargerConnection = 6      // enum, chargerConnectionByWire
        static let chargingState = 7          // enum, chargingStateByWire
        static let minutesToTarget = 9
        static let powerWatts = 10
        static let currentAmps = 11
        static let capacityKwh = 12           // double; live-observed, kept unfiltered
        static let averageSinceCharge = 13    // double
        static let energySinceChargeWh = 16   // double
        static let chargingType = 17          // enum, chargingTypeByWire
        static let voltageVolts = 18
        static let minutesToMinimumSOC = 19
        static let chargerPowerState = 26     // enum, chargerPowerStateByWire
    }

    static let chargerConnectionByWire: [UInt64: ChargerConnection] = [
        1: .connected, 2: .disconnected, 3: .fault
    ]
    static let chargingTypeByWire: [UInt64: ChargingType] = [
        1: ChargingType.none, 2: .ac, 3: .dc, 4: .wireless
    ]
    static let chargerPowerStateByWire: [UInt64: ChargerPowerState] = [
        1: .noPower, 2: .initializing, 3: .available, 4: .providingPower, 5: .fault
    ]
    /// Matched by value, never by position, so a value the backend adds or reorders cannot
    /// relabel a known state. An unlisted value passes through as its number and surfaces as
    /// `ChargingState.unknown(rawValue)` instead of vanishing.
    static let chargingStateByWire: [UInt64: String] = [
        0: "UNSPECIFIED", 1: "CHARGING", 2: "IDLE", 3: "SCHEDULED", 4: "DISCHARGING",
        5: "ERROR", 6: "SMART_CHARGING", 7: "DONE", 8: "SMART_CHARGING_PAUSED"
    ]

    /// Throws on a malformed payload rather than returning a partial battery that would read
    /// as a real charging state.
    static func parseBattery(_ data: Data) throws -> GrpcBatteryExtras {
        let message = try ProtoMessage(data)
        func positive<T: Comparable & Numeric>(_ value: T?) -> T? { value.flatMap { $0 > 0 ? $0 : nil } }

        let unknownFields = message.fields
            .filter { field in
                unmappedBatteryFields.contains(field.number)
                    && !(field.number == BatteryField.capacityKwh && field.wire == 1)
            }
            .map(rawField)

        return GrpcBatteryExtras(
            reportedAt: try message.timestamp(BatteryField.reportedAt),
            batteryPercentage: message.double(BatteryField.percentage),
            rangeKm: message.int(BatteryField.rangeKm),
            estimatedChargingTimeToFullMinutes: message.int(BatteryField.minutesToFull),
            chargingState: message.uint(BatteryField.chargingState).map {
                ChargingState(apiValue: chargingStateByWire[$0] ?? String($0))
            },
            chargerConnection: message.uint(BatteryField.chargerConnection)
                .flatMap { chargerConnectionByWire[$0] } ?? .unknown,
            chargingType: message.uint(BatteryField.chargingType)
                .flatMap { chargingTypeByWire[$0] } ?? .unknown,
            chargingPowerWatts: message.int(BatteryField.powerWatts),
            chargingCurrentAmps: message.int(BatteryField.currentAmps),
            chargingVoltageVolts: message.int(BatteryField.voltageVolts),
            diagnostics: BatteryDiagnostics(
                timeToTargetMinutes: positive(message.int(BatteryField.minutesToTarget)),
                timeToMinimumSOCMinutes: positive(message.int(BatteryField.minutesToMinimumSOC)),
                chargerPowerState: message.uint(BatteryField.chargerPowerState)
                    .flatMap { chargerPowerStateByWire[$0] } ?? .unknown,
                averageConsumption: positive(message.double(BatteryField.averageConsumption)),
                averageConsumptionSinceCharge: positive(message.double(BatteryField.averageSinceCharge)),
                energyUsedSinceChargeWh: positive(message.double(BatteryField.energySinceChargeWh))
            ),
            reportedBatteryCapacityKwh: positive(message.double(BatteryField.capacityKwh)),
            unknownFields: unknownFields
        )
    }

    /// Preserves an undecoded field as inspectable text: scalars as their value, wire-type 2
    /// as a hex dump. Nothing here is interpreted; this exists so live captures can be
    /// classified later and so support bundles show what the backend actually sent.
    static func rawField(_ field: Protobuf.Field) -> VehicleRawWireField {
        switch field.wire {
        case 0:
            return VehicleRawWireField(field: field.number, wire: field.wire,
                                value: String(field.varint), isBinary: false)
        case 1:
            return VehicleRawWireField(field: field.number, wire: field.wire,
                                value: String(describing: Protobuf.double(from: field.data) ?? 0),
                                isBinary: false)
        case 5:
            return VehicleRawWireField(field: field.number, wire: field.wire,
                                value: String(describing: Protobuf.float(from: field.data) ?? 0),
                                isBinary: false)
        default:
            let hex = field.data.map { String(format: "%02x", $0) }.joined()
            return VehicleRawWireField(field: field.number, wire: field.wire, value: hex, isBinary: true)
        }
    }

    private static func unavailableReason(_ value: UInt64?) -> String? {
        switch value {
        case 1: return L10n.text("No vehicle connection")
        case 2: return L10n.text("Power saving")
        case 3: return L10n.text("Vehicle in use")
        case 4: return L10n.text("Software update in progress")
        case 5: return L10n.text("Tracking in progress")
        case 6: return L10n.text("Service mode")
        // Transport-level value observed in live captures; shown raw so it stays visible.
        case 7: return L10n.text("Transport error")
        default:
            // An unmapped reason is preserved as its number rather than dropped, so a new
            // backend value is diagnosable instead of rendering as "just unavailable".
            if let value, value > 6 {
                return L10n.format("Unknown reason (%d)", Int(value))
            }
            return nil
        }
    }
}


/// Splits a gRPC response body into its length-prefixed messages: a flag byte, a 4-byte
/// big-endian length, then the message. Fed one byte at a time because that is how
/// `URLSession.AsyncBytes` delivers them; the body buffer is reserved up front so a large
/// frame is not regrown byte by byte.
struct GRPCFrameReader {
    static let maxFrameBytes = 2_000_000

    /// Names the call in errors: "compressed \(context) frame".
    let context: String
    private var header: [UInt8] = []
    private var body: [UInt8] = []
    private var expected: Int?

    init(context: String) {
        self.context = context
        header.reserveCapacity(5)
    }

    /// True between a complete header and the end of its message.
    var isReadingBody: Bool { expected != nil }

    /// Returns a message when `byte` completes one, including an empty message.
    mutating func consume(_ byte: UInt8) throws -> Data? {
        if let size = expected {
            body.append(byte)
            return body.count == size ? finishFrame() : nil
        }
        header.append(byte)
        guard header.count == 5 else { return nil }
        // Requests advertise `grpc-accept-encoding: identity`, so a compressed frame means
        // the server ignored it.
        guard header[0] == 0 else {
            throw PolestarError.incompatibleAPI(operation: "compressed \(context) frame")
        }
        let size = Int(header[1]) << 24 | Int(header[2]) << 16 | Int(header[3]) << 8 | Int(header[4])
        guard size <= Self.maxFrameBytes else {
            throw PolestarError.invalidResponse(operation: "oversized \(context) frame")
        }
        if size == 0 { return finishFrame() }
        expected = size
        body.reserveCapacity(size)
        return nil
    }

    private mutating func finishFrame() -> Data {
        let frame = Data(body)
        header.removeAll(keepingCapacity: true)
        body.removeAll(keepingCapacity: true)
        expected = nil
        return frame
    }
}

enum GRPCHost: Sendable {


    case c3


    case pccs
}

enum Protobuf {
    static func packedVarints(_ data: Data) -> [UInt64]? {
        var result: [UInt64] = []
        var value: UInt64 = 0
        var shift = 0
        for byte in data {
            guard shift < 64, shift != 63 || byte <= 1 else { return nil }
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                result.append(value)
                value = 0
                shift = 0
            } else {
                shift += 7
            }
        }
        return shift == 0 ? result : nil
    }

    struct Field {
        let number: Int
        let wire: Int

        let varint: UInt64

        let data: Data
    }

    static func varint(_ value: UInt64) -> Data {
        var v = value, out = Data()
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            out.append(byte)
        } while v != 0
        return out
    }


    static func stringField(_ number: Int, _ value: String) -> Data {
        let bytes = Data(value.utf8)
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(bytes.count)))
        out.append(bytes)
        return out
    }

    static func intField(_ number: Int, _ value: Int) -> Data {
        var out = varint(UInt64(number << 3))
        out.append(varint(UInt64(bitPattern: Int64(value))))
        return out
    }

    static func floatField(_ number: Int, _ value: Float) -> Data {
        var out = varint(UInt64(number << 3 | 5))
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
        return out
    }

    static func packedIntField(_ number: Int, _ values: [Int]) -> Data {
        var payload = Data()
        for value in values { payload.append(varint(UInt64(value))) }
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(payload.count)))
        out.append(payload)
        return out
    }

    static func messageField(_ number: Int, _ value: Data) -> Data {
        var out = varint(UInt64(number << 3 | 2))
        out.append(varint(UInt64(value.count)))
        out.append(value)
        return out
    }


    static func grpcFrame(_ message: Data) -> Data {
        var out = Data([0])
        let n = UInt32(message.count).bigEndian
        withUnsafeBytes(of: n) { out.append(contentsOf: $0) }
        out.append(message)
        return out
    }


    /// Why a payload failed strict decoding. `offset` is the byte where the bad field starts.
    enum DecodeError: Error, Equatable {
        case truncated(offset: Int)
        case invalidFieldNumber(offset: Int)
        case unsupportedWireType(Int, offset: Int)
    }

    /// Strict decode of one message level: any truncated or malformed field throws. Use this
    /// wherever a partial result could be shown as a real vehicle state.
    static func decode(_ data: Data) throws -> [Field] {
        let (fields, failure) = scan(data)
        if let failure { throw failure }
        return fields
    }

    /// Lenient decode: the fields read before the first malformed byte. Kept for parsers that
    /// have not moved to `decode` / `ProtoMessage` yet.
    static func fields(_ data: Data) -> [Field] {
        scan(data).fields
    }

    private static func scan(_ data: Data) -> (fields: [Field], failure: DecodeError?) {
        var fields: [Field] = []
        let base = data.startIndex
        let end = data.endIndex
        var i = base

        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < end, shift < 64 {
                let b = data[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < end {
            let start = i - base
            // Wire values are server-controlled: a tag or length varint beyond Int's range
            // must stop the parse, not trap.
            guard let tag = readVarint() else { return (fields, .truncated(offset: start)) }
            guard let number = Int(exactly: tag >> 3), number > 0 else {
                return (fields, .invalidFieldNumber(offset: start))
            }
            let wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return (fields, .truncated(offset: start)) }
                fields.append(Field(number: number, wire: 0, varint: v, data: Data()))
            case 1, 5:
                let width = wire == 1 ? 8 : 4
                guard end - i >= width else { return (fields, .truncated(offset: start)) }
                fields.append(Field(number: number, wire: wire, varint: 0, data: Data(data[i..<i + width])))
                i += width
            case 2:
                guard let len = readVarint(), let length = Int(exactly: len), length <= end - i else {
                    return (fields, .truncated(offset: start))
                }
                fields.append(Field(number: number, wire: 2, varint: 0, data: Data(data[i..<i + length])))
                i += length
            default:
                // Groups (3, 4) are proto2-only and never seen from these services.
                return (fields, .unsupportedWireType(wire, offset: start))
            }
        }
        return (fields, nil)
    }

    static func double(from data: Data) -> Double? {
        guard data.count == 8 else { return nil }
        let bytes = [UInt8](data)
        var bits: UInt64 = 0
        for (index, byte) in bytes.enumerated() {
            bits |= UInt64(byte) << UInt64(index * 8)
        }
        return Double(bitPattern: bits)
    }

    static func float(from data: Data) -> Float? {
        guard data.count == 4 else { return nil }
        let bytes = [UInt8](data)
        var bits: UInt32 = 0
        for (index, byte) in bytes.enumerated() {
            bits |= UInt32(byte) << UInt32(index * 8)
        }
        return Float(bitPattern: bits)
    }
}



/// One strictly decoded message level with wire-type-checked accessors. A field read with the
/// wrong wire type is absent rather than misread, and repeated scalars resolve to the last
/// occurrence, as proto3 specifies.
struct ProtoMessage {
    let fields: [Protobuf.Field]

    init(_ data: Data) throws {
        fields = try Protobuf.decode(data)
    }

    func field(_ number: Int, wire: Int) -> Protobuf.Field? {
        fields.last { $0.number == number && $0.wire == wire }
    }

    func uint(_ number: Int) -> UInt64? { field(number, wire: 0)?.varint }

    func int(_ number: Int) -> Int? { uint(number).flatMap { Int(exactly: $0) } }

    func double(_ number: Int) -> Double? {
        field(number, wire: 1).flatMap { Protobuf.double(from: $0.data) }
    }

    func bytes(_ number: Int) -> Data? { field(number, wire: 2)?.data }

    func message(_ number: Int) throws -> ProtoMessage? {
        try bytes(number).map(ProtoMessage.init)
    }

    /// Seconds of a nested `google.protobuf.Timestamp` (field 1 of the sub-message), nil when
    /// absent or zero.
    func timestamp(_ number: Int) throws -> Date? {
        guard let seconds = try message(number)?.uint(1), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}

/// The one `String.nilIfEmpty` helper for the gRPC files (previously three divergent copies).
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
