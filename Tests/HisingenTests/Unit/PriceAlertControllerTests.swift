import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct PriceAlertControllerTests {

    @Test
    func startArmsTheTickAndEvaluatesImmediately() async {
        let harness = PriceAlertHarness()
        harness.controller.start()
        for _ in 0..<200 {
            if await harness.prices.resolveCount > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await harness.prices.resolveCount == 1)
        #expect(harness.controller.isArmed)
        harness.controller.stop()
    }

    @Test
    func stopDisarmsTheTick() async {
        let harness = PriceAlertHarness()
        harness.controller.start()
        await settle()
        harness.controller.stop()
        #expect(harness.controller.isArmed == false)
    }

    @Test
    func reloadArmsOnlyWhileAutomaticPricingAndTheAlertAreOn() async {
        let harness = PriceAlertHarness()
        harness.controller.reload()
        #expect(harness.controller.isArmed)

        harness.preferences.electricityRateMode = .fixed
        harness.controller.reload()
        #expect(harness.controller.isArmed == false)

        harness.preferences.electricityRateMode = .automatic
        harness.preferences.notifyPriceThreshold = false
        harness.controller.reload()
        #expect(harness.controller.isArmed == false)

        harness.preferences.notifyPriceThreshold = true
        harness.controller.reload()
        #expect(harness.controller.isArmed)
        harness.controller.stop()
    }

    @Test
    func notificationsSwitchedOffDisarmTheTick() async {
        let harness = PriceAlertHarness()
        harness.preferences.features = FeatureSelection(enabled: [])
        harness.controller.reload()
        #expect(harness.controller.isArmed == false)
    }

    @Test
    func aCrossingPostsOneAlertAndRecordsTheSlot() async {
        let harness = PriceAlertHarness()
        harness.controller.start()
        await waitForPost(harness)

        #expect(harness.notifier.posts.count == 1)
        #expect(harness.notifier.posts.first?.zone == .se3)
        #expect(harness.notifier.posts.first?.slotStart == alertDate(10))
        #expect(harness.preferences.priceAlertLastAlertedAt(for: .se3) == harness.now)
        #expect(harness.preferences.priceAlertLastSlotStart(for: .se3) == alertDate(10))
        harness.controller.stop()
    }

    @Test
    func aSecondEvaluationInTheSameHourPostsNothing() async {
        let harness = PriceAlertHarness()
        await harness.controller.evaluate()
        await harness.controller.evaluate()
        #expect(harness.notifier.posts.count == 1)
    }

    @Test
    func aMissingPriceSeriesPostsNothingAndRecordsNoStamp() async {
        let harness = PriceAlertHarness(prices: [])
        await harness.controller.evaluate()
        #expect(harness.notifier.posts.isEmpty)
        #expect(harness.preferences.priceAlertLastAlertedAt(for: .se3) == nil)
        #expect(harness.preferences.priceAlertLastSlotStart(for: .se3) == nil)
    }

    @Test
    func anUnsetPriceLevelPostsNothing() async {
        let harness = PriceAlertHarness()
        harness.preferences.priceAlertThresholdSekPerKwh = 0
        await harness.controller.evaluate()
        #expect(harness.notifier.posts.isEmpty)
    }

    @Test
    func theAlertBodyCarriesThePriceAndTheReadersLevel() async {
        let harness = PriceAlertHarness()
        await harness.controller.evaluate()
        let body = harness.notifier.posts.first?.body ?? ""
        #expect(body.contains("1.50"))
        #expect(body.contains("1.00"))
    }
}

@MainActor
private final class PriceAlertHarness {
    let scoped: ScopedPreferences
    let prices: FakePriceAlertSource
    let notifier: FakePriceAlertNotifier
    let controller: PriceAlertController
    let now = alertDate(10, 5)

    var preferences: PreferencesStore { scoped.store }

    init(prices series: [ElectricityPricePoint]? = nil) {
        let scoped = ScopedPreferences(label: "PriceAlertController")
        let store = scoped.store
        store.marketCountry = .sweden
        store.features = FeatureSelection(enabled: [.notifications, .smartChargingPlanner])
        store.electricityRateMode = .automatic
        store.notifyPriceThreshold = true
        store.priceAlertThresholdSekPerKwh = 1.0
        store.electricityPriceZone = .se3
        store.electricityIncludesVAT = false

        let points = series ?? alertHourly([0.4, 0.5, 1.5, 1.5], from: 8)
        let source = FakePriceAlertSource(prices: PlannerPrices(
            points: points, origin: .elpriser, fetchedAt: nil,
            tibberConnected: false, tibberProblem: nil
        ))
        let notifier = FakePriceAlertNotifier()
        self.scoped = scoped
        self.prices = source
        self.notifier = notifier
        controller = PriceAlertController(
            preferences: store, notifier: notifier, priceSource: source,
            now: { alertDate(10, 5) }
        )
    }
}

@MainActor
private final class FakePriceAlertNotifier: PriceAlertNotifying {
    private(set) var posts: [(title: String, body: String, zone: ElspotZone, slotStart: Date)] = []

    func notifyPriceAlert(title: String, body: String, zone: ElspotZone, slotStart: Date) {
        posts.append((title, body, zone, slotStart))
    }
}

private actor FakePriceAlertSource: PriceAlertPriceProviding {
    private let prices: PlannerPrices
    private(set) var resolveCount = 0

    init(prices: PlannerPrices) {
        self.prices = prices
    }

    func resolve(zone: ElspotZone) async -> PlannerPrices {
        resolveCount += 1
        return prices
    }
}

private func settle() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

/// The immediate evaluation is a separate task; wait for its effect instead of assuming it ran
/// inside a fixed number of yields.
@MainActor
private func waitForPost(_ harness: PriceAlertHarness) async {
    for _ in 0..<200 {
        if !harness.notifier.posts.isEmpty { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
}

private let alertCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar
}()

private func alertDate(_ hour: Int, _ minute: Int = 0) -> Date {
    alertCalendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: hour, minute: minute))!
}

private func alertPoint(_ startHour: Int, minutes: Int, price: Double) -> ElectricityPricePoint {
    let start = alertDate(startHour)
    return ElectricityPricePoint(startDate: start, endDate: start.addingTimeInterval(TimeInterval(minutes * 60)),
                                 sekPerKwh: price)
}

private func alertHourly(_ prices: [Double], from hour: Int) -> [ElectricityPricePoint] {
    prices.enumerated().map { index, price in
        alertPoint(hour + index, minutes: 60, price: price)
    }
}
