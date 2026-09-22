import Foundation

/// Quotes a CSV cell containing a comma, quote or newline, doubling embedded quotes, so no
/// value a vehicle or preference supplies can shift the column layout.
enum CSV {
    static func field(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "" }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return value.contains(",") || value.contains("\"") || value.contains("\n")
            ? "\"\(escaped)\"" : value
    }
}
