import Foundation
import OSLog

/// The price series the threshold alert reads. `PlannerPriceProvider` is the app's source; tests
/// supply a fixed series so no evaluation touches the network.
protocol PriceAlertPriceProviding: Sendable {
    func resolve(zone: ElspotZone) async -> PlannerPrices
}

extension PlannerPriceProvider: PriceAlertPriceProviding {}

/// Posts the threshold alert. `Notifier` conforms in `Notifier+PriceAlert.swift`; tests supply a
/// recorder.
@MainActor
protocol PriceAlertNotifying: AnyObject {
    func notifyPriceAlert(title: String, body: String, zone: ElspotZone, slotStart: Date)
}

/// Watches the reader's market price against the level they set. It runs on its own minute tick
/// rather than inside the charging planner, so a reader who only wants the price alert does not
/// have to switch the planner on. It needs the same two things the alert itself needs: a price
/// series and automatic market pricing.
@MainActor
final class PriceAlertController {
    static let tickInterval: TimeInterval = 60

    private let preferences: PreferencesStore
    private let notifier: any PriceAlertNotifying
    private let priceSource: any PriceAlertPriceProviding
    private let now: @Sendable () -> Date
    private let scheduler: AsyncTimerLoop
    private let logger = AppLog.logger("elpriser")

    private var evaluationInProgress = false
    private var generation = 0

    init(preferences: PreferencesStore,
         notifier: any PriceAlertNotifying,
         priceSource: any PriceAlertPriceProviding,
         now: @escaping @Sendable () -> Date = { Date() },
         wait: @escaping AsyncTimerLoop.Wait = AsyncTimerLoop.realWait) {
        self.preferences = preferences
        self.notifier = notifier
        self.priceSource = priceSource
        self.now = now
        self.scheduler = AsyncTimerLoop(wait: wait)
    }

    /// Whether the minute tick is armed. Read by tests checking start and reload.
    var isArmed: Bool { scheduler.isArmed }

    /// A threshold alert only means something against a price that moves. In fixed-rate mode the
    /// reader pays the same figure all day, so the alert stays off instead of reading market
    /// prices that are not their bill.
    var isAvailable: Bool {
        preferences.features.contains(.notifications)
            && preferences.notifyPriceThreshold
            && preferences.hasPriceSource
            && preferences.electricityRateMode == .automatic
    }

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

    /// Re-evaluated when a settings surface changes the alert switch, the rate mode or the zone.
    func reload() {
        stop()
        if isAvailable {
            start()
        }
    }

    /// One evaluation pass. Internal rather than private so tests can drive it without a tick.
    func evaluate() async {
        guard !evaluationInProgress, isAvailable else { return }
        evaluationInProgress = true
        defer { evaluationInProgress = false }

        let zone = preferences.electricityPriceZone
        let evaluationGeneration = generation
        let resolved = await priceSource.resolve(zone: zone)
        guard evaluationGeneration == generation, isAvailable,
              preferences.electricityPriceZone == zone else { return }

        let currentDate = now()
        let threshold = preferences.priceAlertThresholdSekPerKwh
        let decision = PriceThresholdAlert.evaluate(
            prices: resolved.points,
            policy: preferences.electricityRatePolicy,
            allIn: resolved.isAllIn,
            now: currentDate,
            threshold: threshold,
            quietPeriod: TimeInterval(preferences.priceAlertQuietMinutes * 60),
            lastAlertAt: preferences.priceAlertLastAlertedAt(for: zone),
            lastAlertedSlotStart: preferences.priceAlertLastSlotStart(for: zone),
            calendar: ElectricityPriceService.stockholmCalendar
        )
        guard case .alert(let crossing) = decision else {
            logger.debug("Price threshold: \(String(describing: decision), privacy: .public)")
            return
        }

        let symbol = preferences.currencySymbol
        let level = Format.currency(threshold, symbol: symbol)
        let price = Format.currency(crossing.price, symbol: symbol)
        let body: String
        switch crossing.window {
        case .current:
            body = L10n.format("The price is now %@/kWh, above your %@/kWh level.", price, level)
        case .nextHour:
            body = L10n.format("The next hour costs %@/kWh from %@, above your %@/kWh level.",
                               price,
                               Format.shortTime(date: crossing.slotStart,
                                                timeZone: ElectricityPriceService.stockholmCalendar.timeZone),
                               level)
        }

        // Recorded before posting so a rejected banner is not re-attempted every minute; the
        // slot stamp also keeps a relaunch inside the same crossing quiet.
        preferences.setPriceAlertLastAlertedAt(currentDate, for: zone)
        preferences.setPriceAlertLastSlotStart(crossing.slotStart, for: zone)
        notifier.notifyPriceAlert(
            title: L10n.text("Electricity price alert"), body: body,
            zone: zone, slotStart: crossing.slotStart
        )
        logger.notice("Price threshold alert for \(zone.rawValue, privacy: .public) at \(price, privacy: .public)")
    }
}
