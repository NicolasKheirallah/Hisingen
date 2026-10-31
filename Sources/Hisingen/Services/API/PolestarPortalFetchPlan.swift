import Foundation

struct PolestarPortalFetchPlan: Sendable {
    private enum Endpoint: CaseIterable {
        case battery, exterior, health, odometer, location, availability, climate
        case target, amp, now, locations, timer, climateTimer, cleaning
    }
    static let maximumCost = Endpoint.allCases.count
    let needsBattery: Bool
    let needsExterior: Bool
    let needsHealth: Bool
    let needsOdometer: Bool
    let needsLocation: Bool
    let needsAvailability: Bool
    let needsClimate: Bool
    let needsTargetSoc: Bool
    let needsAmpLimit: Bool
    let needsChargeNow: Bool
    let needsChargeLocations: Bool
    let needsGlobalChargeTimer: Bool
    let needsParkingClimateTimer: Bool
    let needsPreCleaning: Bool
    let estimatedCost: Int

    init(features: FeatureSelection, budget: Int, rotation: Int = Calendar(identifier: .gregorian).component(.hour, from: Date())) {
        let candidates: [(Endpoint, Bool)] = [
            (.battery, features.contains(.chargingDetails) || features.contains(.batteryDiagnostics)),
            (.exterior, features.contains(.exteriorStatus)),
            (.health, features.contains(.vehicleHealth) || features.contains(.tyreAndWarnings)),
            (.odometer, features.contains(.vehicleHealth) || features.contains(.tripMeters)),
            (.location, features.contains(.vehicleLocation) || features.contains(.vehicleWeather)),
            (.availability, features.contains(.vehicleAvailability)),
            (.climate, features.contains(.climateStatus) || features.contains(.remoteClimate)),
            (.target, features.contains(.chargingDetails) || features.contains(.remoteCharging)),
            (.amp, features.contains(.chargingDetails) || features.contains(.remoteCharging)),
            (.now, features.contains(.chargingDetails) || features.contains(.remoteCharging)),
            (.locations, features.contains(.chargingDetails) || features.contains(.chargingSchedule) || features.contains(.remoteSchedules)),
            (.timer, features.contains(.chargingSchedule) || features.contains(.remoteSchedules) || features.contains(.chargingDetails)),
            (.climateTimer, features.contains(.climateStatus) || features.contains(.remoteClimate) || features.contains(.chargingSchedule)),
            (.cleaning, features.contains(.airQuality) || features.contains(.remotePreCleaning))
        ]
        let wanted = candidates.filter { $0.1 }.map { $0.0 }
        let core: [Endpoint] = wanted.contains(.battery) ? [.battery] : []
        let optional = wanted.filter { $0 != .battery }
        let start = optional.isEmpty ? 0 : ((rotation % optional.count) + optional.count) % optional.count
        let ordered = core + Array(optional.dropFirst(start)) + Array(optional.prefix(start))
        let chosen = Set(ordered.prefix(max(0, budget)))
        needsBattery = chosen.contains(.battery)
        needsExterior = chosen.contains(.exterior)
        needsHealth = chosen.contains(.health)
        needsOdometer = chosen.contains(.odometer)
        needsLocation = chosen.contains(.location)
        needsAvailability = chosen.contains(.availability)
        needsClimate = chosen.contains(.climate)
        needsTargetSoc = chosen.contains(.target)
        needsAmpLimit = chosen.contains(.amp)
        needsChargeNow = chosen.contains(.now)
        needsChargeLocations = chosen.contains(.locations)
        needsGlobalChargeTimer = chosen.contains(.timer)
        needsParkingClimateTimer = chosen.contains(.climateTimer)
        needsPreCleaning = chosen.contains(.cleaning)
        estimatedCost = chosen.count
    }
}
