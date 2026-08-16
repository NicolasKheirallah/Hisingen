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

    @Test
    func testL10nTextLookup() {
        let original = UserDefaults.standard.string(forKey: "interface_language")
        defer {
            UserDefaults.standard.set(original, forKey: "interface_language")
        }

        UserDefaults.standard.set("swedish", forKey: "interface_language")
        XCTAssertEqual(L10n.text("Dashboard"), "Översikt")
        XCTAssertEqual(L10n.text("Done"), "Klar")
        XCTAssertEqual(L10n.text("12V Battery"), "12V-batteri")

        UserDefaults.standard.set("german", forKey: "interface_language")
        XCTAssertEqual(L10n.text("Dashboard"), "Übersicht")
        XCTAssertEqual(L10n.text("Done"), "Fertig")
        XCTAssertEqual(L10n.text("12V Battery"), "12V-Batterie")

        UserDefaults.standard.set("english", forKey: "interface_language")
        XCTAssertEqual(L10n.text("Dashboard"), "Dashboard")
        XCTAssertEqual(L10n.text("Done"), "Done")
    }

    @Test
    func testL10nFormat() {
        let original = UserDefaults.standard.string(forKey: "interface_language")
        defer {
            UserDefaults.standard.set(original, forKey: "interface_language")
        }

        UserDefaults.standard.set("swedish", forKey: "interface_language")
        let formatted = L10n.format("Active Vehicle: %@", "Polestar 2")
        XCTAssertEqual(formatted, "Aktivt fordon: Polestar 2")
        XCTAssertEqual(L10n.text("Locked"), "Låst")
        XCTAssertEqual(L10n.text("Unlocked"), "Olåst")
        XCTAssertEqual(L10n.text("Clear"), "Klart")
        XCTAssertEqual(L10n.text("Rain"), "Regn")
        XCTAssertEqual(L10n.text("Snow"), "Snö")
        XCTAssertEqual(L10n.text("70% / 160,000 km (8 Years)"), "70 % / 160 000 km (8 år)")
        XCTAssertEqual(L10n.format("feels like %@", "20 °C"), "känns som 20 °C")
        XCTAssertEqual(L10n.format("%d hrs", 5), "5 tim")

        UserDefaults.standard.set("english", forKey: "interface_language")
        let formattedEn = L10n.format("Active Vehicle: %@", "Polestar 2")
        XCTAssertEqual(formattedEn, "Active Vehicle: Polestar 2")
        XCTAssertEqual(L10n.text("Locked"), "Locked")
        XCTAssertEqual(L10n.text("Unlocked"), "Unlocked")
    }
}
