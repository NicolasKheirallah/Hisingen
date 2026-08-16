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
        }
    }

    var detail: String {
        switch self {
        case .vehicleIdentity: return L10n.text("Show model, year, plate, and VIN.")
        case .ownerGreeting: return L10n.text("Fetch and show the Polestar ID first name.")
        case .vehicleImage: return L10n.text("Download and show the configured studio image.")
        case .chargingDetails: return L10n.text("Fetch connection, target, type, power, current, and voltage.")
        case .vehicleAvailability: return L10n.text("Fetch online state and unavailable reason.")
        case .vehicleHealth: return L10n.text("Request odometer, service interval, and fluid warnings.")
        case .exteriorStatus: return L10n.text("Show lock state and warn about open doors, windows, hood, or tailgate.")
        case .tyreAndWarnings: return L10n.text("Show reported tyre pressures, lights, fluids, and 12 V warnings.")
        case .softwareUpdates: return L10n.text("Show read-only vehicle software and OTA status.")
        case .chargingSchedule: return L10n.text("Show read-only charging and departure schedules without storing locations.")
        case .climateStatus: return L10n.text("Show preconditioning status and read-only climate timers.")
        case .tripMeters: return L10n.text("Show manual and automatic trip-meter distances.")
        case .connectivityDiagnostics: return L10n.text("Show legacy vehicle network and signal diagnostics when available.")
        case .airQuality: return L10n.text("Show cabin pre-cleaning and reported air-quality values.")
        case .batteryDiagnostics: return L10n.text("Show charger power and reported consumption diagnostics.")
        case .vehicleWeather: return L10n.text("Show the current weather at your vehicle's position.")
        case .vehicleLocation: return L10n.text("Show vehicle parking GPS coordinates and 1-click Apple Maps integration.")
        case .multipleVehicles: return L10n.text("Show the vehicle selector for multi-car accounts.")
        case .notifications: return L10n.text("Enable local charging and account notifications.")
        case .updateChecks: return L10n.text("Check GitHub for stable Hisingen releases.")
        case .remoteClimate: return L10n.text("Start or stop climate with your configured temperature and heating.")
        case .remotePreCleaning: return L10n.text("Start or stop cabin pre-cleaning where supported.")
        case .remoteCharging: return L10n.text("Change charge target/current and override an active charging schedule.")
        case .remoteSchedules: return L10n.text("Create or update charging and parking-climate schedules.")
        case .remoteLocks: return L10n.text("Lock or authenticate to unlock the vehicle or trunk.")
        case .remoteWindows: return L10n.text("Open or close all windows; opening requires authentication.")
        case .remoteHonkFlash: return L10n.text("Flash the lights or honk and flash on explicit request.")
        case .remoteOTA: return L10n.text("Schedule, install, or cancel vehicle software updates with confirmation.")
        }
    }

    static let remoteFeatures: Set<AppFeature> = [
        .remoteClimate, .remotePreCleaning, .remoteCharging, .remoteSchedules,
        .remoteLocks, .remoteWindows, .remoteHonkFlash, .remoteOTA
    ]

    static var userSelectableCases: [AppFeature] {
        allCases
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
            .tripMeters, .vehicleLocation,
            .multipleVehicles, .notifications, .updateChecks
        ])
    }

    func contains(_ feature: AppFeature) -> Bool { enabled.contains(feature) }

    mutating func set(_ feature: AppFeature, enabled isEnabled: Bool) {
        if isEnabled { enabled.insert(feature) }
        else { enabled.remove(feature) }
    }
}


