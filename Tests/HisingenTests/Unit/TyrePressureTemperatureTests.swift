import Foundation
import Testing
@testable import Hisingen

struct TyrePressureTemperatureTests {
    @Test("The reference temperature leaves a reading where it is")
    func noShiftAtTheReference() throws {
        let equivalent = try #require(TyrePressureTemperature.equivalentKilopascals(
            gaugeKilopascals: 250, atCelsius: 20))
        #expect(abs(equivalent - 250) < 1e-9)
        let shift = try #require(TyrePressureTemperature.shift(gaugeKilopascals: 250, atCelsius: 20))
        #expect(abs(shift) < 1e-9)
    }

    @Test("A gauge reading of 250 kPa at -10 °C is about 290 kPa at 20 °C")
    func coldReadingIsLowerThanItWouldBeAtTwenty() throws {
        // (250 + 101.325) * 293.15 / 263.15 - 101.325 = 290.1 kPa.
        let equivalent = try #require(TyrePressureTemperature.equivalentKilopascals(
            gaugeKilopascals: 250, atCelsius: -10))
        #expect(abs(equivalent - 290.1) < 0.1)
        let shift = try #require(TyrePressureTemperature.shift(gaugeKilopascals: 250, atCelsius: -10))
        #expect(abs(shift - (-40.1)) < 0.1)
    }

    @Test("Heat raises the reading above its value at 20 °C")
    func hotReadingIsHigher() throws {
        let shift = try #require(TyrePressureTemperature.shift(gaugeKilopascals: 250, atCelsius: 35))
        #expect(shift > 0)
    }

    @Test("Absolute pressure follows absolute temperature, so the effect is the same fraction of it")
    func scalesWithAbsolutePressure() throws {
        // Hold the absolute pressure ratio: 20 °C is 293.15 K, 0 °C is 273.15 K.
        let equivalent = try #require(TyrePressureTemperature.equivalentKilopascals(
            gaugeKilopascals: 200, atCelsius: 0))
        let ratio = (equivalent + TyrePressureTemperature.atmosphereKilopascals)
            / (200 + TyrePressureTemperature.atmosphereKilopascals)
        #expect(abs(ratio - 293.15 / 273.15) < 1e-9)
    }

    @Test("Bad inputs give nothing")
    func rejectsBadInputs() {
        #expect(TyrePressureTemperature.equivalentKilopascals(gaugeKilopascals: 0, atCelsius: 5) == nil)
        #expect(TyrePressureTemperature.equivalentKilopascals(gaugeKilopascals: -5, atCelsius: 5) == nil)
        #expect(TyrePressureTemperature.equivalentKilopascals(gaugeKilopascals: .nan, atCelsius: 5) == nil)
        #expect(TyrePressureTemperature.equivalentKilopascals(gaugeKilopascals: 250, atCelsius: -273.15) == nil)
        #expect(TyrePressureTemperature.equivalentKilopascals(gaugeKilopascals: 250, atCelsius: .infinity) == nil)
    }

    @Test("The note appears at 10 °C from the reference and not nearer")
    func noteThresholdEdges() {
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: 10) != nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: 30) != nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: 10.1) == nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: 29.9) == nil)
    }

    @Test("The note is the mean shift across the tyres that report a pressure")
    func noteAveragesTheReportedTyres() throws {
        let note = try #require(TyrePressureTemperature.note(
            tyreKilopascals: [240, 260], ambientCelsius: -10))
        let low = try #require(TyrePressureTemperature.shift(gaugeKilopascals: 240, atCelsius: -10))
        let high = try #require(TyrePressureTemperature.shift(gaugeKilopascals: 260, atCelsius: -10))
        #expect(abs(note - (low + high) / 2) < 1e-9)
        #expect(note < 0)
    }

    @Test("No temperature, no tyres or no usable pressure gives no note")
    func noteNeedsInputs() {
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: nil) == nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [], ambientCelsius: -10) == nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [0], ambientCelsius: -10) == nil)
        #expect(TyrePressureTemperature.note(tyreKilopascals: [250], ambientCelsius: .nan) == nil)
    }
}
