import Foundation

struct ParkedChargeLossDetector {
    private struct Observation {
        let date: Date
        let battery: Double
        let odometer: Int
    }
    private struct Window {
        let start: Observation
        var last: Observation
    }
    private var windows: [String: Window] = [:]

    mutating func reset(vin: String? = nil) {
        if let vin { windows.removeValue(forKey: vin) } else { windows.removeAll() }
    }

    mutating func ingest(_ state: VehicleState) -> VehicleActivity? {
        guard state.hasFreshReading(.battery, now: state.freshness.fetchedAt),
              state.hasFreshReading(.odometer, now: state.freshness.fetchedAt),
              state.hasFreshReading(.charging, now: state.freshness.fetchedAt),
              let date = state.reportedDate(for: .battery), let battery = state.energy.batteryPercentage,
              battery.isFinite, (0...100).contains(battery), let odometer = state.maintenance.odometerKm,
              odometer >= 0, state.energy.connection == .disconnected,
              state.energy.chargingState == .idle || state.energy.chargingState == .complete,
              !state.isClimateActive, state.fuelSystem.isEngineRunning != true else {
            reset(vin: state.identity.vin)
            return nil
        }
        let observation = Observation(date: date, battery: battery, odometer: odometer)
        guard var window = windows[state.identity.vin] else {
            windows[state.identity.vin] = Window(start: observation, last: observation)
            return nil
        }
        guard date > window.last.date else { return nil }
        guard date.timeIntervalSince(window.last.date) <= 20 * 60,
              odometer == window.last.odometer, battery <= window.last.battery else {
            windows[state.identity.vin] = Window(start: observation, last: observation)
            return nil
        }
        window.last = observation
        windows[state.identity.vin] = window
        guard date.timeIntervalSince(window.start.date) >= 30 * 60 else { return nil }
        windows[state.identity.vin] = Window(start: observation, last: observation)
        guard window.start.battery - battery >= 1 else { return nil }
        return VehicleActivity(vin: state.identity.vin, timestamp: date, kind: .parkedChargeLoss,
                               subject: "battery", before: String(window.start.battery), after: String(battery),
                               intervalStart: window.start.date)
    }
}
