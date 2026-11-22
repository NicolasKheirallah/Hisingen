import Foundation

/// The Electricity Supplier card's house-energy readout: the last 30 days of whole-home
/// consumption and production by day, the twelve months before that, and how the prices published
/// for today and tomorrow spread over Tibber's five price levels. It reads with the same saved
/// token the live stream uses, once per card appearance, and keeps its last good answer when a
/// later read fails.
@MainActor
final class TibberEnergyModel: ObservableObject {
    struct Content: Equatable {
        /// What Tibber billed for the days, once every day carries one cost in one currency.
        struct CostTotal: Equatable {
            var amount: Double
            var currency: String
        }

        var days: [TibberClient.TibberConsumptionPeriod]
        var productionDays: [TibberClient.TibberProductionPeriod]
        var months: [TibberClient.TibberConsumptionPeriod]
        var productionMonths: [TibberClient.TibberProductionPeriod]
        /// Hours at each price level across the prices published for today and tomorrow.
        var levelHours: [TibberPriceLevel: Double]

        /// The rows a chart of `unit` draws.
        func rows(for unit: Calendar.Component) -> [TibberClient.TibberConsumptionPeriod] {
            unit == .month ? months : days
        }

        func productionRows(for unit: Calendar.Component) -> [TibberClient.TibberProductionPeriod] {
            unit == .month ? productionMonths : productionDays
        }

        /// `nil` unless every day carries a cost and they share one currency.
        var cost: CostTotal? {
            let currencies = Set(days.compactMap(\.currency))
            guard !days.isEmpty, currencies.count == 1, days.allSatisfy({ $0.cost != nil }) else { return nil }
            return CostTotal(amount: days.reduce(0) { $0 + ($1.cost ?? 0) }, currency: currencies.first ?? "")
        }
    }

    @Published private(set) var content: Content?
    /// Why the last read failed, or `nil`. It sits beside the last good content rather than
    /// replacing it, the way the Prices row reports a failure.
    @Published private(set) var problem: String?

    private let store: HomeChargingStore
    private let transport: any HomeAssistantTransport
    private let now: @Sendable () -> Date

    init(preferences: PreferencesStore, transport: any HomeAssistantTransport = URLSessionHomeAssistantTransport(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = HomeChargingStore(defaults: preferences.d, keychain: preferences.keychain)
        self.transport = transport
        self.now = now
    }

    /// Reads the whole readout in one pass. A read that fails keeps the previous content and names
    /// the reason; a cancellation leaves everything as it was.
    func reload() async {
        guard let home = store.tibberHome, let token = (try? store.tibberToken()) ?? nil, !token.isEmpty else {
            content = nil
            problem = nil
            return
        }
        let current = now()
        let to = current.addingTimeInterval(3_600)
        let daysFrom = current.addingTimeInterval(-30 * 86_400)
        let monthsFrom = current.addingTimeInterval(-365 * 86_400)
        let client = TibberClient(token: token, transport: transport, now: now)
        do {
            async let days = client.consumption(homeID: home.id, resolution: .daily, from: daysFrom, to: to)
            async let productionDays = client.production(homeID: home.id, resolution: .daily, from: daysFrom, to: to)
            async let months = client.consumption(homeID: home.id, resolution: .monthly, from: monthsFrom, to: to)
            async let productionMonths = client.production(homeID: home.id, resolution: .monthly, from: monthsFrom, to: to)
            async let prices = client.currentPrices(homeID: home.id)
            let (dayRows, productionDayRows, monthRows, productionMonthRows, pricePoints) =
                try await (days, productionDays, months, productionMonths, prices)
            guard !Task.isCancelled else { return }
            content = Content(days: dayRows, productionDays: productionDayRows, months: monthRows,
                              productionMonths: productionMonthRows, levelHours: TibberPriceLevelTally.hours(pricePoints))
            problem = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            problem = (error as? DirectChargerError)?.errorDescription ?? error.localizedDescription
        }
    }
}
