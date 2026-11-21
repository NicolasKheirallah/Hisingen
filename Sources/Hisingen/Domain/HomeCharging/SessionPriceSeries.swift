import Foundation

/// The price per kWh through one charging session, slot by slot, on the same basis the session's
/// cost was worked out on.
struct SessionPriceSeries: Equatable, Sendable {
    enum Basis: Equatable, Sendable {
        /// Tibber's all-in price (energy, taxes, Tibber's markup) plus the grid transfer fee.
        case tibberWithGridFee
        /// The market price with the markup, other charges and VAT from the Hisingen rate settings.
        case spotWithRates
        /// The bare market price, with no taxes or fees.
        case spot
    }

    /// Ordered by start; only slots that overlap the window.
    var slots: [HomePricePoint]
    var basis: Basis
    /// The stretch the slots were cut for: the time the cable was in.
    var window: ClosedRange<Date>? = nil

    /// Tibber's slots for `[start, end]`, each with the grid fee that applied during it. An hourly
    /// contract folds them into hour averages first, as the session cost does.
    static func tibber(_ points: [HomePricePoint], gridTariff: GridTariff, contract: ElectricityPriceContract = .quarterHour,
                       from start: Date, to end: Date) -> SessionPriceSeries? {
        let slots = clipped(contract.settle(points), from: start, to: end).map { slot in
            var priced = slot
            priced.pricePerKwh += gridTariff.averageFeePerKwh(from: slot.start, to: slot.end)
            return priced
        }
        return slots.isEmpty ? nil : SessionPriceSeries(slots: slots, basis: .tibberWithGridFee, window: start...max(start, end))
    }

    /// Market slots for `[start, end]`. An automatic rate policy turns each into the retail price
    /// the reader pays; a fixed one leaves the bare market price, which is labelled as such.
    static func spot(_ points: [ElectricityPricePoint], policy: ElectricityRatePolicy,
                     from start: Date, to end: Date) -> SessionPriceSeries? {
        let settled = policy.contract.settle(points).map { point in
            HomePricePoint(start: point.startDate, end: point.endDate,
                           pricePerKwh: policy.isAutomatic ? policy.retailPrice(spotSekPerKwh: point.sekPerKwh) : point.sekPerKwh)
        }
        let slots = clipped(settled, from: start, to: end)
        return slots.isEmpty ? nil : SessionPriceSeries(slots: slots, basis: policy.isAutomatic ? .spotWithRates : .spot,
                                                        window: start...max(start, end))
    }

    /// The price in force at `date`, or `nil` outside every slot.
    func price(at date: Date) -> Double? {
        slots.last { $0.start <= date && date < $0.end }?.pricePerKwh
    }

    /// Tibber's own rating of the slot at `date`, when the source gave one.
    func level(at date: Date) -> TibberPriceLevel? {
        slots.last { $0.start <= date && date < $0.end }?.level
    }

    /// One row per slot, for the session's price export.
    func csv(currency: String) -> String {
        let basisName: String
        switch basis {
        case .tibberWithGridFee: basisName = "tibber_with_grid_fee"
        case .spotWithRates: basisName = "spot_with_rates"
        case .spot: basisName = "spot"
        }
        let rows = slots.map { slot in
            [Format.iso8601.string(from: slot.start), Format.iso8601.string(from: slot.end),
             String(format: "%.4f", slot.pricePerKwh), CSV.field(currency), basisName,
             slot.level?.rawValue ?? ""].joined(separator: ",")
        }
        return (["Start,End,Price per kWh,Currency,Basis,Tibber Level"] + rows).joined(separator: "\n")
    }

    /// The average price weighted by the energy that flowed in each slot. Power is a stepped series
    /// (each reading holds until the next) of `(time, kW)`, so the result is what the energy cost,
    /// not the average of the clock. `nil` when no energy fell inside a priced slot.
    func energyWeightedAverage(power: [(Date, Double)], until end: Date) -> Double? {
        let readings = power.sorted { $0.0 < $1.0 }
        guard !readings.isEmpty else { return nil }
        var cost = 0.0
        var energy = 0.0
        for (index, reading) in readings.enumerated() {
            let stepEnd = index + 1 < readings.count ? readings[index + 1].0 : max(reading.0, end)
            guard reading.1 > 0, stepEnd > reading.0 else { continue }
            for slot in slots {
                let overlap = min(slot.end, stepEnd).timeIntervalSince(max(slot.start, reading.0))
                guard overlap > 0 else { continue }
                let kwh = reading.1 * overlap / 3_600
                cost += kwh * slot.pricePerKwh
                energy += kwh
            }
        }
        return energy > 0 ? cost / energy : nil
    }

    /// What `energyKwh` would have cost drawn in the cheapest slots of the window at up to `rateKw`:
    /// a floor, since it lets the charger pause and resume as often as the prices ask. `nil` when the
    /// window cannot hold that much energy at that rate.
    func cheapest(energyKwh: Double, rateKw: Double) -> (cost: Double, slots: [HomePricePoint])? {
        guard energyKwh > 0, rateKw > 0 else { return nil }
        var remaining = energyKwh
        var cost = 0.0
        var used: [HomePricePoint] = []
        for slot in slots.sorted(by: { $0.pricePerKwh < $1.pricePerKwh }) {
            let from = max(slot.start, window?.lowerBound ?? slot.start)
            let to = min(slot.end, window?.upperBound ?? slot.end)
            let hours = to.timeIntervalSince(from) / 3_600
            guard hours > 0 else { continue }
            let take = min(remaining, rateKw * hours)
            cost += take * slot.pricePerKwh
            remaining -= take
            var drawn = slot
            drawn.start = from
            drawn.end = to
            used.append(drawn)
            if remaining <= 1e-9 { break }
        }
        return remaining <= 0.01 ? (cost, used.sorted { $0.start < $1.start }) : nil
    }

    private static func clipped(_ points: [HomePricePoint], from start: Date, to end: Date) -> [HomePricePoint] {
        points.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
    }
}
