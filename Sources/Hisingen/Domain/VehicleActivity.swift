import Foundation

struct VehicleActivity: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case warning, software, charging, locks, airCleaning, parkedChargeLoss }
    let vin: String
    let timestamp: Date
    let kind: Kind
    let subject: String
    let before: String
    let after: String
    var intervalStart: Date? = nil

    var id: String { "\(vin)|\(timestamp.timeIntervalSince1970)|\(kind.rawValue)|\(subject)|\(after)" }
    var title: String {
        switch kind {
        case .warning: return VehicleWarning(rawValue: subject)?.displayName ?? subject
        case .software: return L10n.text("Installed Software")
        case .charging: return L10n.text("Charging")
        case .locks: return L10n.text("Locks")
        case .airCleaning: return L10n.text("Air Cleaning")
        case .parkedChargeLoss: return L10n.text("Observed Parked Charge Loss")
        }
    }
    var summary: String {
        if kind == .parkedChargeLoss, let start = intervalStart,
           let old = Double(before), let new = Double(after) {
            return L10n.format("%@ to %@ over %@ with unchanged reported odometer. Estimated parked loss; short trips, auxiliary use and battery recalibration cannot be ruled out.",
                               Format.percent(old), Format.percent(new),
                               Format.shortDuration(minutes: Int(timestamp.timeIntervalSince(start) / 60)))
        }
        return "\(displayValue(before)) → \(displayValue(after))"
    }

    private func displayValue(_ value: String) -> String {
        if kind == .airCleaning, let state = AirCleaningState(rawValue: value) { return state.displayName }
        return kind == .software ? value : L10n.text(value)
    }

    static func changes(from previous: VehicleState?, to current: VehicleState) -> [VehicleActivity] {
        guard let previous, previous.vin == current.vin, !current.isCachedSnapshot,
              current.fetchedAt > previous.fetchedAt else { return [] }
        var events: [VehicleActivity] = []
        func changed(_ kind: Kind, _ reading: VehicleReading, _ subject: String, _ before: String?, _ after: String?) {
            guard let before, let after, before != after,
                  let date = current.reportedDate(for: reading),
                  let oldDate = previous.reportedDate(for: reading), date > oldDate,
                  current.hasFreshReading(reading, now: current.fetchedAt) else { return }
            events.append(VehicleActivity(vin: current.vin, timestamp: date, kind: kind,
                                          subject: subject, before: before, after: after))
        }
        if let old = previous.healthDetails, let new = current.healthDetails {
            for warning in Set(old.reportedWarnings).intersection(new.reportedWarnings) {
                changed(.warning, .health, warning.rawValue,
                        old.warnings.contains(warning) ? "Active" : "Clear",
                        new.warnings.contains(warning) ? "Active" : "Clear")
            }
        }
        // Installed version is a configuration observation; MyCars has no vehicle timestamp.
        if let before = previous.softwareInfo?.installedVersion,
           let after = current.softwareInfo?.installedVersion, before != after,
           !current.retainedDataCategories.contains(.softwareUpdates) {
            events.append(VehicleActivity(vin: current.vin, timestamp: current.fetchedAt,
                                          kind: .software, subject: "installed", before: before, after: after))
        }
        changed(.locks, .locks, "centralLock", previous.exteriorStatus?.isLocked.map { $0 ? "Locked" : "Unlocked" },
                current.exteriorStatus?.isLocked.map { $0 ? "Locked" : "Unlocked" })
        if case .unknown = current.chargingState { } else if case .unknown = previous.chargingState { } else {
            changed(.charging, .charging, "state", previous.chargingState.displayName, current.chargingState.displayName)
        }
        if let old = previous.airQuality, let new = current.airQuality,
           old.cleaningState != .unknown, new.cleaningState != .unknown {
            changed(.airCleaning, .airQuality, "state", old.cleaningState.rawValue, new.cleaningState.rawValue)
        }
        return events.sorted { $0.id < $1.id }
    }
}
