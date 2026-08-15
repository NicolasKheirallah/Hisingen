import Foundation

enum HTTPBodyReader {
    static func data(
        for request: URLRequest,
        using session: URLSession,
        limit: Int,
        operation: String
    ) async throws -> (Data, URLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            if response.expectedContentLength > Int64(limit) {
                throw PolestarError.responseTooLarge(operation: operation)
            }
            var data = Data()
            data.reserveCapacity(min(max(0, Int(response.expectedContentLength)), limit))
            for try await byte in bytes {
                guard data.count < limit else {
                    throw PolestarError.responseTooLarge(operation: operation)
                }
                data.append(byte)
            }
            return (data, response)
        } catch let error as URLError {
            throw PolestarError.network(error)
        }
    }
}

