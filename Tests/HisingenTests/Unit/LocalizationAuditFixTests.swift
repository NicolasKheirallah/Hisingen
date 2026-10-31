import Foundation
import Testing
@testable import Hisingen

@MainActor
struct LocalizationAuditFixTests {
    @Test
    func koreanHistorySlopePreservesArgumentTypesAndOrder() {
        let value = L10n.format(
            "Cold raises consumption by about %@ per 10 °C, across %d trips.",
            languageCode: "ko", "12%", 37)
        #expect(value.contains("12%"))
        #expect(value.contains("37"))
        #expect(!value.contains("%@"))
    }

    @Test
    func hiddenTripDisclosureHasMeaningfulLabelsAndCountsInEveryLanguage() {
        for language in ["da", "de", "es", "fi", "fr", "it", "ko", "nb", "nl", "nn", "no", "pl", "pt", "sv", "zh"] {
            let label = L10n.format("Hidden trips (%d)", languageCode: language, 37)
            #expect(label.contains("37"), "Missing trip count for \(language)")
            #expect(label.count > 5, "Missing disclosure name for \(language)")
            #expect(label != "Hidden trips (37)", "Untranslated disclosure for \(language)")
        }
    }
}
