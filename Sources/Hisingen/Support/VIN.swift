import Foundation

extension String {
    /// The one spelling of a VIN used as a key, a SQL bind or a comparison: trimmed and uppercased.
    var normalizedVIN: String { trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
}
