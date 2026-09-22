import Testing
@testable import Hisingen

struct SettingsAccountTests {
    @Test
    func accountValidationRejectsMalformedIdentityFields() {
        #expect(SettingsValidation.isValidEmail("driver@example.com"))
        #expect(!SettingsValidation.isValidEmail("driver@example"))
        #expect(!SettingsValidation.isValidEmail("driver @example.com"))
        #expect(SettingsValidation.isValidOptionalVIN(""))
        #expect(SettingsValidation.isValidOptionalVIN("YSM12345678901234"))
        #expect(!SettingsValidation.isValidOptionalVIN("YSM123"))
        #expect(!SettingsValidation.isValidOptionalVIN("YSM1234567890I234"))
        // The optional form normalizes what the reader typed; the strict form the APIs gate
        // on does not, so the same VIN splits across the two exactly at that difference.
        #expect(SettingsValidation.isValidOptionalVIN(" ysm12345678901234\n"))
        #expect(!SettingsValidation.isValidVIN("ysm12345678901234"))
        #expect(!SettingsValidation.isValidVIN(" YSM12345678901234"))
    }

    @Test
    func numericAndCurrencyDraftValidationIsBounded() {
        #expect(SettingsValidation.isValidElectricityPrice("0.01"))
        #expect(SettingsValidation.isValidElectricityPrice("1,000.00"))
        #expect(!SettingsValidation.isValidElectricityPrice("0"))
        #expect(!SettingsValidation.isValidElectricityPrice("1001"))
        #expect(SettingsValidation.isValidCurrencySymbol("SEK"))
        #expect(!SettingsValidation.isValidCurrencySymbol(""))
        #expect(!SettingsValidation.isValidCurrencySymbol("TOO-LONG-CODE"))
    }
}
