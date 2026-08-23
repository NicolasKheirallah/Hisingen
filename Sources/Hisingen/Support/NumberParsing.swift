import Foundation

/// Shared numeric parsing for user-entered prices/quantities. Accepts both `,` and `.` as
/// the decimal separator (European and English keyboards) — previously three call sites each
/// rolled their own comma-swap with divergent edge-case behaviour.
enum NumberParsing {
    /// Parses a decimal number, treating `,` as a decimal separator when no `.` is present.
    /// Returns nil for empty/garbage input; callers decide on range validation.
    static func decimal(from raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains(".")
            ? trimmed.replacingOccurrences(of: ",", with: "")
            : trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
