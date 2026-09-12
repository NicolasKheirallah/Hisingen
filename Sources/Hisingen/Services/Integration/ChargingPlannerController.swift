import Foundation
import OSLog

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
    private let notifier: Notifier
    private let priceService: ElectricityPriceService
    private let chargingLedger: ChargingSessionLedger
    private let latestState: () -> VehicleState?
    private let activeVINs: () -> [String]
    private let startCharging: () async -> RemoteCommandDispatchOutcome

    private var timer: Timer?
    private var evaluationInProgress = false
    /// Auto-start fires at most once per planned window start, in memory. A relaunch
    /// mid-window may re-send one start command; the vehicle ignores a start while it is
    /// already charging, and the coordinator's single-flight guard covers bursts.
    private var autoStartedWindowStarts: [String: Date] = [:]

    /// How often the planner re-evaluates. Cheap: the common path is two guards and one
    /// actor hop onto a warm price cache.
    static let tickInterval: TimeInterval = 60

    init(
        preferences: PreferencesStore,
        notifier: Notifier,
        priceService: ElectricityPriceService,
        database: VehicleDatabase,
        latestState: @escaping () -> VehicleState?,
        activeVINs: @escaping () -> [String],
        startCharging: @escaping () async -> RemoteCommandDispatchOutcome
    ) {
        self.preferences = preferences
        self.notifier = notifier
        self.priceService = priceService
        self.chargingLedger = database.charging
        self.latestState = latestState
        self.activeVINs = activeVINs
        self.startCharging = startCharging
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.evaluate()
            }
        }
        self.timer = timer
        Task { @MainActor in
            await self.evaluate()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-evaluated whenever feature selection changes.
    func reload() {
        stop()
        if preferences.features.contains(.smartChargingPlanner) {
            start()
        }
    }

    /// Fresh vehicle data arrived: re-run the plan ahead of the next tick.
    func vehicleStateDidUpdate(_ state: VehicleState) {
        guard preferences.features.contains(.smartChargingPlanner), timer != nil else { return }
        Task { @MainActor in
            await self.evaluate()
        }
    }

    // MARK: - Evaluation

    private func evaluate() async {
        guard !evaluationInProgress else { return }
        guard preferences.features.contains(.smartChargingPlanner) else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let zone = preferences.electricityPriceZone
        // This call performs the once-a-day fetch when the cache is stale, and returns
        // from the persisted series otherwise.
        let prices = await priceService.prices(for: zone)
        guard !prices.isEmpty else { return }
        await notifyPricesPublishedIfDue(
            zone: zone,
            prices: prices,
            plannerPowerKw: preferences.electricityChargerPowerKw
        )
        backfillSpotCosts(prices: prices)

        guard let state = latestState() else { return }
        let capacity = preferences.vehicleSpecificationOverride(for: state.identity.vin)?.usableBatteryCapacityKwh
            ?? state.configuredUsableBatteryCapacityKwh
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
            prices: prices, now: Date(), energyKwh: energyKwh, chargerPowerKw: powerKw
        ) else { return }

        notifyWindowStartIfDue(plan: plan, state: state)
        autoStartIfDue(plan: plan, state: state)
    }

    // MARK: - Window-start banner

    private func notifyWindowStartIfDue(plan: ChargingPlan, state: VehicleState) {
        guard preferences.features.contains(.notifications),
              preferences.notifyPlannerWindowStart else { return }
        let vin = state.identity.vin
        guard ChargingPlannerDecisions.shouldNotifyWindowStart(
            plan: plan,
            now: Date(),
            lastNotifiedStart: preferences.plannerNotifiedWindowStart(for: vin)
        ) else { return }
        preferences.setPlannerNotifiedWindowStart(plan.start, for: vin)

        let window = "\(Format.shortTime(date: plan.start)) – \(Format.shortTime(date: plan.end))"
        let body: String
        switch (state.energy.connection, preferences.plannerAutoStartEnabled) {
        case (.connected, _):
            body = L10n.format("The cheap charging window runs %@.", window)
        case (_, true):
            body = L10n.format("Plug in the vehicle — the cheap charging window runs %@.", window)
        default:
            body = L10n.format("Cheap charging window: %@.", window)
        }
        notifier.notifyCommandNotice(
            title: L10n.text("Charging Planner"),
            body: body
        )
    }

    // MARK: - Prices-published banner

    private func notifyPricesPublishedIfDue(zone: ElspotZone, prices: [ElectricityPricePoint], plannerPowerKw: Double) async {
        guard preferences.features.contains(.notifications),
              preferences.notifyPlannerPricesPublished else { return }
        guard let horizon = ChargingPlanner.dataHorizonEnd(prices: prices),
              horizon >= ElectricityPriceService.requiredCoverageEnd(after: Date()) else { return }
        // Only announce on the day the fetch actually brought tomorrow's file in; the
        // persisted day marker keeps it to one banner per zone per day across relaunches.
        let calendar = ElectricityPriceService.stockholmCalendar
        let today = calendar.startOfDay(for: Date())
        guard let fetchedAt = await priceService.fetchedAt(for: zone),
              calendar.startOfDay(for: fetchedAt) == today else { return }
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
            body: body
        )
    }

    // MARK: - Auto-start

    private func autoStartIfDue(plan: ChargingPlan, state: VehicleState) {
        guard preferences.plannerAutoStartEnabled,
              let battery = state.energy.batteryPercentage,
              let target = state.energy.targetPercentage,
              target > Int(battery) else { return }
        let vin = state.identity.vin
        guard ChargingPlannerDecisions.shouldAutoStartCharging(
            plan: plan,
            now: Date(),
            connection: state.energy.connection,
            chargingState: state.energy.chargingState
        ) else { return }
        guard autoStartedWindowStarts[vin] != plan.start else { return }
        autoStartedWindowStarts[vin] = plan.start
        Task { @MainActor [weak self] in
            guard let outcome = await self?.dispatchStartCharging() else { return }
            AppLog.logger("elpriser").notice("Planner auto-start outcome: \(String(describing: outcome), privacy: .public)")
        }
    }

    private func dispatchStartCharging() async -> RemoteCommandDispatchOutcome {
        await startCharging()
    }

    // MARK: - Market-price backfill

    /// Prices freshly fetched sessions that predate the series' coverage back in time.
    /// Sessions outside coverage stay untouched so a later pass can price them.
    private func backfillSpotCosts(prices: [ElectricityPricePoint]) {
        for vin in activeVINs() where !vin.isEmpty {
            chargingLedger.backfillSpotEstimatedCosts(vin: vin, prices: prices)
        }
    }
}
