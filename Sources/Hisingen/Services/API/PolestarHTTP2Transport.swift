import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

struct PolestarHTTP2Transport: PolestarGRPCTransport {
    let supportsTrailers = true
    private let allowLoopbackPlaintext: Bool
    private let timeout: Duration?

    init(allowLoopbackPlaintext: Bool = false, timeout: Duration? = nil) {
        self.allowLoopbackPlaintext = allowLoopbackPlaintext
        self.timeout = timeout
    }

    private struct RawCodec: MessageSerializer, MessageDeserializer {
        func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes { Bytes(message) }
        func deserialize<Bytes: GRPCContiguousBytes>(_ bytes: Bytes) throws -> [UInt8] {
            bytes.withUnsafeBytes { Array($0) }
        }
    }

    private struct CallbackError: Error {
        let underlying: any Error
    }
    private struct Stopped: Error {}

    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws {
        guard let url = request.url, let host = url.host, let scheme = url.scheme,
              let body = request.httpBody, body.count >= 5 else {
            throw PolestarError.invalidResponse(operation: "invalid gRPC request")
        }
        let plain = scheme == "http" && allowLoopbackPlaintext && (host == "127.0.0.1" || host == "localhost" || host == "::1")
        guard scheme == "https" || plain else { throw PolestarError.invalidResponse(operation: "invalid gRPC transport security") }
        let path = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2 else { throw PolestarError.invalidResponse(operation: "invalid gRPC method") }
        let bytes = [UInt8](body)
        let length = (Int(bytes[1]) << 24) | (Int(bytes[2]) << 16) | (Int(bytes[3]) << 8) | Int(bytes[4])
        guard bytes[0] == 0, length == bytes.count - 5, length <= 2 * 1024 * 1024 else {
            throw PolestarError.invalidResponse(operation: "invalid gRPC request frame")
        }
        var metadata = Metadata()
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            let key = name.lowercased()
            guard !["content-type", "te", "host", "content-length"].contains(key), !key.hasPrefix("grpc-") else { continue }
            metadata.addString(value, forKey: key)
        }
        var options = CallOptions.defaults
        options.timeout = timeout ?? (live ? .seconds(20 * 60) : .seconds(max(1, Int(request.timeoutInterval))))
        options.waitForReady = false
        options.maxResponseMessageBytes = 2 * 1024 * 1024
        let descriptor = MethodDescriptor(service: ServiceDescriptor(fullyQualifiedService: String(path[0])), method: String(path[1]))
        let transport = try HTTP2ClientTransport.Posix(
            target: .dns(host: host, port: url.port ?? (plain ? 80 : 443)),
            transportSecurity: plain ? .plaintext : .tls
        )
        let callMetadata = metadata
        let callOptions = options
        do {
            try await withGRPCClient(transport: transport) { client in
                try await client.serverStreaming(
                    request: ClientRequest(message: Array(bytes.dropFirst(5)), metadata: callMetadata),
                    descriptor: descriptor, serializer: RawCodec(), deserializer: RawCodec(), options: callOptions
                ) { response in
                    func emit(_ part: PolestarGRPCResponsePart) async throws {
                        do { if try await !onPart(part) { throw Stopped() } }
                        catch is Stopped { throw Stopped() }
                        catch { throw CallbackError(underlying: error) }
                    }
                    do {
                        let contents = try response.accepted.get()
                        try await emit(.headers(.init(httpStatus: nil, metadata: Self.dictionary(contents.metadata))))
                        for try await part in contents.bodyParts {
                            switch part {
                            case .message(let message): try await emit(.message(Data(message)))
                            case .trailingMetadata(let metadata):
                                try await emit(.status(.init(code: 0, message: nil, metadata: Self.dictionary(metadata))))
                            }
                        }
                    } catch let error as RPCError {
                        try Task.checkCancellation()
                        try await emit(.status(.init(code: error.code.rawValue, message: error.message, metadata: Self.dictionary(error.metadata))))
                    }
                }
            }
        } catch is Stopped {
            return
        } catch let error as CallbackError {
            throw error.underlying
        } catch is CancellationError {
            // grpc-swift enforces the call deadline by cancelling the call from inside, so it
            // surfaces here as a bare CancellationError. Only a cancelled caller is a real
            // cancellation; otherwise report the deadline as the status it is, so callers can
            // tell "the stream never closed" from "the user cancelled".
            try Task.checkCancellation()
            _ = try await onPart(.status(.init(code: PolestarGRPC.deadlineExceededStatus, message: "deadline exceeded", metadata: [:])))
        }
    }

    private static func dictionary(_ metadata: Metadata) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in metadata {
            let encoded = value.encoded()
            if let existing = result[key] { result[key] = existing + "," + encoded }
            else { result[key] = encoded }
        }
        return result
    }
}
