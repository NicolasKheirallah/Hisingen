import Foundation

enum AppFeature: String, CaseIterable, Codable, Hashable, Sendable {
    case vehicleIdentity = "vehicle-identity"
    case ownerGreeting = "owner-greeting"
    case vehicleImage = "vehicle-image"
    case chargingDetails = "charging-details"
    case vehicleAvailability = "vehicle-availability"
    case vehicleHealth = "vehicle-health"
    case exteriorStatus = "exterior-status"
    case tyreAndWarnings = "tyre-and-warnings"
    case softwareUpdates = "software-updates"
    case chargingSchedule = "charging-schedule"
    case climateStatus = "climate-status"
    case tripMeters = "trip-meters"
    case connectivityDiagnostics = "connectivity-diagnostics"
    case airQuality = "air-quality"
    case batteryDiagnostics = "battery-diagnostics"
    case vehicleWeather = "vehicle-weather"
    case vehicleLocation = "vehicle-location"
    case multipleVehicles = "multiple-vehicles"
    case notifications = "notifications"
    case updateChecks = "update-checks"
    case remoteClimate = "remote-climate"
    case remotePreCleaning = "remote-precleaning"
    case remoteCharging = "remote-charging"
    case remoteSchedules = "remote-schedules"
    case remoteLocks = "remote-locks"
    case remoteWindows = "remote-windows"
    case remoteHonkFlash = "remote-honk-flash"
    case remoteOTA = "remote-ota"
    case realTimeUpdates = "real-time-updates"
    case smartChargingPlanner = "smart-charging-planner"

    var title: String {
        switch self {
        case .vehicleIdentity: return L10n.text("Vehicle details")
        case .ownerGreeting: return L10n.text("Owner greeting")
        case .vehicleImage: return L10n.text("Vehicle image")
        case .chargingDetails: return L10n.text("Charging details")
        case .vehicleAvailability: return L10n.text("Availability")
        case .vehicleHealth: return L10n.text("Odometer & service")
        case .exteriorStatus: return L10n.text("Exterior status")
        case .tyreAndWarnings: return L10n.text("Tyres & warnings")
        case .softwareUpdates: return L10n.text("Vehicle software")
        case .chargingSchedule: return L10n.text("Charging schedules")
        case .climateStatus: return L10n.text("Climate & timers")
        case .tripMeters: return L10n.text("Trip meters")
        case .connectivityDiagnostics: return L10n.text("Connectivity diagnostics")
        case .airQuality: return L10n.text("Air quality")
        case .batteryDiagnostics: return L10n.text("Battery diagnostics")
        case .vehicleWeather: return L10n.text("Vehicle weather")
        case .vehicleLocation: return L10n.text("Vehicle location & maps")
        case .multipleVehicles: return L10n.text("Vehicle switcher")
        case .notifications: return L10n.text("Notifications")
        case .updateChecks: return L10n.text("Update checks")
        case .remoteClimate: return L10n.text("Climate controls")
        case .remotePreCleaning: return L10n.text("Cabin-cleaning controls")
        case .remoteCharging: return L10n.text("Charging controls")
        case .remoteSchedules: return L10n.text("Schedule controls")
        case .remoteLocks: return L10n.text("Lock controls")
        case .remoteWindows: return L10n.text("Window controls")
        case .remoteHonkFlash: return L10n.text("Honk & flash controls")
        case .remoteOTA: return L10n.text("Vehicle software controls")
        case .realTimeUpdates: return L10n.text("Real-time updates")
        case .smartChargingPlanner: return L10n.text("Smart Charging Planner")
        }
    }

    static let remoteFeatures: Set<AppFeature> = [
        .remoteClimate, .remotePreCleaning, .remoteCharging, .remoteSchedules,
        .remoteLocks, .remoteWindows, .remoteHonkFlash, .remoteOTA
    ]

    static var userSelectableCases: [AppFeature] {
        allCases
    }

    /// Features safe to enable in one batch. Remote commands stay an explicit choice:
    /// some can move vehicle hardware or expose location and must never be swept in by
    /// a broad convenience action.
    static var safeBulkEnableCases: [AppFeature] {
        userSelectableCases.filter { !$0.isRemoteControl }
    }

    static var permittedFeatures: Set<AppFeature> { Set(allCases) }

    var isRemoteControl: Bool { Self.remoteFeatures.contains(self) }
}

struct FeatureSelection: Codable, Equatable, Sendable {
    private(set) var enabled: Set<AppFeature>

    static var `default`: FeatureSelection {
        FeatureSelection(enabled: [
            .vehicleIdentity, .ownerGreeting, .vehicleImage, .chargingDetails,
            .vehicleAvailability, .exteriorStatus,
            .tyreAndWarnings, .softwareUpdates, .climateStatus,
            .tripMeters, .vehicleLocation, .vehicleWeather, .batteryDiagnostics,
            .multipleVehicles, .notifications, .updateChecks, .realTimeUpdates
        ])
    }

    func contains(_ feature: AppFeature) -> Bool { enabled.contains(feature) }

    mutating func set(_ feature: AppFeature, enabled isEnabled: Bool) {
        if isEnabled { enabled.insert(feature) }
        else { enabled.remove(feature) }
    }
}
