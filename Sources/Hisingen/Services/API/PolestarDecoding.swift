import Foundation
import OSLog

enum PolestarDecoding {
    static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data, operation: String, logger: Logger
    ) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            log(error, operation: operation, logger: logger)
            throw PolestarError.decoding(operation: operation)
        }
    }

    static func log(_ error: any Error, operation: String, logger: Logger) {
        let path: [any CodingKey]
        let category: String
        switch error {
        case DecodingError.typeMismatch(_, let context):
            path = context.codingPath; category = "typeMismatch"
        case DecodingError.valueNotFound(_, let context):
            path = context.codingPath; category = "valueNotFound"
        case DecodingError.keyNotFound(let key, let context):
            path = context.codingPath + [key]; category = "keyNotFound"
        case DecodingError.dataCorrupted(let context):
            path = context.codingPath; category = "dataCorrupted"
        default:
            path = []; category = "decoding"
        }
        let safePath = DiagnosticRedaction.redact(path.map(\.stringValue).joined(separator: "."))
        logger.warning("Polestar \(operation, privacy: .public) decode failed: \(category, privacy: .public) at \(safePath, privacy: .public)")
    }
}
