import Foundation

/// What the Settings pane can say about a catalogued card on this car right now.
///
/// The pane used to imply that every listed row was on the tab. The structural roster fixed
/// that; this answers the remaining question, which is whether the car has reported what the
/// card draws. The tab views ask the same content predicates in `VehicleState+CardContent`, so
/// a card is never listed as reported by one rule and gated by another.
enum TabItemAvailability: Equatable, Sendable {
    case drawable
    /// The reader switched this card's reading off in Settings → Features.
    case switchedOff
    /// The car has not reported the reading yet, so the card has nothing to draw.
    case notReported
    /// This vehicle does not have the capability the card needs.
    case notSupported
    /// The card reads a service the reader has not signed in to.
    case notSignedIn

    static func of(
        _ item: TabItemID,
        state: VehicleState?,
        enabledFeatures: Set<AppFeature>,
        plannerAvailable: Bool,
        homeChargerSignedIn: Bool = false
    ) -> TabItemAvailability {
        if item == .vehicleHomeCharger, !homeChargerSignedIn { return .notSignedIn }
        if let feature = TabItemCatalog.item(item)?.feature, !enabledFeatures.contains(feature) {
            // Two controls draw from a second feature as well: climate can run pre-cleaning,
            // and the windows card can honk and flash without the windows permission.
            let drawsFromAlternative: Bool = {
                guard let state else { return false }
                switch item {
                case .controlsClimate:
                    return enabledFeatures.contains(.remotePreCleaning)
                        && state.capabilityProfile.permits(.preCleaning)
                case .controlsWindowsLocate:
                    return enabledFeatures.contains(.remoteHonkFlash)
                default:
                    return false
                }
            }()
            guard drawsFromAlternative else { return .switchedOff }
        }
        guard let state else { return .drawable }

        switch item {
        case .vehicleChargingPlanner, .controlsChargingPlanner:
            guard state.powertrain.hasElectricRange, plannerAvailable else { return .notSupported }
            return state.energy.batteryPercentage != nil && state.energy.targetPercentage != nil
                ? .drawable : .notReported

        case .controlsCharging:
            return state.powertrain.hasElectricRange ? .drawable : .notSupported

        case .vehicleFuelEngine:
            guard state.powertrain.hasCombustionEngine else { return .notSupported }
            return state.fuelSystem.levelPercent != nil || state.fuelSystem.isEngineRunning != nil
                ? .drawable : .notReported

        case .controlsEngine:
            guard state.powertrain.hasCombustionEngine, state.isVolvo else { return .notSupported }
            return state.fuelSystem.levelPercent != nil || state.fuelSystem.isEngineRunning != nil
                ? .drawable : .notReported

        case .vehicleReceipts, .controlsReceipts:
            return state.commandState.receipts.isEmpty ? .notReported : .drawable

        case .vehicleWeather, .infoWeather:
            return state.hasWeatherContent ? .drawable : .notReported

        case .infoTrip:
            return state.hasTripContent ? .drawable : .notReported

        case .infoSoftware:
            return state.hasSoftwareContent ? .drawable : .notReported

        case .infoBatteryHealth:
            return state.powertrain.hasElectricRange ? .drawable : .notSupported

        case .infoAirQuality:
            return state.airQuality == nil ? .notReported : .drawable

        case .infoConnectivity:
            return state.connectivity == nil && state.identity.usageModeDisplayName == nil
                ? .notReported : .drawable

        case .infoChargeLocations:
            return state.hasSavedChargeLocations ? .drawable : .notReported

        case .infoExterior:
            return state.hasExteriorContent ? .drawable : .notReported

        case .infoInterior:
            return state.hasInteriorContent ? .drawable : .notReported

        case .infoFreshness:
            return state.hasReportedDates ? .drawable : .notReported

        case .vehicleReadiness:
            guard state.powertrain.hasElectricRange else { return .notSupported }
            return enabledFeatures.contains(.vehicleHealth) || enabledFeatures.contains(.exteriorStatus)
                ? .drawable : .switchedOff

        case .controlsRoutines:
            return enabledFeatures.isDisjoint(with: AppFeature.remoteFeatures) ? .switchedOff : .drawable

        case .historyChargingSessions, .historyChargingCurve, .historyMonthlyCharging,
             .historyChargeLocations, .historyChargingHistory, .historyBatteryHealth:
            return state.powertrain.hasElectricRange ? .drawable : .notSupported

        case .historyFuelEconomy, .historyRecentFills, .historyConsumption:
            return state.powertrain.hasCombustionEngine ? .drawable : .notSupported

        default:
            return .drawable
        }
    }
}
