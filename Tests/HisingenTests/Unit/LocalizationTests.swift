import Foundation
import Testing
@testable import Hisingen

@MainActor
struct LocalizationTests {
    @Test
    func testInterfaceLanguagesHaveValidCodes() {
        for lang in InterfaceLanguage.allCases {
            if lang == .system {
                #expect(lang.languageCode == nil)
            } else {
                #expect(lang.languageCode != nil)
                #expect(!(lang.title.isEmpty))
            }
        }
    }

    // These resolve each language explicitly rather than writing "interface_language" into
    // UserDefaults.standard. That key is process-global and read by L10n on every lookup,
    // so while a test held it at Swedish or German, unrelated tests running in parallel
    // asserted English strings against translated ones and failed.

    @Test
    func testL10nTextLookup() {
        #expect(L10n.text("Dashboard", languageCode: "sv") == "Översikt")
        #expect(L10n.text("Done", languageCode: "sv") == "Klar")
        #expect(L10n.text("12V Battery", languageCode: "sv") == "12V-batteri")

        #expect(L10n.text("Dashboard", languageCode: "de") == "Übersicht")
        #expect(L10n.text("Done", languageCode: "de") == "Fertig")
        #expect(L10n.text("12V Battery", languageCode: "de") == "12V-Batterie")

        #expect(L10n.text("Dashboard", languageCode: "en") == "Dashboard")
        #expect(L10n.text("Done", languageCode: "en") == "Done")
    }

    @Test
    func testL10nFormat() {
        #expect(L10n.format("Active Vehicle: %@", languageCode: "sv", "Polestar 2") == "Aktivt fordon: Polestar 2")
        #expect(L10n.text("Locked", languageCode: "sv") == "Låst")
        #expect(L10n.text("Unlocked", languageCode: "sv") == "Olåst")
        #expect(L10n.text("Clear", languageCode: "sv") == "Klart")
        #expect(L10n.text("Rain", languageCode: "sv") == "Regn")
        #expect(L10n.text("Snow", languageCode: "sv") == "Snö")
        #expect(L10n.text("70% / 160,000 km (8 Years)", languageCode: "sv") == "70 % / 160 000 km (8 år)")
        #expect(L10n.format("feels like %@", languageCode: "sv", "20 °C") == "känns som 20 °C")
        #expect(L10n.format("%d hrs", languageCode: "sv", 5) == "5 tim")

        #expect(L10n.format("Active Vehicle: %@", languageCode: "en", "Polestar 2") == "Active Vehicle: Polestar 2")
        #expect(L10n.text("Locked", languageCode: "en") == "Locked")
        #expect(L10n.text("Unlocked", languageCode: "en") == "Unlocked")
    }
}
