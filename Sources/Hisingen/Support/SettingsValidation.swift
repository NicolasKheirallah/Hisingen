import Foundation

enum SettingsValidation {
    static func isValidEmail(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !trimmed.contains(" ")
    }

    /// The VIN syntax both providers gate on: 17 ASCII characters, digits and uppercase
    /// letters, excluding I, O and Q. Strict: no trimming or case folding. Callers taking
    /// user input normalize first through `isValidOptionalVIN`.
    static func isValidVIN(_ value: String) -> Bool {
        value.count == 17 && value.allSatisfy { character in
            character.isASCII
                && (character.isNumber || (character.isUppercase && !"IOQ".contains(character)))
        }
    }

    static func isValidOptionalVIN(_ value: String) -> Bool {
        let vin = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !vin.isEmpty else { return true }
        return isValidVIN(vin)
    }

    static func isValidElectricityPrice(_ text: String) -> Bool {
        guard let value = NumberParsing.decimal(from: text) else { return false }
        return (0.01...1_000).contains(value)
    }

    static func isValidCurrencySymbol(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return (1...8).contains(value.count) && !value.contains(where: \.isNewline)
    }
}
