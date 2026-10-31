import Foundation
import Testing
@testable import Hisingen

@Suite(.serialized)
@MainActor
struct ChargingPlannerControllerTests {

    // MARK: - Lifecycle

    @Test
    func startArmsTheMinuteTickAndEvaluatesImmediately() async {
        let harness = PlannerHarness()
        var calls = harness.prices.calls.makeAsyncIterator()
        var waits = harness.timer.requested.makeAsyncIterator()

        harness.controller.start()

        _ = await calls.next()
        #expect(await waits.next() == ChargingPlannerController.tickInterval)
        #expect(harness.controller.isArmed)
    }

    @Test
    func stopDisarmsTheTick() async {
        let harness = PlannerHarness()
        var calls = harness.prices.calls.makeAsyncIterator()

        harness.controller.start()
        _ = await calls.next()
        harness.controller.stop()

        #expect(harness.controller.isArmed == false)
    }

    @Test
    func secondStartWhileArmedDoesNotArmAnotherTick() async {
        let harness = PlannerHarness()
        var calls = harness.prices.calls.makeAsyncIterator()
        var waits = harness.timer.requested.makeAsyncIterator()

        harness.controller.start()
        _ = await calls.next()
        _ = await waits.next()
        harness.controller.start()
        await settle()

        #expect(await harness.timer.waitCount == 1)
    }

    @Test
    func reloadArmsWhenPlannerIsAvailableAndDisarmsWhenItIsNot() async {
        let harness = PlannerHarness()

        harness.controller.reload()
        #expect(harness.controller.isArmed)

        harness.preferences.marketCountry = .other
        harness.controller.reload()
        #expect(harness.controller.isArmed == false)
    }

    @Test
    func vehicleStateUpdateEvaluatesOnlyWhileArmed() async {
        let harness = PlannerHarness()
        var calls = harness.prices.calls.makeAsyncIterator()

        harness.controller.vehicleStateDidUpdate(vehicle(connection: .disconnected))
        await settle()
        #expect(await harness.prices.callCount == 0)

        harness.controller.start()
        _ = await calls.next()
        harness.controller.vehicleStateDidUpdate(vehicle(connection: .disconnected))
        _ = await calls.next()
        #expect(await harness.prices.callCount == 2)
    }

    @Test
    func plannerWithoutPriceSeriesDoesNothingElse() async {
        let harness = PlannerHarness(series: [])

        await harness.controller.evaluate()

        #expect(harness.notifier.notices.isEmpty)
        #expect(await harness.charger.dispatchCount == 0)
    }

    @Test
    func suspendedEvaluationStopsAfterDisableZoneChangeOrVehicleSwitch() async {
        for change in 0..<3 {
            let harness = PlannerHarness(vehicleState: vehicle(connection: .connected))
            harness.preferences.plannerAutoStartEnabled = true
            await harness.prices.suspendNext()
            var calls = harness.prices.calls.makeAsyncIterator()
            let evaluation = Task { await harness.controller.evaluate() }
            _ = await calls.next()
            switch change {
            case 0:
                harness.preferences.marketCountry = .other
                harness.controller.reload()
            case 1:
                harness.preferences.electricityPriceZone = .se1
            default:
                harness.changeVIN("OTHER-VIN")
            }
            await harness.prices.resume()
            await evaluation.value
            await settle()
            #expect(await harness.charger.dispatchCount == 0)
            #expect(harness.notifier.notices.isEmpty)
        }
    }

    // MARK: - Window-start banner

    @Test
    func windowBannerPostsOnceInsideTheLeadWindow() async {
        let harness = PlannerHarness(now: plannerDate(2026, 2, 10, 3, 30))

        await harness.controller.evaluate()
        #expect(harness.notifier.notices.count == 1)
        #expect(harness.notifier.notices.first?.title == L10n.text("Charging Planner"))
        #expect(harness.notifier.notices.first?.body.contains(Format.shortTime(date: plannerDate(2026, 2, 10, 3, 30))) == true)

        // The same window is already announced, so a later pass stays quiet.
        await harness.controller.evaluate()
        #expect(harness.notifier.notices.count == 1)
    }

    @Test
    func windowBannerWaitsUntilTheLeadWindowOpens() async {
        // From midnight the cheapest hour starts at 03:00, well outside the 15-minute lead.
        let harness = PlannerHarness(now: plannerDate(2026, 2, 10, 0, 0))

        await harness.controller.evaluate()

        #expect(harness.notifier.notices.isEmpty)
    }

    @Test
    func windowBannerRespectsTheNotificationsFeature() async {
        let harness = PlannerHarness(now: plannerDate(2026, 2, 10, 3, 30))
        harness.preferences.features = FeatureSelection(enabled: [.smartChargingPlanner])

        await harness.controller.evaluate()

        #expect(harness.notifier.notices.isEmpty)
    }

    @Test
    func windowBannerRespectsItsOwnToggle() async {
        let harness = PlannerHarness(now: plannerDate(2026, 2, 10, 3, 30))
        harness.preferences.notifyPlannerWindowStart = false

        await harness.controller.evaluate()

        #expect(harness.notifier.notices.isEmpty)
    }

    // MARK: - Auto-start

    @Test
    func autoStartDispatchesOncePerWindowWhenPluggedIn() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerAutoStartEnabled = true
        var dispatches = harness.charger.dispatches.makeAsyncIterator()

        await harness.controller.evaluate()
        _ = await dispatches.next()
        await settle()

        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.dispatchCount == 1)
    }

    @Test
    func autoStartNeverDispatchesWithoutConsent() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected)
        )

        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.dispatchCount == 0)
    }

    @Test
    func autoStartSkipsAVehicleThatIsNotPluggedIn() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .disconnected)
        )
        harness.preferences.plannerAutoStartEnabled = true

        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.dispatchCount == 0)
    }

    @Test
    func deferredDispatchStaysRetryableOnTheNextPass() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            outcomes: [.deferred(reason: "busy"), .refused(reason: "stop")]
        )
        harness.preferences.plannerAutoStartEnabled = true
        var dispatches = harness.charger.dispatches.makeAsyncIterator()

        await harness.controller.evaluate()
        _ = await dispatches.next()
        await settle()

        await harness.controller.evaluate()
        _ = await dispatches.next()
        await settle()

        #expect(await harness.charger.dispatchCount == 2)
    }
}

// MARK: - Harness

/// Wires the controller to fakes. Everything is pinned: the clock, the price series, the
/// timer wait, the charger, and an in-memory database.
@MainActor
private final class PlannerHarness {
    let scoped: ScopedPreferences
    let notifier: FakeNotifier
    let prices: FakePriceSource
    let timer: FakeTimerWait
    let charger: FakeCharger
    let controller: ChargingPlannerController
    private let latest: StateBox

    var preferences: PreferencesStore { scoped.store }

    func changeVIN(_ vin: String) { latest.state.identity.vin = vin }

    init(
        now: Date = plannerDate(2026, 2, 10, 3, 30),
        series: [ElectricityPricePoint] = plannerHourlySeries(),
        vehicleState: VehicleState = vehicle(connection: .disconnected),
        outcomes: [RemoteCommandDispatchOutcome] = []
    ) {
        let scopedPreferences = ScopedPreferences(label: "ChargingPlannerController")
        let store = scopedPreferences.store
        let priceSource = FakePriceSource(series: series)
        let charger = FakeCharger(outcomes: outcomes)
        let latest = StateBox(state: vehicleState)
        let database = VehicleDatabase.inMemory()
        let timer = FakeTimerWait()
        let notifier = FakeNotifier()

        store.marketCountry = .sweden
        store.features = FeatureSelection(enabled: [.smartChargingPlanner, .notifications])
        store.electricityChargerPowerKw = 250

        scoped = scopedPreferences
        self.prices = priceSource
        self.charger = charger
        self.latest = latest
        self.timer = timer
        self.notifier = notifier
        controller = ChargingPlannerController(
            preferences: store,
            notifier: notifier,
            priceService: ElectricityPriceService(database: database),
            priceSource: priceSource,
            database: database,
            latestState: { latest.state },
            activeVINs: { [] },
            startCharging: { _ in await charger.dispatch() },
            now: { now },
            wait: { seconds in try await timer.wait(seconds) }
        )
    }
}

@MainActor
private final class StateBox {
    var state: VehicleState
    init(state: VehicleState) { self.state = state }
}

@MainActor
private final class FakeNotifier: ChargingPlannerNotifying {
    private(set) var notices: [(title: String, body: String)] = []

    func notifyCommandNotice(title: String, body: String, subtitle: String?) {
        notices.append((title, body))
    }
}

private actor FakePriceSource: ChargingPlannerPriceSource {
    private let series: [ElectricityPricePoint]
    nonisolated let calls: AsyncStream<Void>
    private let callsContinuation: AsyncStream<Void>.Continuation
    private(set) var callCount = 0
    private var shouldSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?

    func suspendNext() { shouldSuspend = true }
    func resume() { continuation?.resume(); continuation = nil }

    init(series: [ElectricityPricePoint]) {
        self.series = series
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        calls = stream
        callsContinuation = continuation
    }

    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint] {
        callCount += 1
        callsContinuation.yield(())
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation = $0 }
        }
        return series
    }

    func fetchedAt(for zone: ElspotZone) async -> Date? {
        nil
    }
}

private actor FakeCharger {
    nonisolated let dispatches: AsyncStream<Void>
    private let dispatchesContinuation: AsyncStream<Void>.Continuation
    private var outcomes: [RemoteCommandDispatchOutcome]
    private(set) var dispatchCount = 0

    init(outcomes: [RemoteCommandDispatchOutcome]) {
        self.outcomes = outcomes
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        dispatches = stream
        dispatchesContinuation = continuation
    }

    /// Returns the scripted outcome, or a terminal refusal once the script runs out.
    func dispatch() -> RemoteCommandDispatchOutcome {
        dispatchCount += 1
        dispatchesContinuation.yield(())
        return outcomes.isEmpty ? .refused(reason: "test") : outcomes.removeFirst()
    }
}

/// Stands in for the tick's `Task.sleep`. Each wait announces its duration and then parks
/// until cancelled, so the tick never fires on its own during a test.
private actor FakeTimerWait {
    nonisolated let requested: AsyncStream<TimeInterval>
    private let requestedContinuation: AsyncStream<TimeInterval>.Continuation
    private var parked: [CheckedContinuation<Void, Error>] = []
    private(set) var waitCount = 0

    init() {
        let (stream, continuation) = AsyncStream<TimeInterval>.makeStream()
        requested = stream
        requestedContinuation = continuation
    }

    func wait(_ seconds: TimeInterval) async throws {
        waitCount += 1
        requestedContinuation.yield(seconds)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { parked.append($0) }
        } onCancel: {
            Task { await self.cancelParked() }
        }
    }

    private func cancelParked() {
        let waiting = parked
        parked = []
        for continuation in waiting {
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// Lets the fire-and-forget tasks the controller spawns reach their next suspension point.
/// Used only after the controller returns, where no other signal exists.
@MainActor
private func settle() async {
    for _ in 0..<20 {
        await Task.yield()
    }
}

private let plannerCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar
}()

/// A fixed wall-clock instant in Stockholm time.
private func plannerDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    plannerCalendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// Hourly prices for 2026-02-10. Hour 03 is the only cheap slot, so from 03:30 the cheapest
/// one-hour window opens at 03:30 and from midnight it opens at 03:00.
private func plannerHourlySeries() -> [ElectricityPricePoint] {
    let start = plannerDate(2026, 2, 10, 0)
    return (0..<24).map { hour in
        let from = start.addingTimeInterval(Double(hour) * 3_600)
        return ElectricityPricePoint(
            startDate: from,
            endDate: from.addingTimeInterval(3_600),
            sekPerKwh: hour == 3 ? 0.1 : 2.0
        )
    }
}
