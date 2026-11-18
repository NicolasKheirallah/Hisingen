import Foundation

/// Whether the snapshot carries enough for a card to draw.
///
/// The tab views ask these before building a section, and the Settings pane asks the same
/// functions when it explains why a listed card is not on the tab. One declaration, two readers.
extension VehicleState {
    var hasWeatherContent: Bool { weather?.hasCurrentConditions == true }

    var hasSoftwareContent: Bool {
        guard let software = softwareInfo else { return false }
        return software.noUpdateAvailable == true
            || software.installedVersion?.isEmpty == false
            || software.version?.isEmpty == false
            || software.latestAvailableVersion?.isEmpty == false
            || software.state != .unknown
            || software.scheduledAt != nil
    }

    var hasTripContent: Bool {
        tripComputer.manualTripKm != nil
            || tripComputer.automaticTripKm != nil
            || tripComputer.sinceChargeTripKm != nil
            || tripComputer.averageSpeedKmH != nil
    }

    var hasExteriorContent: Bool {
        identity.externalColour?.isEmpty == false
            || (exteriorStatus?.physicalDoorCount ?? 0) > 0
    }

    var hasInteriorContent: Bool {
        identity.upholstery?.isEmpty == false
            || formattedSteeringOrientation?.isEmpty == false
            || climateStatus != nil
    }

    var savedChargeLocations: [ChargeLocationSnapshot] {
        energy.locations.filter { $0.isSavedLocation || !$0.alias.isEmpty }
    }

    var hasSavedChargeLocations: Bool { !savedChargeLocations.isEmpty }

    var hasReportedDates: Bool {
        VehicleReading.allCases.contains { reportedDate(for: $0) != nil }
    }
}
