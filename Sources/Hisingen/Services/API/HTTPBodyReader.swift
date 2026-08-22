import Foundation

enum HTTPBodyReader {
    /// Shared by both `PolestarAPI+Transport.swift` and `VolvoAPI+Transport.swift`, so the
    /// errors it throws must match whichever provider is actually calling it — `provider`
    /// selects between `PolestarError`/`VolvoError` rather than always throwing `PolestarError`
    /// (which previously meant a Volvo `catch let error as VolvoError` could never match a
    /// too-large-response or network failure that actually originated here).
    static func data(
        for request: URLRequest,
        using session: URLSession,
        limit: Int,
        operation: String,
        provider: VehicleBrand
    ) async throws -> (Data, URLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if response.expectedContentLength > Int64(limit) {
                throw Self.responseTooLarge(operation: operation, provider: provider)
            }
            var data = Data()
            data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), limit))
            for try await byte in bytes {
                guard data.count < limit else {
                    throw Self.responseTooLarge(operation: operation, provider: provider)
                }
                data.append(byte)
            }
            return (data, response)
        } catch let error as URLError {
            throw Self.network(error, provider: provider)
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


