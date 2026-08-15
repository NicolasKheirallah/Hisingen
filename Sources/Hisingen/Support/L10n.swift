import Foundation

enum L10n {
    private static var bundle: Bundle {
        #if SWIFT_PACKAGE
        return .module
        #else
        return .main
        #endif
    }

    private static var selectedLanguageCode: String? {
        InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interface_language") ?? "")?.languageCode
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        let candidates = [languageCode, String(languageCode.prefix(2))]
        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localizedBundle = Bundle(path: path) {
                return localizedBundle
            }
        }
        return nil
    }

    private static var englishBundle: Bundle? {
        localizedBundle(for: "en")
    }

    static func text(_ key: String) -> String {
        guard let languageCode = selectedLanguageCode,
              let localizedBundle = localizedBundle(for: languageCode) else {
            return bundle.localizedString(forKey: key, value: key, table: nil)
        }
        let localized = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard localized != key || languageCode.hasPrefix("en") else {
            return englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        }
        return localized
    }

    static func text(_ key: String, languageCode: String?) -> String {
        guard let languageCode, let localizedBundle = localizedBundle(for: languageCode) else { return text(key) }
        let localized = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard localized != key || languageCode.hasPrefix("en") else {
            return englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        }
        return localized
    }

    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        let locale = selectedLanguageCode.map(Locale.init(identifier:)) ?? .current
        return String(format: text(key), locale: locale, arguments: arguments)
    }
}


