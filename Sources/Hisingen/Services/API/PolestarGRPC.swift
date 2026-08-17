

import Foundation


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
    private var c3DiscoveryTask: Task<URL, Error>?
    var exteriorCache: [String: ExteriorSnapshot] = [:]
    var otaSoftwareIDs: [String: String] = [:]
    /// Last observed OTA state per VIN. `InstallNow` is only meaningful for some of these, and
    /// the backend reports the rest in HTTP/2 trailers we cannot read — so the precondition is
    /// checked here instead of being discovered as an unexplained refusal.
    var otaSoftwareStates: [String: SoftwareUpdateState] = [:]
    /// Last observed raw OTA state per VIN, preserving the 15 vs 1 distinction.
    var otaRawSoftwareStates: [String: SoftwareStateRaw] = [:]
    /// When true, uses server-streaming gRPC methods (`GetBattery`, `GetExterior`) that the
    /// server keeps open and pushes updates over, instead of the one-shot `GetLatest*` methods.
    /// The streaming variants return the same first-frame data but may be fresher since the
    /// server expects an ongoing connection. Recovered from the official Polestar APK v5.10.0
    /// teardown — see `docs/api/ota-investigation.md` (E1).
    var useStreaming = false

    func setUseStreaming(_ enabled: Bool) { useStreaming = enabled }
    /// Token used for the current invocation-backed command, set by `executeRemoteCommand`.
    var activeCommandToken: String?
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
    }


    func fetchBattery(vin: String, accessToken: String) async throws -> GrpcBatteryExtras {

        var message = Data()
        message.append(Protobuf.stringField(1, UUID().uuidString))
        message.append(Protobuf.stringField(2, vin))
        let path = useStreaming ? batteryStreamPath : batteryPath
        let body = try await firstMessage(path: path, message: message,
                                          vin: vin, accessToken: accessToken)


        guard let batteryBytes = Protobuf.fields(body).first(where: { $0.number == 3 && $0.wire == 2 })?.data
        else { throw PolestarError.invalidResponse(operation: "gRPC battery") }
        return Self.parseBattery(batteryBytes)
    }

    func fetchAvailability(vin: String, accessToken: String) async throws -> VehicleAvailability {
        var message = Data()
        message.append(Protobuf.stringField(1, UUID().uuidString))
        message.append(Protobuf.stringField(2, vin))
        let body = try await firstMessage(path: availabilityPath, message: message,
                                          vin: vin, accessToken: accessToken)
        guard let availability = Protobuf.fields(body)
            .first(where: { $0.number == 3 && $0.wire == 2 })?.data else {
            return .unknown
        }
        let fields = Protobuf.fields(availability)
        let status = fields.first(where: { $0.number == 3 })?.varint
        let reason = fields.first(where: { $0.number == 4 })?.varint
        switch status {
        case 1: return .available
        case 2: return .unavailable(reason: Self.unavailableReason(reason))
        default: return .unknown
        }
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
        guard let target = Protobuf.fields(body)
            .first(where: { $0.number == 3 && $0.wire == 2 })?.data,
              let level = Protobuf.fields(target).first(where: { $0.number == 1 })?.varint,
              level > 0, level <= 100 else { return nil }
        return Int(level)
    }

    func fetchAmpLimit(vin: String, accessToken: String) async throws -> Int? {
        let request = Self.chronosEnvelope(vin: vin)
        let body = try await firstMessage(path: ampLimitReadPath, message: request,
                                          vin: vin, accessToken: accessToken, host: .pccs)
        return Self.fetchAmpLimitResponse(body)
    }


    static func fetchAmpLimitResponse(_ body: Data) -> Int? {
        guard let inner = Protobuf.fields(body).first(where: { $0.number == 3 && $0.wire == 2 })?.data,
              let limit = Protobuf.fields(inner).first(where: { $0.number == 1 && $0.wire == 0 })?.varint,
              limit > 0, limit <= 64 else { return nil }
        return Int(limit)
    }


    private func c3Host(accessToken: String) async throws -> URL {
        if let cached = c3BaseURL { return cached }
        if let c3DiscoveryTask { return try await c3DiscoveryTask.value }
        let discoveryURL = discoveryURL
        let session = session
        let task = Task<URL, Error> {
            var request = URLRequest(url: discoveryURL)
            request.setValue("application/volvo.cloud.cnepmob.v1+json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await HTTPBodyReader.data(
                for: request, using: session, limit: 256_000, operation: "C3 discovery"
            )
            guard let http = response as? HTTPURLResponse else {
                throw PolestarError.invalidResponse(operation: "C3 discovery")
            }
            if let failure = PolestarError.httpFailure(
                statusCode: http.statusCode, operation: "C3 discovery"
            ) { throw failure }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let c3 = json["c3"] as? [String: Any],
                  let host = c3["grpcHost"] as? String,
                  let port = c3["grpcPort"] as? Int,
                  let url = URL(string: "https://\(host):\(port)") else {
                throw PolestarError.invalidResponse(operation: "C3 discovery")
            }
            return url
        }
        c3DiscoveryTask = task
        defer { c3DiscoveryTask = nil }
        let url = try await task.value
        c3BaseURL = url
        return url
    }

    func invalidateDiscoveredHost() {
        c3BaseURL = nil
        c3DiscoveryTask?.cancel()
        c3DiscoveryTask = nil
    }


    func resolvedHost(_ host: GRPCHost, accessToken: String) async throws -> URL {
        switch host {
        case .c3: return try await c3Host(accessToken: accessToken)
        case .pccs: return pccsURL
        }
    }



    static func chronosEnvelope(vin: String, payload: Data = Data()) -> Data {
        var chronos = Data()
        chronos.append(Protobuf.stringField(1, UUID().uuidString))
        chronos.append(Protobuf.stringField(2, vin))
        chronos.append(Protobuf.stringField(3, "RCS"))
        chronos.append(Protobuf.messageField(4,
            Protobuf.intField(1, TimeZone.current.secondsFromGMT() / 60)))
        var request = Protobuf.messageField(1, chronos)
        request.append(payload)
        return request
    }

    func firstMessage(path: String, message: Data, vin: String,
                      accessToken: String, host: GRPCHost = .c3) async throws -> Data {
        let base = try await resolvedHost(host, accessToken: accessToken)
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.httpBody = Protobuf.grpcFrame(message)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolestarError.invalidResponse(operation: "gRPC")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        guard http.statusCode == 200 else {
            throw PolestarError.server(statusCode: http.statusCode)
        }
        if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
            throw PolestarError.invalidResponse(operation: "gRPC status \(status)")
        }

        var header = [UInt8]()
        var body = Data()
        var expected = -1
        for try await byte in bytes {
            if header.count < 5 {
                header.append(byte)
                if header.count == 5 {
                    guard header[0] == 0 else {
                        throw PolestarError.incompatibleAPI(operation: "compressed gRPC frame")
                    }
                    expected = Int(header[1]) << 24 | Int(header[2]) << 16
                        | Int(header[3]) << 8 | Int(header[4])
                    guard expected >= 0, expected <= 2_000_000 else {
                        throw PolestarError.invalidResponse(operation: "oversized gRPC frame")
                    }
                    if expected == 0 { break }
                }
                continue
            }
            body.append(byte)
            if body.count == expected { break }
        }
        guard expected >= 0, body.count == expected else {
            throw PolestarError.invalidResponse(operation: "truncated gRPC frame")
        }
        return body
    }


    /// Turns a non-zero gRPC status on a write RPC into something the user can act on.
    /// Previously every status except 12 and 16 collapsed into "returned an unexpected
    /// response", which hid the one piece of information that explains the failure.
    /// `grpc-message` is percent-encoded per the gRPC HTTP/2 spec.
    static func commandError(status: String, message: String?, path: String) -> Error {
        let detail = message?.removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmptyValue
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
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/grpc", forHTTPHeaderField: "Content-Type")
        request.setValue("grpc-java-okhttp/1.68.2", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(vin, forHTTPHeaderField: "vin")
        request.httpBody = Protobuf.grpcFrame(message)

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolestarError.invalidResponse(operation: "gRPC command")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PolestarError.authenticationRequired(.expiredSession)
        }
        guard http.statusCode == 200 else { throw PolestarError.server(statusCode: http.statusCode) }
        if let status = http.value(forHTTPHeaderField: "grpc-status"), status != "0" {
            throw Self.commandError(status: status,
                                    message: http.value(forHTTPHeaderField: "grpc-message"),
                                    path: path)
        }

        var header = [UInt8]()
        var body = Data()
        var expected: Int?
        var latest: Data?
        var frameCount = 0
        var endedByTimeout = false
        do {
            for try await byte in bytes {
                if expected == nil {
                    header.append(byte)
                    guard header.count == 5 else { continue }
                    guard header[0] == 0 else {
                        throw PolestarError.incompatibleAPI(operation: "compressed gRPC command frame")
                    }
                    let size = Int(header[1]) << 24 | Int(header[2]) << 16
                        | Int(header[3]) << 8 | Int(header[4])
                    guard size >= 0, size <= 2_000_000 else {
                        throw PolestarError.invalidResponse(operation: "oversized gRPC command frame")
                    }
                    expected = size
                    body.removeAll(keepingCapacity: true)
                    if size == 0 {
                        latest = Data()
                        expected = nil
                        header.removeAll(keepingCapacity: true)
                    }
                    continue
                }
                body.append(byte)
                if let frameSize = expected, body.count == frameSize {
                    latest = body
                    frameCount += 1
                    guard frameCount < 32 else { break }
                    expected = nil
                    header.removeAll(keepingCapacity: true)
                    body.removeAll(keepingCapacity: true)
                }
            }
        } catch let error as URLError where error.code == .timedOut && latest != nil {


            endedByTimeout = true
        }
        guard let latest, expected == nil || endedByTimeout else {
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
        return latest
    }


    static func parseBattery(_ data: Data) -> GrpcBatteryExtras {
        var reportedAt: Date?
        var battery: Double?, range: Int?, minutes: Int?
        var connection: ChargerConnection = .unknown
        var state: ChargingState?, type: ChargingType = .unknown
        var watts: Int?, amps: Int?, volts: Int?
        var timeToTarget: Int?, timeToMinimumSOC: Int?
        var averageConsumption: Double?, averageSinceCharge: Double?, energySinceCharge: Double?
        var powerState: ChargerPowerState = .unknown
        for field in Protobuf.fields(data) {
            switch field.number {
            case 1 where field.wire == 2:
                if let seconds = Protobuf.fields(field.data).first(where: { $0.number == 1 })?.varint,
                   seconds > 0 { reportedAt = Date(timeIntervalSince1970: TimeInterval(seconds)) }
            case 2 where field.wire == 1: battery = Protobuf.double(from: field.data)
            case 4 where field.wire == 0: range = Int(field.varint)
            case 5 where field.wire == 0: minutes = Int(field.varint)
            case 6:
                switch field.varint {
                case 1: connection = .connected
                case 2: connection = .disconnected
                case 3: connection = .fault
                default: break
                }
            case 7:
                let values = ["UNSPECIFIED", "CHARGING", "IDLE", "SCHEDULED", "DISCHARGING",
                              "ERROR", "SMART_CHARGING", "DONE", "SMART_CHARGING_PAUSED"]
                if Int(field.varint) < values.count { state = ChargingState(apiValue: values[Int(field.varint)]) }
            case 10: watts = Int(field.varint)
            case 11: amps = Int(field.varint)
            case 3 where field.wire == 1: averageConsumption = Protobuf.double(from: field.data)
            case 9: timeToTarget = Int(field.varint)
            case 13 where field.wire == 1: averageSinceCharge = Protobuf.double(from: field.data)
            case 16 where field.wire == 1: energySinceCharge = Protobuf.double(from: field.data)
            case 17:
                switch field.varint {
                case 1: type = .none
                case 2: type = .ac
                case 3: type = .dc
                case 4: type = .wireless
                default: break
                }
            case 18: volts = Int(field.varint)
            case 19: timeToMinimumSOC = Int(field.varint)
            case 26:
                switch field.varint {
                case 1: powerState = .noPower
                case 2: powerState = .initializing
                case 3: powerState = .available
                case 4: powerState = .providingPower
                case 5: powerState = .fault
                default: break
                }
            default: break
            }
        }
        return GrpcBatteryExtras(reportedAt: reportedAt,
                                 batteryPercentage: battery,
                                 rangeKm: range,
                                 estimatedChargingTimeToFullMinutes: minutes,
                                 chargingState: state,
                                 chargerConnection: connection,
                                 chargingType: type,
                                 chargingPowerWatts: watts,
                                 chargingCurrentAmps: amps,
                                 chargingVoltageVolts: volts,
                                 diagnostics: BatteryDiagnostics(
                                    timeToTargetMinutes: timeToTarget.flatMap { $0 > 0 ? $0 : nil },
                                    timeToMinimumSOCMinutes: timeToMinimumSOC.flatMap { $0 > 0 ? $0 : nil },
                                    chargerPowerState: powerState,
                                    averageConsumption: averageConsumption.flatMap { $0 > 0 ? $0 : nil },
                                    averageConsumptionSinceCharge: averageSinceCharge.flatMap { $0 > 0 ? $0 : nil },
                                    energyUsedSinceChargeWh: energySinceCharge.flatMap { $0 > 0 ? $0 : nil }
                                 ))
    }

    private static func unavailableReason(_ value: UInt64?) -> String? {
        switch value {
        case 1: return L10n.text("No vehicle connection")
        case 2: return L10n.text("Power saving")
        case 3: return L10n.text("Vehicle in use")
        case 4: return L10n.text("Software update in progress")
        case 5: return L10n.text("Tracking in progress")
        case 6: return L10n.text("Service mode")
        default: return nil
        }
    }
}


enum GRPCHost: Sendable {


    case c3


    case pccs
}

enum Protobuf {

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

    static func doubleField(_ number: Int, _ value: Double) -> Data {
        var out = varint(UInt64(number << 3 | 1))
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { out.append(contentsOf: $0) }
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


    static func fields(_ data: Data) -> [Field] {
        var fields: [Field] = []
        let bytes = [UInt8](data)
        var i = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count, shift < 64 {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while i < bytes.count {
            guard let tag = readVarint() else { break }
            let number = Int(tag >> 3), wire = Int(tag & 7)
            switch wire {
            case 0:
                guard let v = readVarint() else { return fields }
                fields.append(Field(number: number, wire: 0, varint: v, data: Data()))
            case 1, 5:
                let width = wire == 1 ? 8 : 4
                guard i + width <= bytes.count else { return fields }
                let value = Data(bytes[i..<i + width])
                i += width
                fields.append(Field(number: number, wire: wire, varint: 0, data: value))
            case 2:
                guard let len = readVarint(), i + Int(len) <= bytes.count else { return fields }
                fields.append(Field(number: number, wire: 2, varint: 0,
                                    data: Data(bytes[i..<i + Int(len)])))
                i += Int(len)
            default:
                return fields
            }
        }
        return fields
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



extension String {
    /// Local spelling of the common `nilIfEmpty` helper — the file-private ones in the
    /// sibling gRPC files are not visible here.
    var nilIfEmptyValue: String? { isEmpty ? nil : self }
}
