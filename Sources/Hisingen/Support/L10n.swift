import Foundation

enum L10n {
    private static let threadLanguageOverrideKey = "io.kheirallah.hisingen.interface-language-override"
    private static let bundleLock = NSLock()
    nonisolated(unsafe) private static var localizedBundleCache: [String: Bundle?] = [:]

    /// Resolved once per process. This used to be a computed property that probed several
    /// `Bundle(path:)` candidates on *every* `text()` call – a filesystem hit per localized
    /// string, on render paths in a permanent menu-bar app.
    private static let bundle: Bundle = {
        if let resBundlePath = Bundle.main.path(forResource: "Hisingen_Hisingen", ofType: "bundle"),
           let bundle = Bundle(path: resBundlePath) {
            return bundle
        }
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
            return .main
        }
        let currentDir = FileManager.default.currentDirectoryPath
        let candidates = [
            Bundle.main.bundlePath + "/Contents/Resources",
            Bundle.main.bundlePath,
            "Sources/Hisingen/Resources",
            currentDir + "/Sources/Hisingen/Resources",
            "../Sources/Hisingen/Resources",
            "../../Sources/Hisingen/Resources"
        ]
        for path in candidates {
            if let bundle = Bundle(path: path), bundle.path(forResource: "en", ofType: "lproj") != nil {
                return bundle
            }
        }
        return .main
    }()

    /// Read per call (a cheap cached-preferences lookup) so language changes apply without an
    /// explicit invalidation hook; only the expensive bundle resolution is memoized.
    private static var selectedLanguageCode: String? {
        if let override = Thread.current.threadDictionary[threadLanguageOverrideKey] as? String {
            return override
        }
        return InterfaceLanguage(rawValue: UserDefaults.standard.string(forKey: "interface_language") ?? "")?.languageCode
    }

    /// Test seam scoped to the calling thread. A process-global UserDefaults mutation let
    /// parallel locale tests change the language underneath unrelated formatters.
    static func withInterfaceLanguageOverride<T>(_ languageCode: String, body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[threadLanguageOverrideKey]
        dictionary[threadLanguageOverrideKey] = languageCode
        defer {
            if let previous {
                dictionary[threadLanguageOverrideKey] = previous
            } else {
                dictionary.removeObject(forKey: threadLanguageOverrideKey)
            }
        }
        return try body()
    }

    /// The locale every user-facing number and date follows: the selected interface language
    /// when one is chosen, the system locale otherwise. Without this, an English UI on a
    /// Swedish-region Mac rendered Swedish month names ("19 september 2026") and split decimal
    /// separators across its own surfaces, because `Format`'s formatters tracked the region
    /// while `L10n.format` tracked the language.
    static var displayLocale: Locale {
        selectedLanguageCode.map(Locale.init(identifier:)) ?? .current
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        bundleLock.lock()
        defer { bundleLock.unlock() }
        if let cached = localizedBundleCache[languageCode] { return cached }
        let candidates = [languageCode, String(languageCode.prefix(2))]
        var resolved: Bundle?
        for candidate in candidates {
            if let path = bundle.path(forResource: candidate, ofType: "lproj"),
               let localizedBundle = Bundle(path: path) {
                resolved = localizedBundle
                break
            }
        }
        localizedBundleCache[languageCode] = resolved
        return resolved
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

    /// Formats against an explicit language instead of the selected one. Mirrors
    /// `text(_:languageCode:)`, and lets callers (notably tests) resolve a specific
    /// language without writing the process-global `interface_language` preference.
    static func format(_ key: String, languageCode: String?, _ arguments: CVarArg...) -> String {
        let locale = (languageCode ?? selectedLanguageCode).map(Locale.init(identifier:)) ?? .current
        return String(format: text(key, languageCode: languageCode), locale: locale, arguments: arguments)
    }
}
