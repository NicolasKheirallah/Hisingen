import Foundation
@testable import Hisingen

/// Pins the interface language for the duration of `body`, then restores whatever was there.
///
/// Every user-facing number and date now formats through `L10n.displayLocale` (the selected
/// interface language, else the system locale), so assertions that pin "6.5"-style output must
/// pin the language too: on a Swedish-region host the same formatter would honestly render
/// "6,5", and a locale-dependent test would break on machines that differ from its author's.
func withPinnedInterfaceLanguage(_ body: () throws -> Void) rethrows {
    try L10n.withInterfaceLanguageOverride("en", body: body)
}
