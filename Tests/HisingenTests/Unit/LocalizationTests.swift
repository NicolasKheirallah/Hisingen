import Foundation
import Testing
@testable import Hisingen

@MainActor
struct LocalizationTests {
    @Test
    func testInterfaceLanguagesHaveValidCodes() {
        for lang in InterfaceLanguage.allCases {
            if lang == .system {
                XCTAssertNil(lang.languageCode)
            } else {
                XCTAssertNotNil(lang.languageCode)
                XCTAssertFalse(lang.title.isEmpty)
            }
        }
    }

    // These resolve each language explicitly rather than writing "interface_language" into
    // UserDefaults.standard. That key is process-global and read by L10n on every lookup,
    // so while a test held it at Swedish or German, unrelated tests running in parallel
    // asserted English strings against translated ones and failed.

    @Test
    func testL10nTextLookup() {
        XCTAssertEqual(L10n.text("Dashboard", languageCode: "sv"), "Översikt")
        XCTAssertEqual(L10n.text("Done", languageCode: "sv"), "Klar")
        XCTAssertEqual(L10n.text("12V Battery", languageCode: "sv"), "12V-batteri")

        XCTAssertEqual(L10n.text("Dashboard", languageCode: "de"), "Übersicht")
        XCTAssertEqual(L10n.text("Done", languageCode: "de"), "Fertig")
        XCTAssertEqual(L10n.text("12V Battery", languageCode: "de"), "12V-Batterie")

        XCTAssertEqual(L10n.text("Dashboard", languageCode: "en"), "Dashboard")
        XCTAssertEqual(L10n.text("Done", languageCode: "en"), "Done")
    }

    @Test
    func testL10nFormat() {
        XCTAssertEqual(L10n.format("Active Vehicle: %@", languageCode: "sv", "Polestar 2"),
                       "Aktivt fordon: Polestar 2")
        XCTAssertEqual(L10n.text("Locked", languageCode: "sv"), "Låst")
        XCTAssertEqual(L10n.text("Unlocked", languageCode: "sv"), "Olåst")
        XCTAssertEqual(L10n.text("Clear", languageCode: "sv"), "Klart")
        XCTAssertEqual(L10n.text("Rain", languageCode: "sv"), "Regn")
        XCTAssertEqual(L10n.text("Snow", languageCode: "sv"), "Snö")
        XCTAssertEqual(L10n.text("70% / 160,000 km (8 Years)", languageCode: "sv"),
                       "70 % / 160 000 km (8 år)")
        XCTAssertEqual(L10n.format("feels like %@", languageCode: "sv", "20 °C"), "känns som 20 °C")
        XCTAssertEqual(L10n.format("%d hrs", languageCode: "sv", 5), "5 tim")

        XCTAssertEqual(L10n.format("Active Vehicle: %@", languageCode: "en", "Polestar 2"),
                       "Active Vehicle: Polestar 2")
        XCTAssertEqual(L10n.text("Locked", languageCode: "en"), "Locked")
        XCTAssertEqual(L10n.text("Unlocked", languageCode: "en"), "Unlocked")
    }
}
