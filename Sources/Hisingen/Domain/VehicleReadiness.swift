import Foundation

struct VehicleReadiness {
    enum Status: Equatable { case reported, attention, unknown }
    struct Check: Identifiable {
        let id: String
        let title: String
        let detail: String
        let status: Status
    }

    static func checks(_ state: VehicleState, lowBatteryThreshold: Int, now: Date = Date()) -> [Check] {
        var checks: [Check] = []
        if state.powertrain.hasElectricRange {
            let battery = state.energy.batteryPercentage
            let fresh = state.hasFreshReading(.battery, now: now)
            checks.append(Check(id: "battery", title: L10n.text("Battery"),
                                detail: battery.map { Format.percent($0) } ?? L10n.text("Unavailable"),
                                status: fresh ? battery.map { $0 <= Double(lowBatteryThreshold) ? .attention : .reported } ?? .unknown : .unknown))
        }
        if state.powertrain.hasFuelRange {
            let fresh = state.hasFreshReading(.fuel, now: now)
            checks.append(Check(id: "fuel", title: L10n.text("Fuel"),
                                detail: state.fuelSystem.levelPercent.map { Format.percent($0) } ?? L10n.text("Unavailable"),
                                status: fresh && state.fuelSystem.levelPercent != nil ? .reported : .unknown))
        }
        let locked = state.exteriorStatus?.isLocked
        checks.append(Check(id: "locks", title: L10n.text("Locks"),
                            detail: locked.map { L10n.text($0 ? "Locked" : "Unlocked") } ?? L10n.text("Unavailable"),
                            status: !state.hasFreshReading(.locks, now: now) || locked == nil ? .unknown : locked == true ? .reported : .attention))
        if let exterior = state.exteriorStatus, !exterior.openings.isEmpty {
            let open = exterior.itemsNeedingAttention
            checks.append(Check(id: "openings", title: L10n.text("Doors & Openings"),
                                detail: open.isEmpty ? L10n.text("No reported openings are open.") : open.map(\.displayName).joined(separator: ", "),
                                status: !state.hasFreshReading(.openings, now: now) || exterior.openings.contains(where: { $0.state == .unknown })
                                    ? .unknown : open.isEmpty ? .reported : .attention))
        }
        let warnings = state.maintenance.details?.warnings ?? []
        checks.append(Check(id: "health", title: L10n.text("Vehicle Health"),
                            detail: warnings.isEmpty ? L10n.text("No active warnings reported") : warnings.map(\.displayName).joined(separator: ", "),
                            status: !state.hasFreshReading(.health, now: now) || state.maintenance.details?.reportedWarnings.isEmpty != false
                                ? .unknown : warnings.isEmpty ? .reported : .attention))
        return checks
    }

    struct DepartureAssessment: Equatable {
        let message: String
        var estimateDestination: String? = nil
    }

    static func chargingByDeparture(_ state: VehicleState, departure: Date, now: Date = Date()) -> String {
        assessDeparture(state, departure: departure, now: now).message
    }

    static func assessDeparture(_ state: VehicleState, departure: Date, now: Date = Date()) -> DepartureAssessment {
        guard departure > now else { return .init(message: L10n.text("Choose a future departure time.")) }
        guard state.hasFreshReading(.battery, now: now), let battery = state.energy.batteryPercentage,
              let target = state.energy.targetPercentage else {
            return .init(message: L10n.text("Fresh battery and charge-target readings are required."))
        }
        if battery >= Double(target) {
            return .init(message: L10n.text("The reported charge target has been reached."))
        }
        guard state.hasFreshReading(.charging, now: now) else {
            return .init(message: L10n.text("No current charging estimate is available for this departure."))
        }
        guard state.energy.connection != .disconnected && state.energy.connection != .fault, state.isCharging else {
            return .init(message: state.chargingExplanation)
        }
        guard
              let minutes = state.remainingChargingMinutes, let timestamp = state.reportedDate(for: .charging) else {
            return .init(message: L10n.text("No current charging estimate is available for this departure."))
        }
        let completion = timestamp.addingTimeInterval(TimeInterval(minutes) * 60)
        guard completion > now else {
            return .init(message: L10n.text("The charging estimate needs a new vehicle reading."))
        }
        let message = completion <= departure
            ? L10n.text("The current vehicle estimate finishes before departure.")
            : L10n.text("The current vehicle estimate finishes after departure.")
        return .init(message: message, estimateDestination: state.chargingEstimateDestination)
    }
}
