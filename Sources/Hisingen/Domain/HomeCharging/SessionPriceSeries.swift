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

    /// Ordered by start; only slots that overlap the session.
    var slots: [HomePricePoint]
    var basis: Basis

    /// Tibber's slots for `[start, end]`, each with the grid fee that applied during it.
    static func tibber(_ points: [HomePricePoint], gridTariff: GridTariff,
                       from start: Date, to end: Date) -> SessionPriceSeries? {
        let slots = clipped(points, from: start, to: end).map { slot in
            var priced = slot
            priced.pricePerKwh += gridTariff.averageFeePerKwh(from: slot.start, to: slot.end)
            return priced
        }
        return slots.isEmpty ? nil : SessionPriceSeries(slots: slots, basis: .tibberWithGridFee)
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
        return slots.isEmpty ? nil : SessionPriceSeries(slots: slots, basis: policy.isAutomatic ? .spotWithRates : .spot)
    }

    /// The price in force at `date`, or `nil` outside every slot.
    func price(at date: Date) -> Double? {
        slots.last { $0.start <= date && date < $0.end }?.pricePerKwh
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

    private static func clipped(_ points: [HomePricePoint], from start: Date, to end: Date) -> [HomePricePoint] {
        points.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
    }
}
