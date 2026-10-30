import Foundation

enum HTTPExchange {
    /// Performs one bounded HTTP exchange and records its redacted diagnostic outcome. The
    /// request is never replayed, which keeps this safe for Remote Command POSTs.
    static func data(
        for request: URLRequest,
        using session: URLSession,
        limit: Int,
        operation: String,
        provider: VehicleBrand,
        diagnosticLog: APIDiagnosticLogStore = .shared,
        // Classifies the response even when the store must not retain its body: an OAuth
        // `error` code, or an expected version-negotiation rejection such as a 406. Returns a
        // short, credential-free label, or nil when there is nothing to classify.
        semanticError: (@Sendable (Data, Int) -> String?)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let startedAt = Date()
        let diagnosticProvider: APILogProvider = provider == .polestar ? .polestar : .volvo
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw Self.invalidResponse(operation: operation, provider: provider)
            }
            if http.expectedContentLength > Int64(limit) {
                throw Self.responseTooLarge(operation: operation, provider: provider)
            }
            var data = Data()
            data.reserveCapacity(min(max(0, Int(http.expectedContentLength)), limit))
            // Bytes are staged in a small array and copied into `data` a chunk at a time, so the
            // per-byte work is a plain array append. The size bound and cancellation are checked
            // at chunk boundaries rather than on every byte.
            let chunkSize = 16 * 1_024
            var chunk: [UInt8] = []
            chunk.reserveCapacity(chunkSize)
            for try await byte in bytes {
                chunk.append(byte)
                guard chunk.count == chunkSize else { continue }
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                guard data.count < limit else {
                    throw Self.responseTooLarge(operation: operation, provider: provider)
                }
                try Task.checkCancellation()
            }
            data.append(contentsOf: chunk)
            guard data.count < limit else {
                throw Self.responseTooLarge(operation: operation, provider: provider)
            }
            await diagnosticLog.record(
                provider: diagnosticProvider, request: request, operation: operation,
                statusCode: http.statusCode, responseBytes: data.count,
                responseData: data, startedAt: startedAt,
                semanticErrorType: semanticError?(data, http.statusCode))
            return (data, http)
        } catch {
            let mapped = (error as? URLError).map { Self.network($0, provider: provider) } ?? error
            await diagnosticLog.record(
                provider: diagnosticProvider, request: request, operation: operation,
                startedAt: startedAt, error: mapped)
            throw mapped
        }
    }

    private static func invalidResponse(operation: String, provider: VehicleBrand) -> Error {
        switch provider {
        case .polestar: return PolestarError.invalidResponse(operation: operation)
        case .volvo: return VolvoError.invalidResponse(operation: operation)
        }
    }

    private static func responseTooLarge(operation: String, provider: VehicleBrand) -> Error {
        switch provider {
        case .polestar: return PolestarError.responseTooLarge(operation: operation)
        case .volvo: return VolvoError.responseTooLarge(operation: operation)
        }
    }

    private static func network(_ error: URLError, provider: VehicleBrand) -> Error {
        switch provider {
        case .polestar: return PolestarError.network(error)
        case .volvo: return VolvoError.network(error)
        }
    }
}
