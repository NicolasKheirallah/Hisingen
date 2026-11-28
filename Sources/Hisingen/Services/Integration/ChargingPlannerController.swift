import Foundation
import OSLog

/// The notifier calls the planner makes. `Notifier` conforms in its own file; tests supply a fake.
@MainActor
protocol ChargingPlannerNotifying {
    func notifyCommandNotice(title: String, body: String, subtitle: String?)
}

/// The price series the planner reads. `PlannerPriceProvider` is the app's source (the connected
/// provider, Elpriser behind it); tests supply a fixed series so no evaluation touches the
/// network or the wall clock.
protocol ChargingPlannerPriceSource: Sendable {
    func prices(for zone: ElspotZone) async -> [ElectricityPricePoint]
    func fetchedAt(for zone: ElspotZone) async -> Date?
    /// The bare market series, for pricing past sessions. `prices(for:)` may be a provider's
    /// all-in series, which must not be stored as a spot cost.
    func marketPrices(for zone: ElspotZone) async -> [ElectricityPricePoint]
}

extension ChargingPlannerPriceSource {
    func marketPrices(for zone: ElspotZone) async -> [ElectricityPricePoint] {
        await prices(for: zone)
    }
}

extension ElectricityPriceService: ChargingPlannerPriceSource {}

/// Background driver for the opt-in Smart Charging Planner. Runs a minute-cadence tick
/// that keeps the spot-price cache fresh (this is what performs the once-a-day fetch
/// after publication even when no panel is open), posts the window-start and
/// prices-published banners, starts charging inside the planned window when the user has
/// explicitly consented to auto-start, ends that override at the window's end so the car
/// does not keep charging into the next, more expensive hours, holds a sleep assertion
/// while a window waits or runs when the reader asked for it, and backfills market-price
/// costs onto completed charging sessions.
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
    private let stateForVIN: (String) -> VehicleState?
    private let activeVINs: () -> [String]
    private let startCharging: (String) async -> RemoteCommandDispatchOutcome
    private let stopCharging: (String) async -> RemoteCommandDispatchOutcome
    private let sleepPrevention: any SleepPreventing
    /// True while Home Assistant runs a charging plan for the vehicle. The two planners must never
    /// drive the same car, so everything that would notify or send a command waits for this to clear.
    private let plannerOwnedByHomeAssistant: (String) -> Bool
    private let now: @Sendable () -> Date

    private let scheduler: AsyncTimerLoop
    private var evaluationInProgress = false
    private var generation = 0
    /// Auto-start fires at most once per planned window start, in memory. The persisted
    /// committed window carries the same fact across a relaunch; this map is what a terminal
    /// refusal leaves behind so a window that will not start is not retried every minute.
    private var autoStartedWindowStarts: [String: Date] = [:]
    /// VIN → the window end whose stop command is in flight, so a minute tick cannot send it twice.
    private var stopInFlight: [String: Date] = [:]
    /// Refused sends of the start and of the stop, per VIN. `.refused` also covers a provider
    /// request that failed on the network, and both commands are safe to repeat, so one
    /// refusal does not end the window.
    private(set) var refusedStarts: [String: Int] = [:]
    private(set) var refusedStops: [String: Int] = [:]
    /// VIN → when a start that was refused `maxRefusedSends` times may be tried again. The plan
    /// is recomputed every tick, so the guard on the window start alone would not hold it back.
    private var gaveUpStartsUntil: [String: Date] = [:]

    /// How many refused sends of one planner command end the attempt. At the minute tick this is
    /// about five minutes of trying, then the window is given up and the failure banner stands.
    static let maxRefusedSends = 5

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
        stateForVIN: @escaping (String) -> VehicleState? = { _ in nil },
        plannerOwnedByHomeAssistant: @escaping (String) -> Bool = { _ in false },
        activeVINs: @escaping () -> [String],
        startCharging: @escaping (String) async -> RemoteCommandDispatchOutcome,
        stopCharging: @escaping (String) async -> RemoteCommandDispatchOutcome,
        sleepPrevention: any SleepPreventing = SleepPrevention(),
        now: @escaping @Sendable () -> Date = { Date() },
        wait: @escaping AsyncTimerLoop.Wait = AsyncTimerLoop.realWait
    ) {
        self.preferences = preferences
        self.notifier = notifier
        self.priceSource = priceSource ?? priceService
        self.chargingLedger = database.charging
        self.latestState = latestState
        self.stateForVIN = stateForVIN
        self.activeVINs = activeVINs
        self.startCharging = startCharging
        self.stopCharging = stopCharging
        self.sleepPrevention = sleepPrevention
        self.plannerOwnedByHomeAssistant = plannerOwnedByHomeAssistant
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
        // A disarmed planner does not need the Mac awake for a window it cannot act on.
        sleepPrevention.release()
    }

    /// Re-evaluated whenever feature selection changes.
    func reload() {
        stop()
        if preferences.smartChargingPlannerAvailable {
            start()
        }
    }

    /// Fresh vehicle data arrived: re-run the plan ahead of the next tick.
    func vehicleStateDidUpdate() {
        guard preferences.smartChargingPlannerAvailable, scheduler.isArmed else { return }
        Task { @MainActor in
            await self.evaluate()
        }
    }

    // MARK: - Evaluation

    /// One planning pass. Internal rather than private so tests can drive a pass without
    /// waiting for the tick.
    func evaluate() async {
        guard preferences.smartChargingPlannerAvailable else {
            sleepPrevention.release()
            return
        }

        let evaluationGeneration = generation
        let initialVIN = targetVehicleState()?.identity.vin ?? preferences.plannerTargetVIN
        reconcileCommittedWindows(now: now(), generation: evaluationGeneration, extraVIN: initialVIN)
        let selectedHasCommittedWindow = initialVIN.flatMap { preferences.plannerWindow(for: $0) } != nil
        let activeWindow = firstActiveCommittedWindow(now: now(), extraVIN: initialVIN)
        if let activeWindow { updateSleepPrevention(window: activeWindow) }

        guard !evaluationInProgress else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let zone = preferences.electricityPriceZone
        let prices = await priceSource.prices(for: zone)
        guard isCurrentForWindowEnd(evaluationGeneration) else { return }
        guard !prices.isEmpty, isCurrent(evaluationGeneration, zone: zone, vin: initialVIN) else {
            updateSleepPrevention(window: firstActiveCommittedWindow(now: now(), extraVIN: initialVIN))
            return
        }
        await notifyPricesPublishedIfDue(
            zone: zone,
            prices: prices,
            plannerPowerKw: preferences.electricityChargerPowerKw,
            generation: evaluationGeneration, vin: initialVIN
        )
        guard isCurrent(evaluationGeneration, zone: zone, vin: initialVIN) else { return }
        await backfillSpotCosts(zone: zone)
        guard isCurrent(evaluationGeneration, zone: zone, vin: initialVIN) else { return }

        let currentDate = now()
        let committed = firstActiveCommittedWindow(now: currentDate, extraVIN: initialVIN)
        guard let state = targetVehicleState(),
              !plannerOwnedByHomeAssistant(state.identity.vin) else {
            updateSleepPrevention(window: committed)
            return
        }
        let vin = state.identity.vin
        if selectedHasCommittedWindow || preferences.plannerWindow(for: vin) != nil {
            updateSleepPrevention(window: committed)
            return
        }

        let capacity = state.configuredCapacityReference(
            specification: preferences.vehicleSpecificationOverride(for: state.identity.vin)).kwh
        let energyKwh = ChargingPlannerSupport.neededEnergyKwh(
            batteryPercentage: state.energy.batteryPercentage,
            targetPercentage: state.energy.targetPercentage,
            usableCapacityKwh: capacity
        )
        guard energyKwh > 0.5 else {
            autoStartedWindowStarts[vin] = nil
            refusedStarts[vin] = nil
            refusedStops[vin] = nil
            gaveUpStartsUntil[vin] = nil
            updateSleepPrevention(window: committed)
            return
        }

        let powerKw = ChargingPlannerSupport.powerKw(
            liveWatts: state.energy.powerWatts,
            isCharging: state.isCharging,
            configuredKw: preferences.electricityChargerPowerKw
        )
        guard let plan = ChargingPlanner.cheapestWindow(
            prices: prices, now: currentDate, energyKwh: energyKwh, chargerPowerKw: powerKw
        ) else {
            updateSleepPrevention(window: committed)
            return
        }

        notifyWindowStartIfDue(plan: plan, state: state)
        autoStartIfDue(plan: plan, state: state, generation: evaluationGeneration, zone: zone)
        updateSleepPrevention(window: committed ?? DateInterval(start: plan.start, end: plan.end))
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
                Format.currency(cheapestHour.averagePrice, symbol: preferences.currencySymbol)
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
        if let until = gaveUpStartsUntil[vin], now() < until { return }
        // Held while the dispatch is in flight so an intervening tick cannot double-send;
        // released below when the outcome is retryable.
        autoStartedWindowStarts[vin] = plan.start
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.isCurrent(generation, zone: zone, vin: vin), self.preferences.plannerAutoStartEnabled,
                  !self.plannerOwnedByHomeAssistant(vin) else {
                self.autoStartedWindowStarts[vin] = nil
                return
            }
            let outcome = await self.startCharging(vin)
            AppLog.logger("elpriser").notice("Planner auto-start outcome: \(String(describing: outcome), privacy: .public)")
            // .deferred (command pipeline busy, vehicle context changed mid-flight, shell still
            // loading) stays retryable: the next 60 s tick re-evaluates while `now < plan.end`
            // holds. .refused is retried too, up to `maxRefusedSends`, because a network failure
            // arrives as a refusal.
            switch outcome {
            case .sent:
                self.refusedStarts[vin] = nil
                self.gaveUpStartsUntil[vin] = nil
                // The window's end is now fixed: the stop command is due there even if the
                // remaining energy pushes the recomputed plan past it.
                self.preferences.setPlannerWindow(
                    DateInterval(start: plan.start, end: plan.end), for: vin
                )
            case .refused:
                let refused = (self.refusedStarts[vin] ?? 0) + 1
                if refused < Self.maxRefusedSends {
                    self.refusedStarts[vin] = refused
                    self.autoStartedWindowStarts[vin] = nil
                } else {
                    self.refusedStarts[vin] = nil
                    self.gaveUpStartsUntil[vin] = plan.end
                    self.preferences.setPlannerWindow(nil, for: vin)
                }
            case .deferred:
                self.autoStartedWindowStarts[vin] = nil
            }
        }
    }

    // MARK: - Window-end stop

    private func stopChargingAtWindowEnd(vin: String, generation: Int) {
        guard stopInFlight[vin] == nil else { return }
        guard let window = preferences.plannerWindow(for: vin) else { return }
        stopInFlight[vin] = window.end
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.stopInFlight[vin] = nil }
            guard self.isCurrentForWindowEnd(generation),
                  !self.plannerOwnedByHomeAssistant(vin) else { return }
            let outcome = await self.stopCharging(vin)
            AppLog.logger("elpriser").notice("Planner window-end stop outcome: \(String(describing: outcome), privacy: .public)")
            // A stop that never lands leaves the car charging into the dearer hours, so a refusal
            // is retried on the next ticks before the window is given up. A deferred send is
            // retried without a limit while the window is still fresh.
            if case .refused = outcome {
                let refused = (self.refusedStops[vin] ?? 0) + 1
                if refused < Self.maxRefusedSends {
                    self.refusedStops[vin] = refused
                    return
                }
            }
            if CalendarPreconditioningDispatchDecision.consumesOccurrence(outcome) {
                self.refusedStops[vin] = nil
                self.preferences.setPlannerWindow(nil, for: vin)
                self.autoStartedWindowStarts[vin] = nil
            }
        }
    }

    // MARK: - Sleep prevention

    /// Hold one assertion while a window is ahead or running, and drop it as soon as there is
    /// nothing left to act on. The system cannot be asked to wake a sleeping Mac, so the
    /// assertion only covers the case where this Mac is still awake when the window is planned.
    private func updateSleepPrevention(window: DateInterval?) {
        guard ChargingPlannerDecisions.shouldPreventSleep(
            window: window,
            now: now(),
            autoStartEnabled: preferences.plannerAutoStartEnabled,
            keepAwakeEnabled: preferences.plannerKeepAwakeEnabled
        ) else {
            sleepPrevention.release()
            return
        }
        sleepPrevention.hold(reason: SleepPrevention.assertionReason)
    }

    private func targetVehicleState() -> VehicleState? {
        if let target = preferences.plannerTargetVIN, !target.isEmpty {
            if let direct = stateForVIN(target) { return direct }
            if let latest = latestState(), latest.identity.vin.normalizedVIN == target {
                return latest
            }
            return nil
        }
        return latestState()
    }

    private func windowState(for vin: String) -> VehicleState? {
        let normalized = vin.normalizedVIN
        if let latest = latestState(), latest.identity.vin.normalizedVIN == normalized {
            return latest
        }
        return stateForVIN(normalized)
    }

    private func committedWindows(extraVIN: String?) -> [(vin: String, window: DateInterval)] {
        let candidates = Set(activeVINs().map(\.normalizedVIN) + [extraVIN?.normalizedVIN].compactMap { $0 })
        return candidates.compactMap { vin in
            guard !vin.isEmpty, !plannerOwnedByHomeAssistant(vin),
                  let window = preferences.plannerWindow(for: vin) else { return nil }
            return (vin, window)
        }
    }

    private func reconcileCommittedWindows(now currentDate: Date, generation: Int, extraVIN: String?) {
        for (vin, window) in committedWindows(extraVIN: extraVIN) where currentDate >= window.end {
            let expired = currentDate >= window.end.addingTimeInterval(ChargingPlannerDecisions.stopWindowGrace)
            let state = windowState(for: vin)
            if let state, ChargingPlannerDecisions.shouldStopChargingAtWindowEnd(
                window: window,
                now: currentDate,
                connection: state.energy.connection,
                chargingState: state.energy.chargingState
            ) {
                stopChargingAtWindowEnd(vin: vin, generation: generation)
            } else if expired || state?.energy.connection == .disconnected
                        || (state?.energy.chargingState.isRecognised == true && state?.isCharging == false) {
                preferences.setPlannerWindow(nil, for: vin)
                autoStartedWindowStarts[vin] = nil
                refusedStops[vin] = nil
            }
        }
    }

    private func firstActiveCommittedWindow(now currentDate: Date, extraVIN: String?) -> DateInterval? {
        committedWindows(extraVIN: extraVIN).first { $0.window.end > currentDate }?.window
    }

    private func isCurrentForWindowEnd(_ generation: Int) -> Bool {
        !Task.isCancelled && self.generation == generation && preferences.smartChargingPlannerAvailable
    }

    private func isCurrent(_ generation: Int, zone: ElspotZone, vin: String?) -> Bool {
        guard !Task.isCancelled && self.generation == generation && preferences.smartChargingPlannerAvailable
            && preferences.electricityPriceZone == zone else {
            return false
        }
        if let configured = preferences.plannerTargetVIN, !configured.isEmpty {
            return configured == vin?.normalizedVIN
        }
        return latestState()?.identity.vin == vin
    }

    // MARK: - Market-price backfill

    /// Prices freshly fetched sessions that predate the series' coverage back in time.
    /// Sessions outside coverage stay untouched so a later pass can price them.
    private func backfillSpotCosts(zone: ElspotZone) async {
        let vins = activeVINs().filter { !$0.isEmpty }
        guard !vins.isEmpty else { return }
        // Always the market series: the stored spot cost is raw, and the rate policy adds the
        // user's markup and VAT on display. A provider's all-in price would count them twice.
        let prices = await priceSource.marketPrices(for: zone)
        let contract = preferences.electricityPriceContract
        for vin in vins {
            chargingLedger.backfillSpotEstimatedCosts(vin: vin, prices: contract.settle(prices))
        }
    }
}
