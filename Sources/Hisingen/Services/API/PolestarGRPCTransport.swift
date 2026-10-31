import Foundation

protocol PolestarGRPCTransport: Sendable {
    var supportsTrailers: Bool { get }
    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws
}

final class URLSessionPolestarGRPCTransport: PolestarGRPCTransport {
    let supportsTrailers = false
    private let requestSession: URLSession
    private let liveSession: URLSession

    init(requestSession: URLSession, liveSession: URLSession? = nil) {
        self.requestSession = requestSession
        if let liveSession {
            self.liveSession = liveSession
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 20 * 60
            configuration.timeoutIntervalForResource = 24 * 60 * 60
            self.liveSession = URLSession(configuration: configuration)
        }
    }

    func execute(
        for request: URLRequest, live: Bool,
        onPart: @escaping @Sendable (PolestarGRPCResponsePart) async throws -> Bool
    ) async throws {
        let (bytes, response) = try await (live ? liveSession : requestSession).bytes(for: request)
        let http = response as? HTTPURLResponse
        var metadata: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] {
            metadata[String(describing: key).lowercased()] = String(describing: value)
        }
        guard try await onPart(.headers(.init(httpStatus: http?.statusCode, metadata: metadata))) else { return }
        if let raw = metadata["grpc-status"], let code = Int(raw), code != 0 {
            _ = try await onPart(.status(.init(code: code, message: metadata["grpc-message"]?.removingPercentEncoding, metadata: metadata)))
            return
        }
        var reader = GRPCFrameReader(context: "gRPC")
        do {
            for try await byte in bytes {
                if let message = try reader.consume(byte), try await !onPart(.message(message)) { return }
            }
        } catch {
            if reader.isReadingBody { throw PolestarError.invalidResponse(operation: "truncated gRPC frame") }
            throw error
        }
        if reader.isReadingBody { throw PolestarError.invalidResponse(operation: "truncated gRPC frame") }
        if metadata["grpc-status"] == "0" {
            _ = try await onPart(.status(.init(code: 0, message: metadata["grpc-message"]?.removingPercentEncoding, metadata: metadata)))
        }
    }
}
