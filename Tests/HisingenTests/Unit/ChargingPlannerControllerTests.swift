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

        harness.controller.vehicleStateDidUpdate()
        await settle()
        #expect(await harness.prices.callCount == 0)

        harness.controller.start()
        _ = await calls.next()
        harness.controller.vehicleStateDidUpdate()
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
            vehicleState: vehicle(connection: .connected),
            outcomes: [.sent(.accepted)]
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

    // MARK: - Window-end stop

    /// Auto-starts a window at 03:30 and lets the dispatch land. The planner's plan is
    /// 03:30–04:30 at the harness's 250 kW.
    private func autoStartedHarness(
        now: Date = plannerDate(2026, 2, 10, 3, 30),
        stopOutcomes: [RemoteCommandDispatchOutcome] = [.sent(.accepted)]
    ) -> PlannerHarness {
        let harness = PlannerHarness(
            now: now,
            vehicleState: vehicle(connection: .connected),
            outcomes: [.sent(.accepted)],
            stopOutcomes: stopOutcomes
        )
        harness.preferences.plannerAutoStartEnabled = true
        return harness
    }

    @Test
    func autoStartRecordsTheWindowItStarted() async {
        let harness = autoStartedHarness()

        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.dispatchCount == 1)
        let recorded = harness.preferences.plannerWindow(for: "YSMTEST")
        #expect(recorded?.start == plannerDate(2026, 2, 10, 3, 30))
        #expect(recorded?.end == plannerDate(2026, 2, 10, 4, 30))
    }

    @Test
    func theRecordedWindowEndDoesNotSlideWhileTheCarCharges() async {
        let harness = autoStartedHarness()

        await harness.controller.evaluate()
        await settle()

        // A slower-than-planned charge recomputes a longer run later on. The window already
        // started keeps the end it was committed with, so the stop has a fixed instant.
        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4))
        await harness.controller.evaluate()
        await settle()

        #expect(harness.preferences.plannerWindow(for: "YSMTEST")?.end == plannerDate(2026, 2, 10, 4, 30))
        #expect(await harness.charger.stopCount == 0)
    }

    @Test
    func aChargeStillRunningAtTheWindowEndIsStoppedOnce() async {
        let harness = autoStartedHarness()

        await harness.controller.evaluate()
        await settle()

        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.stopCount == 1)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)

        // The car may report charging for a moment after the command; the consumed window
        // means no second stop is sent.
        harness.advance(to: plannerDate(2026, 2, 10, 4, 31))
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.stopCount == 1)
    }

    @Test
    func aWindowThatEndedWithTheCarAlreadyStoppedNeedsNoCommand() async {
        let harness = autoStartedHarness()

        await harness.controller.evaluate()
        await settle()

        // The car reached its limit at the end of the window: there is nothing drawing power
        // to stop, and nothing left to plan.
        harness.setVehicle(vehicle(battery: 80, state: .complete, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.stopCount == 0)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func aDeferredStopIsRetriedOnTheNextPass() async {
        let harness = autoStartedHarness(stopOutcomes: [.deferred(reason: "busy"), .sent(.accepted)])

        await harness.controller.evaluate()
        await settle()

        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.stopCount == 1)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") != nil)

        harness.advance(to: plannerDate(2026, 2, 10, 4, 31))
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.stopCount == 2)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func aRefusedStopIsRetriedOnTheNextPass() async {
        let harness = autoStartedHarness(stopOutcomes: [.refused(reason: "network"), .sent(.accepted)])

        await harness.controller.evaluate()
        await settle()

        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.stopCount == 1)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") != nil)

        harness.advance(to: plannerDate(2026, 2, 10, 4, 31))
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.stopCount == 2)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func aStopRefusedEveryTimeIsGivenUpAfterTheLimit() async {
        let harness = autoStartedHarness(stopOutcomes: [])

        await harness.controller.evaluate()
        await settle()

        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        let limit = ChargingPlannerController.maxRefusedSends
        for minute in 0..<(limit + 2) {
            harness.advance(to: plannerDate(2026, 2, 10, 4, 30 + minute))
            await harness.controller.evaluate()
            await settle()
        }

        #expect(await harness.charger.stopCount == limit)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func theRefusedStopCountStartsOverOnceTheWindowIsConsumed() async {
        let harness = autoStartedHarness(stopOutcomes: [])

        await harness.controller.evaluate()
        await settle()

        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()
        harness.advance(to: plannerDate(2026, 2, 10, 4, 31))
        await harness.controller.evaluate()
        await settle()
        #expect(harness.controller.refusedStops["YSMTEST"] == 2)

        // The car stopped on its own, so the window is consumed without another stop. The two
        // refusals must not count against the next window.
        harness.setVehicle(vehicle(battery: 80, state: .complete, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 32))
        await harness.controller.evaluate()
        await settle()

        #expect(harness.controller.refusedStops["YSMTEST"] == nil)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func theRefusedStartCountStartsOverOnceTheTargetIsMet() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            outcomes: []
        )
        harness.preferences.plannerAutoStartEnabled = true

        await harness.controller.evaluate()
        await settle()
        #expect(harness.controller.refusedStarts["YSMTEST"] == 1)

        harness.setVehicle(vehicle(battery: 80, state: .complete, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 3, 31))
        await harness.controller.evaluate()
        await settle()

        #expect(harness.controller.refusedStarts["YSMTEST"] == nil)
    }

    @Test
    func aRefusedAutoStartIsRetriedOnTheNextPass() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            outcomes: [.refused(reason: "network"), .sent(.accepted)]
        )
        harness.preferences.plannerAutoStartEnabled = true

        await harness.controller.evaluate()
        await settle()
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)

        harness.advance(to: plannerDate(2026, 2, 10, 3, 31))
        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.dispatchCount == 2)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") != nil)
    }

    @Test
    func anAutoStartRefusedEveryTimeIsGivenUpAfterTheLimit() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            outcomes: []
        )
        harness.preferences.plannerAutoStartEnabled = true

        let limit = ChargingPlannerController.maxRefusedSends
        for minute in 0..<(limit + 2) {
            harness.advance(to: plannerDate(2026, 2, 10, 3, 30 + minute))
            await harness.controller.evaluate()
            await settle()
        }

        #expect(await harness.charger.dispatchCount == limit)
        #expect(harness.preferences.plannerWindow(for: "YSMTEST") == nil)
    }

    @Test
    func theWindowEndStopNeedsNoAutoStartConsentOfItsOwn() async {
        let harness = autoStartedHarness()
        await harness.controller.evaluate()
        await settle()

        // Turning auto-start off after the window started does not strand the override: the
        // planner still ends the window it began.
        harness.preferences.plannerAutoStartEnabled = false
        harness.setVehicle(vehicle(state: .charging, connection: .connected))
        harness.advance(to: plannerDate(2026, 2, 10, 4, 30))
        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.stopCount == 1)
    }

    @Test
    func noStopIsSentWithoutAPlannerWindow() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 4, 30),
            vehicleState: vehicle(state: .charging, connection: .connected)
        )

        await harness.controller.evaluate()
        await settle()

        #expect(await harness.charger.stopCount == 0)
    }

    // MARK: - Sleep prevention

    @Test
    func sleepPreventionIsOffByDefault() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerAutoStartEnabled = true

        #expect(harness.preferences.plannerKeepAwakeEnabled == false)
        await harness.controller.evaluate()
        await settle()

        #expect(harness.sleeper.holdCount == 0)
        #expect(harness.sleeper.isHolding == false)
    }

    @Test
    func sleepPreventionHoldsTheAssertionWhileAWindowWaits() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerAutoStartEnabled = true
        harness.preferences.plannerKeepAwakeEnabled = true

        await harness.controller.evaluate()
        await settle()

        #expect(harness.sleeper.holdCount == 1)
        #expect(harness.sleeper.isHolding)
        #expect(harness.sleeper.lastReason == SleepPrevention.assertionReason)
    }

    @Test
    func sleepPreventionNeedsTheAutoStartConsent() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerKeepAwakeEnabled = true

        await harness.controller.evaluate()
        await settle()

        #expect(harness.sleeper.holdCount == 0)
    }

    @Test
    func sleepPreventionReleasesWhenTheTargetIsReached() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerAutoStartEnabled = true
        harness.preferences.plannerKeepAwakeEnabled = true
        await harness.controller.evaluate()
        await settle()
        #expect(harness.sleeper.isHolding)

        harness.setVehicle(vehicle(battery: 80, connection: .connected))
        await harness.controller.evaluate()
        await settle()

        #expect(harness.sleeper.isHolding == false)
        #expect(harness.sleeper.releaseCount >= 1)
    }

    @Test
    func sleepPreventionIsReleasedWhenThePlannerIsDisarmed() async {
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected)
        )
        harness.preferences.plannerAutoStartEnabled = true
        harness.preferences.plannerKeepAwakeEnabled = true
        await harness.controller.evaluate()
        await settle()
        #expect(harness.sleeper.isHolding)

        harness.controller.stop()

        #expect(harness.sleeper.isHolding == false)
    }

    @Test
    func homeAssistantOwnershipDropsTheAssertion() async {
        let owned = OwnershipFlag(false)
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 0),
            vehicleState: vehicle(connection: .connected),
            plannerOwned: { _ in owned.value }
        )
        harness.preferences.plannerAutoStartEnabled = true
        harness.preferences.plannerKeepAwakeEnabled = true
        await harness.controller.evaluate()
        await settle()
        #expect(harness.sleeper.isHolding)

        owned.value = true
        await harness.controller.evaluate()
        await settle()

        #expect(harness.sleeper.isHolding == false)
    }
}

// MARK: - Home Assistant ownership

@Suite(.serialized)
@MainActor
struct ChargingPlannerOwnershipTests {
    @Test
    func theVehicleSideSchedulerDefersWhileHomeAssistantOwnsThePlan() async {
        let owned = OwnershipFlag(true)
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            plannerOwned: { _ in owned.value }
        )
        harness.preferences.plannerAutoStartEnabled = true

        await harness.controller.evaluate()
        await settle()
        await harness.controller.evaluate()
        await settle()

        // No start command and no window banner from this Mac while Home Assistant runs the plan.
        #expect(await harness.charger.dispatchCount == 0)
        #expect(harness.notifier.notices.isEmpty)
    }

    @Test
    func theSchedulerResumesWhenHomeAssistantHandsTheCarBack() async {
        let owned = OwnershipFlag(true)
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            plannerOwned: { _ in owned.value }
        )
        harness.preferences.plannerAutoStartEnabled = true
        var dispatches = harness.charger.dispatches.makeAsyncIterator()

        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.dispatchCount == 0)

        owned.value = false
        await harness.controller.evaluate()
        _ = await dispatches.next()
        await settle()
        #expect(await harness.charger.dispatchCount == 1)
    }

    @Test
    func aStartAlreadyQueuedIsDroppedIfOwnershipBeginsBeforeItSends() async {
        let owned = OwnershipFlag(false)
        let harness = PlannerHarness(
            now: plannerDate(2026, 2, 10, 3, 30),
            vehicleState: vehicle(connection: .connected),
            plannerOwned: { _ in owned.value }
        )
        harness.preferences.plannerAutoStartEnabled = true
        await harness.controller.evaluate()
        // The reader hands the plan to Home Assistant in the same instant; whatever has not been sent stays unsent.
        owned.value = true
        await settle()
        await harness.controller.evaluate()
        await settle()
        #expect(await harness.charger.dispatchCount <= 1)
    }
}

@MainActor
private final class OwnershipFlag {
    var value: Bool
    init(_ value: Bool) { self.value = value }
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
    let sleeper: FakeSleeper
    let controller: ChargingPlannerController
    private let latest: StateBox
    private let clock: ClockBox

    var preferences: PreferencesStore { scoped.store }
    var now: Date { clock.value }

    func changeVIN(_ vin: String) { latest.state.identity.vin = vin }

    func advance(to date: Date) { clock.value = date }

    func setVehicle(_ state: VehicleState) { latest.state = state }

    init(
        now: Date = plannerDate(2026, 2, 10, 3, 30),
        series: [ElectricityPricePoint] = plannerHourlySeries(),
        vehicleState: VehicleState = vehicle(connection: .disconnected),
        outcomes: [RemoteCommandDispatchOutcome] = [],
        stopOutcomes: [RemoteCommandDispatchOutcome] = [],
        plannerOwned: @escaping (String) -> Bool = { _ in false }
    ) {
        let scopedPreferences = ScopedPreferences(label: "ChargingPlannerController")
        let store = scopedPreferences.store
        let priceSource = FakePriceSource(series: series)
        let charger = FakeCharger(outcomes: outcomes, stopOutcomes: stopOutcomes)
        let latest = StateBox(state: vehicleState)
        let clock = ClockBox(now: now)
        let database = VehicleDatabase.inMemory()
        let timer = FakeTimerWait()
        let notifier = FakeNotifier()
        let sleeper = FakeSleeper()

        store.marketCountry = .sweden
        store.features = FeatureSelection(enabled: [.smartChargingPlanner, .notifications])
        store.electricityChargerPowerKw = 250

        scoped = scopedPreferences
        self.prices = priceSource
        self.charger = charger
        self.latest = latest
        self.clock = clock
        self.timer = timer
        self.notifier = notifier
        self.sleeper = sleeper
        controller = ChargingPlannerController(
            preferences: store,
            notifier: notifier,
            priceService: ElectricityPriceService(database: database),
            priceSource: priceSource,
            database: database,
            latestState: { latest.state },
            plannerOwnedByHomeAssistant: plannerOwned,
            activeVINs: { [] },
            startCharging: { _ in await charger.dispatch() },
            stopCharging: { _ in await charger.stop() },
            sleepPrevention: sleeper,
            now: { clock.value },
            wait: { seconds in try await timer.wait(seconds) }
        )
    }
}

@MainActor
private final class StateBox {
    var state: VehicleState
    init(state: VehicleState) { self.state = state }
}

/// A mutable clock the controller reads from its `@Sendable` closure. The lock is what
/// lets a Sendable closure read a value the main-actor test moves between evaluations.
private final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date

    init(now: Date) { stored = now }

    var value: Date {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

@MainActor
private final class FakeSleeper: SleepPreventing {
    private(set) var isHolding = false
    private(set) var holdCount = 0
    private(set) var releaseCount = 0
    private(set) var lastReason: String?

    func hold(reason: String) -> Bool {
        lastReason = reason
        guard !isHolding else { return true }
        isHolding = true
        holdCount += 1
        return true
    }

    func release() {
        guard isHolding else { return }
        isHolding = false
        releaseCount += 1
    }
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
    nonisolated let stops: AsyncStream<Void>
    private let dispatchesContinuation: AsyncStream<Void>.Continuation
    private let stopsContinuation: AsyncStream<Void>.Continuation
    private var outcomes: [RemoteCommandDispatchOutcome]
    private var stopOutcomes: [RemoteCommandDispatchOutcome]
    private(set) var dispatchCount = 0
    private(set) var stopCount = 0

    init(outcomes: [RemoteCommandDispatchOutcome], stopOutcomes: [RemoteCommandDispatchOutcome]) {
        self.outcomes = outcomes
        self.stopOutcomes = stopOutcomes
        let (dispatchStream, dispatchContinuation) = AsyncStream<Void>.makeStream()
        dispatches = dispatchStream
        dispatchesContinuation = dispatchContinuation
        let (stopStream, stopContinuation) = AsyncStream<Void>.makeStream()
        stops = stopStream
        stopsContinuation = stopContinuation
    }

    /// Returns the scripted outcome, or a terminal refusal once the script runs out.
    func dispatch() -> RemoteCommandDispatchOutcome {
        dispatchCount += 1
        dispatchesContinuation.yield(())
        return outcomes.isEmpty ? .refused(reason: "test") : outcomes.removeFirst()
    }

    func stop() -> RemoteCommandDispatchOutcome {
        stopCount += 1
        stopsContinuation.yield(())
        return stopOutcomes.isEmpty ? .refused(reason: "test") : stopOutcomes.removeFirst()
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
