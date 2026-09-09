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
            let battery = state.batteryPercentage
            let fresh = state.hasFreshReading(.battery, now: now)
            checks.append(Check(id: "battery", title: L10n.text("Battery"),
                                detail: battery.map { Format.percent($0) } ?? L10n.text("Unavailable"),
                                status: fresh ? battery.map { $0 <= Double(lowBatteryThreshold) ? .attention : .reported } ?? .unknown : .unknown))
        }
        if state.powertrain.hasFuelRange {
            let fresh = state.hasFreshReading(.fuel, now: now)
            checks.append(Check(id: "fuel", title: L10n.text("Fuel"),
                                detail: state.fuelLevelPercent.map { Format.percent($0) } ?? L10n.text("Unavailable"),
                                status: fresh && state.fuelLevelPercent != nil ? .reported : .unknown))
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
        let warnings = state.healthDetails?.warnings ?? []
        checks.append(Check(id: "health", title: L10n.text("Vehicle Health"),
                            detail: warnings.isEmpty ? L10n.text("No active warnings reported") : warnings.map(\.displayName).joined(separator: ", "),
                            status: !state.hasFreshReading(.health, now: now) || state.healthDetails?.reportedWarnings.isEmpty != false
                                ? .unknown : warnings.isEmpty ? .reported : .attention))
        return checks
    }

    static func chargingByDeparture(_ state: VehicleState, departure: Date, now: Date = Date()) -> String {
        guard departure > now else { return L10n.text("Choose a future departure time.") }
        guard state.hasFreshReading(.battery, now: now), let battery = state.batteryPercentage,
              let target = state.chargeTargetPercentage else { return L10n.text("Fresh battery and charge-target readings are required.") }
        if battery >= Double(target) { return L10n.text("The reported charge target has been reached.") }
        guard state.isCharging, state.hasFreshReading(.charging, now: now),
              let minutes = state.remainingChargingMinutes, let timestamp = state.reportedDate(for: .charging) else {
            return L10n.text("No current charging estimate is available for this departure.")
        }
        let completion = timestamp.addingTimeInterval(TimeInterval(minutes) * 60)
        guard completion > now else { return L10n.text("The charging estimate needs a new vehicle reading.") }
        return completion <= departure
            ? L10n.text("The current vehicle estimate finishes before departure.")
            : L10n.text("The current vehicle estimate finishes after departure.")
    }
}
