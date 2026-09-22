import Foundation
import Testing
@testable import Hisingen

@Suite("FuelFillUpValidation")
struct FuelFillUpValidationTests {
    @Test func validEntryParsesAllFields() {
        let v = FuelFillUpValidation.validate(volumeText: "42.5", priceText: "1,89", odometerText: "12 340")
        #expect(v.isValid)
        #expect(v.liters == 42.5)
        #expect(v.pricePerLiter == 1.89)
        #expect(v.odometerKm == 12340)
    }

    @Test func volumeMustBeGreaterThanZero() {
        #expect(FuelFillUpValidation.validate(volumeText: "0", priceText: "1", odometerText: "").invalidFields == [.volume])
        #expect(FuelFillUpValidation.validate(volumeText: "-3", priceText: "1", odometerText: "").invalidFields == [.volume])
        #expect(FuelFillUpValidation.validate(volumeText: "", priceText: "1", odometerText: "").invalidFields == [.volume])
        #expect(FuelFillUpValidation.validate(volumeText: "litres", priceText: "1", odometerText: "").invalidFields == [.volume])
    }

    @Test func priceMayBeZeroButNotNegativeOrGarbage() {
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "0", odometerText: "").isValid)
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "-1", odometerText: "").invalidFields == [.price])
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "", odometerText: "").invalidFields == [.price])
    }

    @Test func odometerIsOptionalButMustBeANumberWhenPresent() {
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "1", odometerText: "").isValid)
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "1", odometerText: "  ").isValid)
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "1", odometerText: "-5").invalidFields == [.odometer])
        #expect(FuelFillUpValidation.validate(volumeText: "10", priceText: "1", odometerText: "abc").invalidFields == [.odometer])
    }

    @Test func multipleFieldReasonsAreReportedTogether() {
        let v = FuelFillUpValidation.validate(volumeText: "", priceText: "", odometerText: "x")
        #expect(v.invalidFields == [.volume, .price, .odometer])
        #expect(v.reason(for: .volume) != nil)
        #expect(v.reason(for: .price) != nil)
        #expect(v.reason(for: .odometer) != nil)
    }
}
