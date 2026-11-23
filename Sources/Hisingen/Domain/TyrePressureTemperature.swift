import Foundation

/// How much the outside temperature moves a tyre's pressure reading. The air in a tyre keeps its
/// volume, so absolute pressure follows absolute temperature (Gay-Lussac's law) and a gauge
/// reading, which sits above the atmosphere, moves by more than the same fraction of itself.
/// Cold air is the common case: a tyre filled indoors reads lower the morning it freezes, and
/// every tyre on the car moves together, which is what separates it from a leak.
enum TyrePressureTemperature {
    /// The temperature the note compares against.
    static let referenceCelsius = 20.0
    /// The note only appears when the air is at least this far from the reference. Closer than
    /// that the shift is a few kilopascals and not worth a line.
    static let noteThresholdCelsius = 10.0
    /// Standard atmosphere. TPMS values are gauge readings, so the atmosphere is added back
    /// before the temperature scaling and taken off again after.
    static let atmosphereKilopascals = 101.325

    /// What `gaugeKilopascals`, read with the air at `celsius`, would read at `referenceCelsius`.
    /// Nil for a non-positive gauge, a temperature at or below absolute zero, or a non-finite input.
    static func equivalentKilopascals(gaugeKilopascals: Double, atCelsius celsius: Double,
                                      referenceCelsius reference: Double = referenceCelsius) -> Double? {
        guard gaugeKilopascals.isFinite, gaugeKilopascals > 0, celsius.isFinite, reference.isFinite,
              celsius > -273.15, reference > -273.15 else { return nil }
        let absolute = gaugeKilopascals + atmosphereKilopascals
        let scaled = absolute * (reference + 273.15) / (celsius + 273.15)
        return scaled - atmosphereKilopascals
    }

    /// How far the reading sits from its equivalent at the reference, in kPa. Negative when the air
    /// is colder than the reference: the tyre then reads lower than it would at 20 °C.
    static func shift(gaugeKilopascals: Double, atCelsius celsius: Double) -> Double? {
        equivalentKilopascals(gaugeKilopascals: gaugeKilopascals, atCelsius: celsius)
            .map { gaugeKilopascals - $0 }
    }

    /// The mean shift across the tyres that report a pressure, when the air is far enough from the
    /// reference to be worth saying. Positive means the tyres read higher than at the reference.
    static func note(tyreKilopascals: [Double], ambientCelsius: Double?) -> Double? {
        guard let ambientCelsius, ambientCelsius.isFinite,
              abs(ambientCelsius - referenceCelsius) >= noteThresholdCelsius else { return nil }
        let shifts = tyreKilopascals.compactMap { shift(gaugeKilopascals: $0, atCelsius: ambientCelsius) }
        guard !shifts.isEmpty else { return nil }
        return shifts.reduce(0, +) / Double(shifts.count)
    }
}
