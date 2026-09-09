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
        diagnosticLog: APIDiagnosticLogStore = .shared
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
            var pending = [UInt8]()
            pending.reserveCapacity(64 * 1_024)
            for try await byte in bytes {
                guard data.count + pending.count < limit else {
                    throw Self.responseTooLarge(operation: operation, provider: provider)
                }
                pending.append(byte)
                if pending.count >= 64 * 1_024 {
                    data.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                }
            }
            data.append(contentsOf: pending)
            await diagnosticLog.record(
                provider: diagnosticProvider, request: request, operation: operation,
                statusCode: http.statusCode, responseBytes: data.count,
                responseData: data, startedAt: startedAt)
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
