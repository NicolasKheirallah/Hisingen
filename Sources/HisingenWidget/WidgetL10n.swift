import Foundation

/// The widget's twin of the app's `L10n`. The app and the widget are separate binaries with
/// no shared module between them, so the widget resolves the same English-key tables
/// against its own bundle; the Makefile copies the app's `.lproj` folders into the `.appex`
/// at assembly time. A missing translation falls back to the English key, exactly as
/// `L10n.text` does, so an unbundled build still reads correctly in English.
///
/// The language comes from the snapshot (`VehicleWidgetSnapshot.languageCode`), which the
/// app resolved from the same preference its own `L10n` reads.
enum WidgetL10n {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var localizedBundleCache: [String: Bundle?] = [:]

    static func text(_ key: String, _ languageCode: String?) -> String {
        guard let languageCode,
              let localizedBundle = localizedBundle(for: languageCode) else {
            return Bundle.main.localizedString(forKey: key, value: key, table: nil)
        }
        let localized = localizedBundle.localizedString(forKey: key, value: key, table: nil)
        guard localized != key || languageCode.hasPrefix("en") else {
            return englishBundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        }
        return localized
    }

    static func format(_ key: String, _ languageCode: String?, _ arguments: CVarArg...) -> String {
        let locale = languageCode.map(Locale.init(identifier:)) ?? .current
        return String(format: text(key, languageCode), locale: locale, arguments: arguments)
    }

    private static func localizedBundle(for languageCode: String) -> Bundle? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = localizedBundleCache[languageCode] { return cached }
        var resolved: Bundle?
        for candidate in [languageCode, String(languageCode.prefix(2))] {
            if let path = Bundle.main.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                resolved = bundle
                break
            }
        }
        localizedBundleCache[languageCode] = resolved
        return resolved
    }

    private static var englishBundle: Bundle? { localizedBundle(for: "en") }
}
