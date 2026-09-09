import Foundation

enum VehicleReading: String, Codable, CaseIterable, Sendable {
    case battery, range, charging, locks, openings, health, odometer, software, airQuality, connectivity, location, fuel

    var title: String {
        switch self {
        case .battery: return L10n.text("Battery")
        case .range: return L10n.text("Range")
        case .charging: return L10n.text("Charging")
        case .locks: return L10n.text("Locks")
        case .openings: return L10n.text("Doors & Openings")
        case .health: return L10n.text("Vehicle Health")
        case .odometer: return L10n.text("Odometer")
        case .software: return L10n.text("Software")
        case .airQuality: return L10n.text("Air Quality")
        case .connectivity: return L10n.text("Connectivity")
        case .location: return L10n.text("Location")
        case .fuel: return L10n.text("Fuel")
        }
    }
}

extension VehicleState {
    var remainingChargingMinutes: Int? {
        [estimatedChargingTimeToTargetMinutes, batteryDiagnostics?.timeToTargetMinutes,
         estimatedChargingTimeToFullMinutes].compactMap { $0 }.first { $0 > 0 }
    }

    var chargingEstimateDestination: String {
        if (estimatedChargingTimeToTargetMinutes ?? batteryDiagnostics?.timeToTargetMinutes ?? 0) > 0 {
            return chargeTargetPercentage.map { L10n.format("Target %@", Format.percent(Double($0))) }
                ?? L10n.text("Charge target")
        }
        return L10n.text("Full charge")
    }

    var chargingExplanation: String {
        if chargerConnection == .fault { return L10n.text("The vehicle reports a charger connection fault.") }
        if chargingState == .fault { return L10n.text("The vehicle reports a charging fault.") }
        if chargerConnection == .disconnected { return L10n.text("The charging cable is disconnected.") }
        switch chargingState {
        case .fault: return L10n.text("The vehicle reports a charging fault.")
        case .scheduled: return L10n.text("Charging is scheduled by the vehicle.")
        case .paused: return L10n.text("Smart charging is paused by the vehicle.")
        case .complete: return L10n.text("The vehicle reports charging complete.")
        case .charging, .smartCharging:
            return chargingPowerWatts.map { $0 > 0 } == true
                ? L10n.text("The vehicle reports active charging and power delivery.")
                : L10n.text("Charging is reported active; power delivery is not confirmed by this reading.")
        case .discharging: return L10n.text("The vehicle reports discharging.")
        case .idle:
            return chargerConnection == .connected
                ? L10n.text("The cable is connected, but the vehicle reports no active charging.")
                : L10n.text("The vehicle reports no active charging.")
        case .unknown: return L10n.text("The vehicle has not reported a known charging state.")
        }
    }

    func reportedDate(for reading: VehicleReading) -> Date? {
        if let explicit = readingDates[reading] { return explicit }
        switch reading {
        case .locks, .openings: return exteriorStatus?.reportedAt
        case .software: return softwareInfo?.updatedAt
        case .airQuality: return airQuality?.reportedAt
        case .connectivity: return connectivity?.updatedAt
        case .location: return location?.timestamp
        default: return nil
        }
    }

    func hasFreshReading(_ reading: VehicleReading, now: Date = Date(), maximumAge: TimeInterval = 600) -> Bool {
        guard !isCachedSnapshot, let date = reportedDate(for: reading) else { return false }
        let age = now.timeIntervalSince(date)
        return age >= -60 && age <= maximumAge
    }
}
