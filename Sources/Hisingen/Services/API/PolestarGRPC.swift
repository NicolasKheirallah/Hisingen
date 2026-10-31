

import Foundation

/// Availability, usage mode and the remaining raw wire context.
struct GrpcAvailabilityReport: Equatable, Sendable {
    let availability: VehicleAvailability
    let reportedAt: Date?
    let unknownFields: [VehicleRawWireField]
    var usageMode: String? = nil
}

typealias GrpcBatteryExtras = VehicleBatteryReading
typealias PolestarInFlightRequest<Value: Sendable> = InFlightRequest<Value>

/// One PCCS scalar read (charge target, current limit) with the payload fields the parser
/// did not consume kept raw. The write probes proved these services carry a payload status
/// enum (SetTargetSoc answered `{3: 3}`), so a Get payload can hold fields this build does
/// not decode; retaining them keeps a new backend field visible in diagnostics.
struct PCCSScalarRead: Equatable, Sendable {
    /// The decoded setting, nil for a missing, out-of-range or malformed reply.
    let value: Int?
    /// Payload fields other than the decoded field 1, empty when none were sent.
    let unknownFields: [VehicleRawWireField]
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
    var sessionGeneration: UInt64 = 0
    private var liveWorkers: [UUID: Task<Void, Never>] = [:]
    var softwareReadGeneration: [String: UInt64] = [:]
    var otaSoftwareIDs: [String: String] = [:]
    /// Backend-advertised charging bounds per VIN (`GetMyCars`), used to validate
    /// charge-target and amp-limit writes against what the vehicle actually supports.
    var capabilityLimits: [String: VehicleOTACapabilities] = [:]
    /// Last observed OTA state per VIN, used to check `InstallNow` preconditions before sending it.
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
            unimplementedReadPathExpirations[key] = now().addingTimeInterval(Self.unimplementedReadPathTTL)
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
        if let expiry = unimplementedReadPathExpirations[key], expiry > now() { return true }
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
        let generation = sessionGeneration
        let base = try await resolvedHost(.c3, accessToken: accessToken)
        guard generation == sessionGeneration else { throw CancellationError() }
        let requestBody = Self.stateRequest(vin: vin)
        let stream: (path: String, parse: @Sendable (Data) -> VehicleLiveUpdate?)
        switch purpose {
        case .charging:
            // A malformed frame is skipped; the next full snapshot replaces it.
            stream = (batteryStreamPath, { body in
                guard let payload = try? Self.responsePayload(body, expectedVIN: vin),
                      let battery = try? Self.parseBattery(payload) else { return nil }
                return .battery(battery)
            })
        case .exteriorConfirmation:
            stream = ("/services.vehiclestates.exterior.ExteriorService/GetExterior", { body in
                guard let payload = try? Self.responsePayload(body, expectedVIN: vin),
                      let exterior = Self.parseExterior(payload) else { return nil }
                return .exterior(exterior, reportedAt: nil)
            })
        }

        // `bufferingNewest` bounds memory if the UI consumer stalls while the push stream
        // stays chatty; dropping stale frames is correct because each frame is a full
        // snapshot, not a delta.
        let workerID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let worker = Task {
                defer { self.liveWorkers[workerID] = nil }
                do {
                    try await self.consumeLiveFrames(
                        base: base, path: stream.path,
                        message: requestBody, vin: vin, accessToken: accessToken, generation: generation,
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
            liveWorkers[workerID] = worker
            continuation.onTermination = { _ in worker.cancel() }
        }
    }

    private func consumeLiveFrames(
        base: URL, path: String, message: Data, vin: String, accessToken: String, generation: UInt64,
        onConnected: @escaping @Sendable () -> Void,
        onFrame: @escaping @Sendable (Data) -> Void
    ) async throws {
        let request = Self.grpcRequest(base: base, path: path, message: message,
                                       vin: vin, accessToken: accessToken)
        let state = PolestarGRPCExchangeState(maximumMessages: nil)
        let startedAt = now()
        do {
            try await transport.execute(for: request, live: true) { part in
                try Task.checkCancellation()
                try await self.requireGeneration(generation)
                try await state.record(part)
                switch part {
                case .headers(let head):
                    try Self.validateHead(head, operation: path)
                    onConnected()
                case .message(let body):
                    onFrame(body)
                case .status(let status):
                    if status.code != 0 {
                        throw Self.readStatusError(status: String(status.code), message: status.message, path: path)
                    }
                }
                return true
            }
            try requireGeneration(generation)
            let result = await state.snapshot()
            if transport.supportsTrailers, result.status == nil {
                throw PolestarError.invalidResponse(operation: "live gRPC missing final status")
            }
            await recordExchange(state: result, request: request, path: path, startedAt: startedAt)
        } catch {
            await recordExchange(state: await state.snapshot(), request: request, path: path,
                                 startedAt: startedAt, error: error)
            throw error
        }
    }

    private func requireGeneration(_ generation: UInt64) throws {
        try Task.checkCancellation()
        guard generation == sessionGeneration else { throw CancellationError() }
    }

    private static func validateHead(_ head: PolestarGRPCResponseHead, operation: String) throws {
        guard let code = head.httpStatus else { return }
        if code == 401 || code == 403 {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        if let error = PolestarError.httpFailure(statusCode: code,
                retryAfter: head.metadata["retry-after"].flatMap(TimeInterval.init), operation: operation) {
            throw error
        }
    }

    private func recordExchange(
        state: PolestarGRPCExchangeState.Snapshot, request: URLRequest, path: String,
        startedAt: Date, error: (any Error)? = nil
    ) async {
        await diagnosticLog.record(provider: .polestar, request: request, operation: "gRPC \(path)",
            grpcStatus: state.grpcCode, grpcMessage: state.grpcMessage,
            statusCode: state.head?.httpStatus, responseBytes: state.lastMessage?.count,
            responseData: state.lastMessage, startedAt: startedAt, error: error)
    }

    let session: URLSession
    private let transport: any PolestarGRPCTransport
    private let now: @Sendable () -> Date

    init(defaultsSuiteName: String? = nil, session: URLSession? = nil,
         diagnosticLog: APIDiagnosticLogStore = .shared,
         transport: (any PolestarGRPCTransport)? = nil,
         now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.diagnosticLog = diagnosticLog
        self.now = now
        let defaults = self.defaults
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        let requestSession = session ?? URLSession(configuration: config)
        self.session = requestSession
        if let transport {
            self.transport = transport
        } else if session != nil {
            self.transport = URLSessionPolestarGRPCTransport(requestSession: requestSession)
        } else {
            self.transport = PolestarHTTP2Transport()
        }
        let now = now()
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


    /// Request envelope shared by the vehicle-state services: a fresh request id in field 1, the
    /// VIN in field 2.
    static func stateRequest(vin: String) -> Data {
        Protobuf.stringField(1, UUID().uuidString) + Protobuf.stringField(2, vin)
    }

    func fetchBattery(vin: String, accessToken: String) async throws -> GrpcBatteryExtras {

        let body = try await firstMessage(path: batteryPath, message: Self.stateRequest(vin: vin),
                                          vin: vin, accessToken: accessToken)
        do {
            guard let batteryBytes = try Self.responsePayload(body, expectedVIN: vin) else {
                throw PolestarError.invalidResponse(operation: "gRPC battery")
            }
            return try Self.parseBattery(batteryBytes)
        } catch is Protobuf.DecodeError {
            throw PolestarError.invalidResponse(operation: "malformed gRPC battery")
        }
    }

    /// The `GetLatest*` / Chronos response envelope `{1: id, 2: vin, 3: payload}`: returns the
    /// payload, or nil when the envelope is valid but carries none.
    static func responsePayload(_ body: Data, expectedVIN: String? = nil) throws -> Data? {
        let envelope = try ProtoMessage(body)
        if let expectedVIN, envelope.fields.contains(where: { $0.number == 2 }) {
            guard let bytes = envelope.bytes(2),
                  let actualVIN = String(data: bytes, encoding: .utf8),
                  actualVIN.caseInsensitiveCompare(expectedVIN) == .orderedSame else {
                throw PolestarError.invalidResponse(operation: "gRPC vehicle identity")
            }
        }
        return envelope.bytes(3)
    }

    /// Wire fields of the availability payload whose meaning is decoded. Everything else is
    /// captured raw by `fetchAvailabilityReport`.
    static let decodedAvailabilityFields: Set<Int> = [1, 3, 4]

    static let usageModeByWire: [UInt64: String] = [
        1: "ABANDONED", 2: "INACTIVE", 3: "CONVENIENCE", 4: "ACTIVE",
        5: "DRIVING", 6: "ENGINE_ON", 7: "ENGINE_OFF"
    ]

    func fetchAvailabilityReport(vin: String, accessToken: String) async throws -> GrpcAvailabilityReport {
        let body = try await firstMessage(path: availabilityPath, message: Self.stateRequest(vin: vin),
                                          vin: vin, accessToken: accessToken)
        _ = try Self.responsePayload(body, expectedVIN: vin)
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
        let usageMode = message.uint(5).flatMap { usageModeByWire[$0] }
        let unknownFields = message.fields
            .filter { field in
                !decodedAvailabilityFields.contains(field.number)
                    && !(field.number == 5 && field.wire == 0 && usageModeByWire[field.varint] != nil)
            }
            .map(rawField)
        return GrpcAvailabilityReport(availability: value, reportedAt: reportedAt,
                                      unknownFields: unknownFields, usageMode: usageMode)
    }

    func fetchTargetSoc(vin: String, accessToken: String) async throws -> PCCSScalarRead {
        var chronos = Data()
        chronos.append(Protobuf.stringField(1, UUID().uuidString))
        chronos.append(Protobuf.stringField(2, vin))
        chronos.append(Protobuf.stringField(3, "RCS"))
        let offset = TimeZone.current.secondsFromGMT() / 60
        chronos.append(Protobuf.messageField(4, Protobuf.intField(1, offset)))
        let request = Protobuf.messageField(1, chronos)
        let body = try await firstMessage(path: targetSocPath, message: request,
                                          vin: vin, accessToken: accessToken, host: .pccs)
        _ = try Self.responsePayload(body, expectedVIN: vin)
        return Self.parseTargetSocRead(body)
    }

    /// nil (unknown) for a missing, out-of-range or malformed reply.
    static func parseTargetSoc(_ body: Data) -> Int? {
        guard let payload = try? responsePayload(body),
              let level = (try? ProtoMessage(payload))?.uint(1),
              level > 0, level <= 100 else { return nil }
        return Int(level)
    }

    /// Decodes the charge target and retains any other payload fields raw. Only field 1 is
    /// decoded; a payload that fails strict parsing retains nothing so no partial frame is
    /// shown as data.
    static func parseTargetSocRead(_ body: Data) -> PCCSScalarRead {
        PCCSScalarRead(value: parseTargetSoc(body),
                       unknownFields: retainedPayloadFields(body, decoded: 1))
    }

    /// Payload fields of a PCCS scalar read other than the decoded field number, in wire
    /// order. A malformed payload contributes nothing.
    static func retainedPayloadFields(_ body: Data, decoded number: Int) -> [VehicleRawWireField] {
        guard let payload = try? responsePayload(body),
              let message = try? ProtoMessage(payload) else { return [] }
        return message.fields.filter { $0.number != number }.map(rawField)
    }

    func fetchAmpLimit(vin: String, accessToken: String) async throws -> PCCSScalarRead {
        let request = Self.chronosRequest(vin)
        let body = try await firstMessage(path: ampLimitReadPath, message: request,
                                          vin: vin, accessToken: accessToken, host: .pccs)
        _ = try Self.responsePayload(body, expectedVIN: vin)
        return Self.parseAmpLimitRead(body)
    }


    /// nil (unknown) for a missing, out-of-range or malformed reply.
    static func fetchAmpLimitResponse(_ body: Data) -> Int? {
        guard let payload = try? responsePayload(body),
              let limit = (try? ProtoMessage(payload))?.uint(1),
              limit > 0, limit <= 64 else { return nil }
        return Int(limit)
    }

    /// Decodes the current limit and retains any other payload fields raw
    /// (see `parseTargetSocRead`).
    static func parseAmpLimitRead(_ body: Data) -> PCCSScalarRead {
        PCCSScalarRead(value: fetchAmpLimitResponse(body),
                       unknownFields: retainedPayloadFields(body, decoded: 1))
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
        if let cached = c3BaseURL, let expiry = c3HostExpiry, expiry > now() { return cached }
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
            c3HostExpiry = now().addingTimeInterval(Self.discoveryRetryDelay)
            return stale
        }
        guard c3DiscoveryTask?.id == requestID else { throw CancellationError() }
        c3BaseURL = url
        c3HostExpiry = now().addingTimeInterval(Self.discoveredHostLifetime)
        return url
    }

    func invalidateDiscoveredHost() {
        sessionGeneration &+= 1
        liveWorkers.values.forEach { $0.cancel() }
        liveWorkers.removeAll()
        c3BaseURL = nil
        c3HostExpiry = nil
        c3DiscoveryTask?.task.cancel()
        c3DiscoveryTask = nil
        // Session-scoped caches must not survive a sign-out: a different account signing in
        // on the same app instance must never inherit the previous account's OTA ids, states,
        // or vehicle-advertised charging limits.
        softwareReadGeneration = [:]
        otaSoftwareIDs = [:]
        otaSoftwareStates = [:]
        otaRawSoftwareStates = [:]
        capabilityLimits = [:]
        exteriorCache = [:]
        myCarsInFlight.values.forEach { $0.task.cancel() }
        myCarsInFlight.removeAll()
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
                      accessToken: String, host: GRPCHost = .c3,
                      completion: PolestarGRPCReadCompletion = .terminalStatus) async throws -> Data {
        try Task.checkCancellation()
        let generation = sessionGeneration
        let base = try await resolvedHost(host, accessToken: accessToken)
        try requireGeneration(generation)
        if isReadPathUnimplemented(path, vin: vin, base: base) {
            throw PolestarError.grpcUnimplemented(service: path.split(separator: "/").first.map(String.init) ?? path)
        }
        var request = Self.grpcRequest(base: base, path: path, message: message, vin: vin, accessToken: accessToken)
        if host == .pccs { request.timeoutInterval = 6 }
        let state = PolestarGRPCExchangeState()
        let startedAt = now()
        do {
            try await transport.execute(for: request, live: false) { part in
                try await self.requireGeneration(generation)
                try await state.record(part)
                switch part {
                case .headers(let head):
                    try Self.validateHead(head, operation: path)
                case .message(let body):
                    try Self.validateResponse(body, path: path)
                    if completion == .firstSnapshot { return false }
                case .status(let status):
                    if status.code != 0 {
                        throw await self.readStatusFailure(status: String(status.code), message: status.message,
                                                          path: path, vin: vin, base: base)
                    }
                }
                return true
            }
            try requireGeneration(generation)
            let result = await state.snapshot()
            if transport.supportsTrailers, completion == .terminalStatus, result.status == nil {
                throw PolestarError.invalidResponse(operation: "gRPC missing final status")
            }
            guard let body = result.firstMessage else {
                throw PolestarError.invalidResponse(operation: "empty gRPC response")
            }
            await recordExchange(state: result, request: request, path: path, startedAt: startedAt)
            return body
        } catch {
            await recordExchange(state: await state.snapshot(), request: request, path: path,
                                 startedAt: startedAt, error: error)
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
            return PolestarError.commandOutcomeUnknown(operation: path)
        }
    }

    /// gRPC `DEADLINE_EXCEEDED`.
    static let deadlineExceededStatus = 4
    /// How long a command waits for the backend to close its stream after replying.
    static let commandDeadline: TimeInterval = 15

    func lastMessage(path: String, message: Data, vin: String,
                     accessToken: String, host: GRPCHost = .c3) async throws -> Data {
        try Task.checkCancellation()
        let generation = sessionGeneration
        let base = try await resolvedHost(host, accessToken: accessToken)
        try requireGeneration(generation)
        var request = Self.grpcRequest(base: base, path: path, message: message, vin: vin, accessToken: accessToken)
        request.timeoutInterval = Self.commandDeadline
        let state = PolestarGRPCExchangeState()
        let startedAt = now()
        do {
            do {
                try await transport.execute(for: request, live: false) { part in
                    try await self.requireGeneration(generation)
                    try await state.record(part)
                    switch part {
                    case .headers(let head): try Self.validateHead(head, operation: path)
                    case .message(let body): _ = try Protobuf.decode(body)
                    case .status(let status):
                        let replied = await state.snapshot().lastMessage != nil
                        if status.code != 0, !(status.code == Self.deadlineExceededStatus && replied) {
                            throw Self.commandError(status: String(status.code), message: status.message, path: path)
                        }
                    }
                    return true
                }
            } catch let error as URLError where error.code == .timedOut && !transport.supportsTrailers {
                guard await state.snapshot().lastMessage != nil else { throw error }
            }
            try requireGeneration(generation)
            let result = await state.snapshot()
            // Climate and charge-target commands answer, then keep the stream open until the
            // client gives up (logged successes ended at 10-15 s). The reply message carries the
            // command status, so a deadline that fires after it only means no closing status
            // arrived; with no reply at all the outcome is still unknown.
            let closedByDeadline = result.status?.code == Self.deadlineExceededStatus && result.lastMessage != nil
            guard let body = result.lastMessage,
                  !transport.supportsTrailers || result.status?.code == 0 || closedByDeadline else {
                throw PolestarError.commandOutcomeUnknown(operation: path)
            }
            await recordExchange(state: result, request: request, path: path, startedAt: startedAt)
            return body
        } catch {
            let snapshot = await state.snapshot()
            let finalError: any Error
            if snapshot.status != nil || error is CancellationError
                || error is RemoteCommandError || (snapshot.head?.httpStatus.map { $0 != 200 } ?? false) {
                finalError = error
            } else {
                finalError = PolestarError.commandOutcomeUnknown(operation: path)
            }
            await recordExchange(state: snapshot, request: request, path: path, startedAt: startedAt, error: finalError)
            throw finalError
        }
    }

    /// Unlisted tags remain raw.
    static let decodedBatteryFields: Set<Int> = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 26, 28]

    /// Accepted field identities; unsupported encodings of the new fields remain raw.
    enum BatteryField {
        static let reportedAt = 1             // Timestamp
        static let percentage = 2             // double
        static let averageConsumption = 3     // double
        static let rangeKm = 4
        static let minutesToFull = 5
        static let chargerConnection = 6      // enum, chargerConnectionByWire
        static let chargingState = 7          // enum, chargingStateByWire
        static let rangeMiles = 8
        static let minutesToTarget = 9
        static let powerWatts = 10
        static let currentAmps = 11
        static let averageAutomatic = 12
        static let averageSinceCharge = 13    // double
        static let energyManualTripWh = 14
        static let energyAutomaticTripWh = 15
        static let energySinceChargeWh = 16   // double
        static let chargingType = 17          // enum, chargingTypeByWire
        static let voltageVolts = 18
        static let minutesToMinimumSOC = 19
        static let chargerPowerState = 26     // enum, chargerPowerStateByWire
        static let chargingStateV2 = 28
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
        5: "ERROR", 6: "SMART_CHARGING", 7: "SMART_CHARGING_PAUSED", 8: "DONE"
    ]

    static let chargingStateV2ByWire: [UInt64: String] = [
        1: "CHARGING", 2: "CHARGE_LEVEL_IS_GOOD_TO_GO", 3: "CHARGING_IS_EN_ROUTE",
        4: "CHARGING_TOWARDS_MIN_SOC", 5: "IDLE", 6: "SCHEDULED",
        7: "SCHEDULED_CHARGING_CANNOT_COMPLETE", 8: "SCHEDULED_CHARGING_WILL_COMPLETE",
        9: "DISCHARGING", 10: "DISCHARGING_V2H", 11: "DISCHARGING_V2L",
        12: "SMART_CHARGING", 13: "SMART_CHARGING_PAUSED", 14: "SMART_CHARGING_WILL_NOT_FINISH",
        15: "ERROR", 16: "DONE"
    ]

    /// Throws on a malformed payload rather than returning a partial battery that would read
    /// as a real charging state.
    static func parseBattery(_ data: Data) throws -> GrpcBatteryExtras {
        let message = try ProtoMessage(data)
        func positive<T: Comparable & Numeric>(_ value: T?) -> T? { value.flatMap { $0 > 0 ? $0 : nil } }

        func energy(_ number: Int) -> Double? {
            message.double(number).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
        let milesRangeKm = message.int(BatteryField.rangeMiles).flatMap { miles -> Int? in
            Int(exactly: (Double(miles) * 1.609344).rounded())
        }
        let manualEnergy = energy(BatteryField.energyManualTripWh)
        let automaticEnergy = energy(BatteryField.energyAutomaticTripWh)
        let automaticConsumption = energy(BatteryField.averageAutomatic)
        let v2 = message.uint(BatteryField.chargingStateV2)
        let chargingState: ChargingState? = if let v2, v2 != 0 {
            ChargingState(apiValue: chargingStateV2ByWire[v2] ?? String(v2))
        } else {
            message.uint(BatteryField.chargingState).map {
                ChargingState(apiValue: chargingStateByWire[$0] ?? String($0))
            }
        }

        let discharge = dischargeValues(message.fields)
        let preconditioning = manualPreconditioningReading(message.fields)

        let unknownFields = message.fields
            .filter { field in
                if remainingBatteryFields.contains(field.number) {
                    return !decodesRemainingBatteryField(field)
                }
                return !decodedBatteryFields.contains(field.number)
                    || (field.number == BatteryField.averageAutomatic && (field.wire != 1 || automaticConsumption == nil))
                    || (field.number == BatteryField.chargingStateV2 && (field.wire != 0 || (field.varint != 0 && chargingStateV2ByWire[field.varint] == nil)))
                    || (field.number == BatteryField.rangeMiles && (field.wire != 0 || milesRangeKm == nil))
                    || (field.number == BatteryField.energyManualTripWh && (field.wire != 1 || manualEnergy == nil))
                    || (field.number == BatteryField.energyAutomaticTripWh && (field.wire != 1 || automaticEnergy == nil))
            }
            .map(rawField)

        return GrpcBatteryExtras(
            reportedAt: try message.timestamp(BatteryField.reportedAt),
            batteryPercentage: message.double(BatteryField.percentage),
            rangeKm: message.int(BatteryField.rangeKm) ?? milesRangeKm,
            estimatedChargingTimeToFullMinutes: message.int(BatteryField.minutesToFull),
            chargingState: chargingState,
            chargerConnection: message.uint(BatteryField.chargerConnection)
                .flatMap { chargerConnectionByWire[$0] } ?? .unknown,
            chargingType: message.uint(BatteryField.chargingType)
                .flatMap { chargingTypeByWire[$0] } ?? .unknown,
            chargingPowerWatts: message.int(BatteryField.powerWatts),
            chargingCurrentAmps: message.int(BatteryField.currentAmps),
            chargingVoltageVolts: message.int(BatteryField.voltageVolts),
            diagnostics: BatteryDiagnostics(
                timeToTargetMinutes: nil,
                timeToMinimumSOCMinutes: positive(message.int(BatteryField.minutesToMinimumSOC)),
                timeToTargetDistanceMinutes: positive(message.int(BatteryField.minutesToTarget)),
                chargerPowerState: message.uint(BatteryField.chargerPowerState)
                    .flatMap { chargerPowerStateByWire[$0] } ?? .unknown,
                averageConsumption: positive(message.double(BatteryField.averageConsumption)),
                averageConsumptionSinceCharge: positive(message.double(BatteryField.averageSinceCharge)),
                averageConsumptionAutomatic: automaticConsumption,
                energyUsedSinceChargeWh: positive(message.double(BatteryField.energySinceChargeWh)),
                energyUsedManualTripWh: manualEnergy,
                energyUsedAutomaticTripWh: automaticEnergy,
                energyBreakdownByPeriod: energyByPeriod(message.fields),
                powerLimitKw: discharge?[3],
                energyAvailableKwh: discharge?[1],
                energyAvailableIncreaseKwh: discharge?[2],
                batteryPreconditioningStatus: preconditioning?.status,
                batteryPreconditioningEndsAt: preconditioning?.endsAt,
                coldBatteryStatus: coldBatteryStatus(message.fields)
            ),
            reportedBatteryCapacityKwh: nil,
            unknownFields: unknownFields
        )
    }

    /// Preserves an undecoded field as inspectable text: scalars as their value, wire-type 2
    /// as a decoded wire summary (`1: 1787835643`) when the bytes parse cleanly as a protobuf
    /// message, or a hex dump otherwise. Nothing here is interpreted semantically; this exists
    /// so live captures can be classified later and so support bundles show what the backend
    /// actually sent.
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
            if let summary = wireSummary(field.data, depth: 2) {
                return VehicleRawWireField(field: field.number, wire: field.wire,
                                           value: summary, isBinary: true)
            }
            let hex = field.data.map { String(format: "%02x", $0) }.joined()
            return VehicleRawWireField(field: field.number, wire: field.wire, value: hex, isBinary: true)
        }
    }

    /// One-level-per-call structural rendering of a length-delimited raw field: `number: value`
    /// for varints, `number: { … }` for nested messages, `number: {}` for empty ones. Returns
    /// nil for bytes that do not parse completely, that use fixed-width scalars the summary
    /// cannot represent, or that are a packed repeated scalar rather than a message; those keep
    /// their hex dump. A summary names the wire layout, never the meaning.
    static func wireSummary(_ data: Data, depth: Int) -> String? {
        guard !data.isEmpty, depth > 0, let fields = try? Protobuf.decode(data) else { return nil }
        var parts: [String] = []
        for field in fields {
            guard field.number > 0 else { return nil }
            switch field.wire {
            case 0:
                parts.append("\(field.number): \(field.varint)")
            case 2 where field.data.isEmpty:
                parts.append("\(field.number): {}")
            case 2:
                guard let nested = wireSummary(field.data, depth: depth - 1) else { return nil }
                parts.append("\(field.number): { \(nested) }")
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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


enum GRPCHost: Sendable {


    case c3


    case pccs
}

/// The one `String.nilIfEmpty` helper for the gRPC files (previously three divergent copies).
extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
