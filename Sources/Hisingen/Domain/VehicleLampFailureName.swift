import Foundation

/// Lamp names for the per-bulb rows under Exterior Lighting. Volvo stores each failure as
/// "<lamp label>: <raw value>" and Polestar as a bare label, so the label is used as-is. A bare
/// field key such as "brakeLightLeftWarning" is split into words so an unrecognised entry still
/// reads as a lamp rather than as an identifier.
enum VehicleLampFailureName {
    static func name(for entry: String) -> String {
        let label: String
        if let separator = entry.range(of: ": ", options: .backwards) {
            label = String(entry[..<separator.lowerBound])
        } else {
            label = entry
        }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFieldKey(trimmed) else { return trimmed }
        return words(fromKey: trimmed)
    }

    private static func isFieldKey(_ text: String) -> Bool {
        guard let first = text.first, first.isLowercase, !text.contains(" ") else { return false }
        return text.contains { $0.isUppercase || $0 == "_" }
    }

    private static func words(fromKey key: String) -> String {
        var source = key
        if source.hasSuffix("Warning") { source.removeLast("Warning".count) }
        var words: [String] = []
        var current = ""
        for character in source {
            if character == "_" || character == "-" {
                if !current.isEmpty { words.append(current); current = "" }
            } else if character.isUppercase {
                if !current.isEmpty { words.append(current); current = "" }
                current.append(contentsOf: character.lowercased())
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        return joined.prefix(1).uppercased() + joined.dropFirst()
    }
}
