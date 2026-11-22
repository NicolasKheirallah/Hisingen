import Foundation
import Testing
@testable import Hisingen

private let stockholm: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    stockholm.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: hour, minute: minute))!
}

private func point(_ startHour: Int, _ startMinute: Int, minutes: Int, price: Double) -> ElectricityPricePoint {
    let start = at(startHour, startMinute)
    return ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                 sekPerKwh: price)
}

private func hourly(_ prices: [Double], from hour: Int) -> [ElectricityPricePoint] {
    prices.enumerated().map { index, price in
        point(hour + index, 0, minutes: 60, price: price)
    }
}

private func quarters(_ prices: [Double], from hour: Int) -> [ElectricityPricePoint] {
    prices.enumerated().map { index, price in
        point(hour + index / 4, (index % 4) * 15, minutes: 15, price: price)
    }
}

private func policy(vat: Bool = false, contract: ElectricityPriceContract = .quarterHour) -> ElectricityRatePolicy {
    ElectricityRatePolicy(mode: .automatic, provider: .other, contract: contract,
                          markupOrePerKwh: 0, otherChargesOrePerKwh: 0, includesVAT: vat)
}

struct PriceThresholdAlertTests {
    @Test
    func aRiseIntoTheCurrentHourAlertsWithTheCurrentPrice() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.4, 0.5, 1.5, 1.5], from: 8),
            policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0
        )
        guard case .alert(let crossing) = decision else {
            Issue.record("expected an alert, got \(decision)")
            return
        }
        #expect(crossing.window == .current)
        #expect(crossing.slotStart == at(10))
        #expect(crossing.price == 1.5)
    }

    @Test
    func theLevelIsComparedWithThePriceAfterTheRatePolicy() {
        // Spot 0.90 is below the level, but with 25% VAT the reader pays 1.125, which is not.
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 0.9], from: 9),
            policy: policy(vat: true), allIn: false, now: at(10, 5), threshold: 1.0
        )
        guard case .alert(let crossing) = decision else {
            Issue.record("expected an alert, got \(decision)")
            return
        }
        #expect(abs(crossing.price - 1.125) < 0.0001)
    }

    @Test
    func allInPricesAreUsedAsTheyStand() {
        // A Tibber all-in price already carries VAT and fees, so the policy must not add them twice.
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 0.9], from: 9),
            policy: policy(vat: true), allIn: true, now: at(10, 5), threshold: 1.0
        )
        #expect(decision == .belowThreshold)
    }

    @Test
    func aRiseIntoTheNextHourAlertsBeforeItStarts() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 1.5, 1.5], from: 9),
            policy: policy(), allIn: false, now: at(9, 30), threshold: 1.0
        )
        guard case .alert(let crossing) = decision else {
            Issue.record("expected an alert, got \(decision)")
            return
        }
        #expect(crossing.window == .nextHour)
        #expect(crossing.slotStart == at(10))
        #expect(crossing.price == 1.5)
    }

    @Test
    func theNextHourPriceIsTheTimeWeightedAverageOfItsQuarters() {
        let decision = PriceThresholdAlert.evaluate(
            prices: quarters([0.5, 0.5, 0.5, 0.5, 1.0, 2.0, 1.0, 2.0], from: 9),
            policy: policy(), allIn: false, now: at(9, 30), threshold: 1.2
        )
        guard case .alert(let crossing) = decision else {
            Issue.record("expected an alert, got \(decision)")
            return
        }
        #expect(crossing.window == .nextHour)
        #expect(abs(crossing.price - 1.5) < 0.0001)
    }

    @Test
    func aPartlyCoveredNextHourKeepsNoPriceAndNoAlert() {
        // The 10:00 hour has only its first quarter, so its price is unknown rather than averaged
        // over the one slot that happens to exist.
        let prices = quarters([0.5, 0.5, 0.5, 0.5], from: 9) + [point(10, 0, minutes: 15, price: 2.0)]
        let decision = PriceThresholdAlert.evaluate(
            prices: prices, policy: policy(), allIn: false, now: at(9, 30), threshold: 1.0
        )
        #expect(decision == .belowThreshold)
    }

    @Test
    func aSeriesThatDoesNotReachTheCurrentInstantReportsNoSeries() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.9, 1.5], from: 8), policy: policy(), allIn: false, now: at(12), threshold: 1.0
        )
        #expect(decision == .noSeries)
    }

    @Test
    func anEmptySeriesReportsNoSeriesRatherThanAZeroPrice() {
        let decision = PriceThresholdAlert.evaluate(
            prices: [], policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0
        )
        #expect(decision == .noSeries)
    }

    @Test
    func aRiseFromAPartlyUnknownPreviousHourIsNotAnnounced() {
        // Nothing says the price was below the level before this hour, so no crossing is claimed.
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([1.5, 1.5], from: 10), policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0
        )
        #expect(decision == .belowThreshold)
    }

    @Test
    func anUnsetLevelPostsNothing() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 1.5], from: 9), policy: policy(), allIn: false, now: at(10, 5), threshold: 0
        )
        #expect(decision == .thresholdNotSet)
    }

    @Test
    func aPriceBelowTheLevelPostsNothing() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.4, 0.5], from: 9), policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0
        )
        #expect(decision == .belowThreshold)
    }

    @Test
    func theQuietPeriodSuppressesASecondCrossing() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.4, 0.5, 1.5, 1.5], from: 8),
            policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0,
            quietPeriod: 60 * 60, lastAlertAt: at(9, 50)
        )
        guard case .quietPeriod(let since, let until) = decision else {
            Issue.record("expected a quiet period, got \(decision)")
            return
        }
        #expect(since == at(9, 50))
        #expect(until == at(10, 50))
    }

    @Test
    func aCrossingAlreadyAnnouncedForThisHourStaysQuietEvenAfterTheQuietPeriod() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 1.5], from: 9), policy: policy(), allIn: false, now: at(10, 50), threshold: 1.0,
            quietPeriod: 60 * 60, lastAlertAt: at(10, 1), lastAlertedSlotStart: at(10)
        )
        #expect(decision == .alreadyAnnounced(slotStart: at(10)))
    }

    @Test
    func theQuietPeriodEndsAndALaterCrossingAlertsAgain() {
        let decision = PriceThresholdAlert.evaluate(
            prices: hourly([0.5, 1.5], from: 9), policy: policy(), allIn: false, now: at(10, 5), threshold: 1.0,
            quietPeriod: 60 * 60, lastAlertAt: at(9, 5)
        )
        guard case .alert(let crossing) = decision else {
            Issue.record("expected an alert, got \(decision)")
            return
        }
        #expect(crossing.window == .current)
    }
}
