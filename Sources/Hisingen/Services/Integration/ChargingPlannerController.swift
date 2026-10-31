import Foundation
import OSLog

/// The notifier calls the planner makes. `Notifier` conforms in its own file; tests supply a fake.
@MainActor
protocol ChargingPlannerNotifying {
    func notifyCommandNotice(title: String, body: String, subtitle: String?)
}

/// The price series the planner reads. `ElectricityPriceService` is the app's source; tests
/// supply a fixed series so no evaluation touches the network or the wall clock.
protocol ChargingPlannerPriceSource: Sendable {
    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint]
    func fetchedAt(for zone: ElspotZone) async -> Date?
}

extension ElectricityPriceService: ChargingPlannerPriceSource {}

/// Background driver for the opt-in Smart Charging Planner. Runs a minute-cadence tick
/// that keeps the spot-price cache fresh (this is what performs the once-a-day fetch
/// after publication even when no panel is open), posts the window-start and
/// prices-published banners, starts charging inside the planned window when the user has
/// explicitly consented to auto-start, and backfills market-price costs onto completed
/// charging sessions.
///
/// All branching logic lives in the pure `ChargingPlannerSupport`/`ChargingPlannerDecisions`
/// enums; this class owns only scheduling, state lookups, and side effects. The command
/// dispatch is closure-injected so the automation path is visible in the composition root
/// (mirrors `CalendarPreconditioningController`).
@MainActor
final class ChargingPlannerController {
    private let preferences: PreferencesStore
    private let notifier: any ChargingPlannerNotifying
    private let priceSource: any ChargingPlannerPriceSource
    private let chargingLedger: ChargingSessionLedger
    private let latestState: () -> VehicleState?
    private let activeVINs: () -> [String]
    private let startCharging: (String) async -> RemoteCommandDispatchOutcome
    private let now: @Sendable () -> Date

    private let scheduler: AsyncTimerLoop
    private var evaluationInProgress = false
    private var generation = 0
    /// Auto-start fires at most once per planned window start, in memory. A relaunch
    /// mid-window may re-send one start command; the vehicle ignores a start while it is
    /// already charging, and the coordinator's single-flight guard covers bursts.
    private var autoStartedWindowStarts: [String: Date] = [:]

    /// How often the planner re-evaluates. Cheap: the common path is two guards and one
    /// actor hop onto a warm price cache.
    static let tickInterval: TimeInterval = 60

    /// `priceSource` overrides `priceService` when given; the composition root passes only
    /// `priceService`. `now` and `wait` default to the wall clock and `Task.sleep`.
    init(
        preferences: PreferencesStore,
        notifier: any ChargingPlannerNotifying,
        priceService: ElectricityPriceService = .shared,
        priceSource: (any ChargingPlannerPriceSource)? = nil,
        database: VehicleDatabase,
        latestState: @escaping () -> VehicleState?,
        activeVINs: @escaping () -> [String],
        startCharging: @escaping (String) async -> RemoteCommandDispatchOutcome,
        now: @escaping @Sendable () -> Date = { Date() },
        wait: @escaping AsyncTimerLoop.Wait = AsyncTimerLoop.realWait
    ) {
        self.preferences = preferences
        self.notifier = notifier
        self.priceSource = priceSource ?? priceService
        self.chargingLedger = database.charging
        self.latestState = latestState
        self.activeVINs = activeVINs
        self.startCharging = startCharging
        self.now = now
        self.scheduler = AsyncTimerLoop(wait: wait)
    }

    /// Whether the minute tick is armed. Read by tests checking start, stop and reload.
    var isArmed: Bool { scheduler.isArmed }

    func start() {
        guard !scheduler.isArmed else { return }
        scheduler.scheduleRepeating(after: Self.tickInterval) { [weak self] in
            await self?.evaluate()
        }
        Task { @MainActor in
            await self.evaluate()
        }
    }

    func stop() {
        generation &+= 1
        scheduler.cancel()
    }

    /// Re-evaluated whenever feature selection changes.
    func reload() {
        stop()
        if preferences.smartChargingPlannerAvailable {
            start()
        }
    }

    /// Fresh vehicle data arrived: re-run the plan ahead of the next tick.
    func vehicleStateDidUpdate(_ state: VehicleState) {
        guard preferences.smartChargingPlannerAvailable, scheduler.isArmed else { return }
        Task { @MainActor in
            await self.evaluate()
        }
    }

    // MARK: - Evaluation

    /// One planning pass. Internal rather than private so tests can drive a pass without
    /// waiting for the tick.
    func evaluate() async {
        guard !evaluationInProgress else { return }
        guard preferences.smartChargingPlannerAvailable else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let zone = preferences.electricityPriceZone
        let evaluationGeneration = generation
        let initialVIN = latestState()?.identity.vin
        // This call performs the once-a-day fetch when the cache is stale, and returns
        // from the persisted series otherwise.
        let prices = await priceSource.prices(for: zone)
        guard !prices.isEmpty, isCurrent(evaluationGeneration, zone: zone, vin: initialVIN) else { return }
        await notifyPricesPublishedIfDue(
            zone: zone,
            prices: prices,
            plannerPowerKw: preferences.electricityChargerPowerKw,
            generation: evaluationGeneration, vin: initialVIN
        )
        guard isCurrent(evaluationGeneration, zone: zone, vin: initialVIN) else { return }
        backfillSpotCosts(prices: prices)

        guard let state = latestState() else { return }
        let capacity = state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh
        let energyKwh = ChargingPlannerSupport.neededEnergyKwh(
            batteryPercentage: state.energy.batteryPercentage,
            targetPercentage: state.energy.targetPercentage,
            usableCapacityKwh: capacity
        )
        guard energyKwh > 0.5 else { return }
        let powerKw = ChargingPlannerSupport.powerKw(
            liveWatts: state.energy.powerWatts,
            isCharging: state.isCharging,
            configuredKw: preferences.electricityChargerPowerKw
        )
        guard let plan = ChargingPlanner.cheapestWindow(
            prices: prices, now: now(), energyKwh: energyKwh, chargerPowerKw: powerKw
        ) else { return }

        notifyWindowStartIfDue(plan: plan, state: state)
        autoStartIfDue(plan: plan, state: state, generation: evaluationGeneration, zone: zone)
    }

    // MARK: - Window-start banner

    private func notifyWindowStartIfDue(plan: ChargingPlan, state: VehicleState) {
        guard preferences.features.contains(.notifications),
              preferences.notifyPlannerWindowStart else { return }
        let vin = state.identity.vin
        guard ChargingPlannerDecisions.shouldNotifyWindowStart(
            plan: plan,
            now: now(),
            leadMinutes: preferences.plannerWindowLeadMinutes,
            announcedWindowEnd: preferences.plannerNotifiedWindowEnd(for: vin)
        ) else { return }
        preferences.setPlannerNotifiedWindowEnd(plan.end, for: vin)

        let window = "\(Format.shortTime(date: plan.start)) – \(Format.shortTime(date: plan.end))"
        let body: String
        switch (state.energy.connection, preferences.plannerAutoStartEnabled) {
        case (.connected, _):
            body = L10n.format("The cheap charging window runs %@.", window)
        case (_, true):
            body = L10n.format("Plug in the vehicle. The cheap charging window runs %@.", window)
        default:
            body = L10n.format("Cheap charging window: %@.", window)
        }
        notifier.notifyCommandNotice(
            title: L10n.text("Charging Planner"),
            body: body,
            subtitle: nil
        )
    }

    // MARK: - Prices-published banner

    private func notifyPricesPublishedIfDue(zone: ElspotZone, prices: [ElectricityPricePoint], plannerPowerKw: Double, generation: Int, vin: String?) async {
        guard preferences.features.contains(.notifications),
              preferences.notifyPlannerPricesPublished else { return }
        let currentDate = now()
        guard let horizon = ChargingPlanner.dataHorizonEnd(prices: prices),
              horizon >= ElectricityPriceService.requiredCoverageEnd(after: currentDate) else { return }
        // Only announce on the day the fetch actually brought tomorrow's file in; the
        // persisted day marker keeps it to one banner per zone per day across relaunches.
        let calendar = ElectricityPriceService.stockholmCalendar
        let today = calendar.startOfDay(for: currentDate)
        guard let fetchedAt = await priceSource.fetchedAt(for: zone),
              calendar.startOfDay(for: fetchedAt) == today,
              isCurrent(generation, zone: zone, vin: vin),
              preferences.features.contains(.notifications), preferences.notifyPlannerPricesPublished else { return }
        let day = Int(today.timeIntervalSince1970 / 86_400)
        guard preferences.plannerPricesNotifiedDay(for: zone) != day else { return }
        preferences.setPlannerPricesNotifiedDay(day, for: zone)

        let tomorrowStart = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let tomorrowPrices = prices.filter { $0.startDate >= tomorrowStart }
        // One charging-hour at the planner's power is the honest "cheapest hour" unit.
        let cheapestHour = ChargingPlanner.cheapestWindow(
            prices: tomorrowPrices,
            now: tomorrowStart,
            energyKwh: max(1, plannerPowerKw),
            chargerPowerKw: plannerPowerKw
        )
        let body: String
        if let cheapestHour {
            body = L10n.format(
                "Cheapest hour tomorrow: %@ – %@ at %@ /kWh.",
                Format.shortTime(date: cheapestHour.start),
                Format.shortTime(date: cheapestHour.end),
                Format.currency(cheapestHour.averagePrice, symbol: "kr")
            )
        } else {
            body = L10n.text("Tomorrow's spot prices have arrived.")
        }
        notifier.notifyCommandNotice(
            title: L10n.text("Tomorrow's electricity prices are in"),
            body: body,
            subtitle: nil
        )
    }

    // MARK: - Auto-start

    private func autoStartIfDue(plan: ChargingPlan, state: VehicleState, generation: Int, zone: ElspotZone) {
        guard preferences.plannerAutoStartEnabled,
              let battery = state.energy.batteryPercentage,
              let target = state.energy.targetPercentage,
              target > Int(battery) else { return }
        let vin = state.identity.vin
        guard ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: plan,
            now: now(),
            connection: state.energy.connection,
            chargingState: state.energy.chargingState
        ) else { return }
        guard autoStartedWindowStarts[vin] != plan.start else { return }
        // Held while the dispatch is in flight so an intervening tick cannot double-send;
        // released below when the outcome is retryable.
        autoStartedWindowStarts[vin] = plan.start
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation, zone: zone, vin: vin), self.preferences.plannerAutoStartEnabled else {
                self.autoStartedWindowStarts[vin] = nil
                return
            }
            let outcome = await self.startCharging(vin)
            AppLog.logger("elpriser").notice("Planner auto-start outcome: \(String(describing: outcome), privacy: .public)")
            // Mirror CalendarPreconditioningDispatchDecision.consumesOccurrence: only an
            // acknowledged send or a terminal refusal consumes the window. .deferred (command
            // pipeline busy, vehicle context changed mid-flight, shell still loading) must
            // stay retryable – the next 60 s tick re-evaluates while `now < plan.end` holds.
            if !CalendarPreconditioningDispatchDecision.consumesOccurrence(outcome) {
                self.autoStartedWindowStarts[vin] = nil
            }
        }
    }

    private func isCurrent(_ generation: Int, zone: ElspotZone, vin: String?) -> Bool {
        !Task.isCancelled && self.generation == generation && preferences.smartChargingPlannerAvailable
            && preferences.electricityPriceZone == zone && latestState()?.identity.vin == vin
    }

    // MARK: - Market-price backfill

    /// Prices freshly fetched sessions that predate the series' coverage back in time.
    /// Sessions outside coverage stay untouched so a later pass can price them.
    private func backfillSpotCosts(prices: [ElectricityPricePoint]) {
        let contract = preferences.electricityPriceContract
        for vin in activeVINs() where !vin.isEmpty {
            chargingLedger.backfillSpotEstimatedCosts(vin: vin, prices: contract.settle(prices))
        }
    }
}
