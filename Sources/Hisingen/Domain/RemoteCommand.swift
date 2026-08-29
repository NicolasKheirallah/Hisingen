import Foundation

enum HeatingLevel: Int, Codable, CaseIterable, Sendable {
    case unspecified = 0
    case off = 1
    case level1 = 2
    case level2 = 3
    case level3 = 4

    var displayName: String {
        switch self {
        case .unspecified: return L10n.text("Vehicle default")
        case .off: return L10n.text("Off")
        case .level1: return L10n.text("Level 1")
        case .level2: return L10n.text("Level 2")
        case .level3: return L10n.text("Level 3")
        }
    }
}

enum RemoteCommandRisk: Equatable, Sendable {
    case routine
    case securitySensitive
    case destructive

    var requiresDeviceOwnerAuthentication: Bool { self != .routine }
}

enum RemoteCommand: Codable, Equatable, Sendable {
    case startClimate(temperatureCelsius: Float, frontLeftSeat: HeatingLevel,
                      frontRightSeat: HeatingLevel, rearLeftSeat: HeatingLevel,
                      rearRightSeat: HeatingLevel, steeringWheel: HeatingLevel)
    case stopClimate
    case startPreCleaning
    case stopPreCleaning
    case lock
    case lockReducedGuard
    case unlock
    case unlockTrunk
    case openTailgate
    case closeTailgate
    case openWindows
    case closeWindows
    case flashLights
    case honkAndFlash
    case honkHorn
    case setChargeTarget(Int)
    case setAmpLimit(Int)
    case startChargingOverride
    case stopChargingOverride
    case setGlobalChargeTimer(VehicleSchedule)
    case setClimateTimer(VehicleSchedule)
    case deleteClimateTimer(id: String)
    case scheduleOTA(delayMinutes: Int)
    case installOTANow
    case cancelOTA
    case createChargeLocationAtCar(alias: String, ampLimit: Int, minimumSoc: Int, optimisedCharging: Bool)
    case updateChargeLocationAlias(id: String, alias: String)
    case updateChargeLocationAmpLimit(id: String, amps: Int)
    case updateChargeLocationMinimumSoc(id: String, soc: Int)
    case setChargeLocationOptimisedCharging(id: String, enabled: Bool)
    case deleteChargeLocation(id: String)
    case startEngine(runtimeMinutes: Int)
    case stopEngine

    /// Whether *this app's client code for `brand`* can actually dispatch the command.
    ///
    /// Deliberately separate from `VehicleCapabilityProfile`, which answers a different
    /// question: what the vehicle is able to do. A command can be perfectly supported by the
    /// car and still unimplemented here, and the UI needs to tell those apart — otherwise a
    /// control appears live and fails at dispatch with a generic "unsupported". Keep this in
    /// sync with the `switch` in `VolvoAPI.dispatchCommand` / `PolestarGRPC.executeRemoteCommand`.
    func isImplemented(by brand: VehicleBrand) -> Bool {
        switch brand {
        case .polestar:
            // PolestarGRPC.executeRemoteCommand switches exhaustively over every case (except engine commands, which are Volvo ICE/PHEV specific).
            switch self {
            case .startEngine, .stopEngine, .lockReducedGuard:
                return false
            default:
                return true
            }
        case .volvo:
            // Volvo's Connected Vehicle API v2 exposes only these as command endpoints.
            switch self {
            case .lock, .lockReducedGuard, .unlock, .startClimate, .stopClimate,
                 .honkAndFlash, .flashLights, .honkHorn,
                 .startEngine, .stopEngine:
                return true
            default:
                return false
            }
        }
    }
    var feature: AppFeature {
        switch self {
        case .startClimate, .stopClimate, .startEngine, .stopEngine: return .remoteClimate
        case .startPreCleaning, .stopPreCleaning: return .remotePreCleaning
        case .lock, .lockReducedGuard, .unlock, .unlockTrunk, .openTailgate, .closeTailgate: return .remoteLocks
        case .openWindows, .closeWindows: return .remoteWindows
        case .flashLights, .honkAndFlash, .honkHorn: return .remoteHonkFlash
        case .setChargeTarget, .setAmpLimit, .startChargingOverride, .stopChargingOverride:
            return .remoteCharging
        case .setGlobalChargeTimer, .setClimateTimer, .deleteClimateTimer:
            return .remoteSchedules
        case .scheduleOTA, .installOTANow, .cancelOTA: return .remoteOTA
        case .createChargeLocationAtCar, .updateChargeLocationAlias,
             .updateChargeLocationAmpLimit, .updateChargeLocationMinimumSoc,
             .setChargeLocationOptimisedCharging, .deleteChargeLocation:
            return .remoteCharging
        }
    }

    var requiredCapability: VehicleCapability {
        switch self {
        case .startClimate, .stopClimate: return .climateStartStop
        case .startEngine, .stopEngine: return .engineStart
        case .startPreCleaning, .stopPreCleaning: return .preCleaning
        case .lock, .unlock: return .locks
        case .lockReducedGuard: return .reducedGuardLock
        case .unlockTrunk, .openTailgate, .closeTailgate: return .trunk
        case .openWindows, .closeWindows: return .windows
        case .flashLights, .honkAndFlash, .honkHorn: return .honkAndFlash
        case .setChargeTarget: return .chargeTarget
        case .setAmpLimit: return .chargingCurrentLimit
        case .startChargingOverride, .stopChargingOverride: return .chargingScheduleOverride
        case .setGlobalChargeTimer: return .chargingSchedule
        case .setClimateTimer, .deleteClimateTimer: return .climateTimers
        case .scheduleOTA, .installOTANow, .cancelOTA: return .softwareInstallControl
        case .createChargeLocationAtCar, .updateChargeLocationAlias,
             .updateChargeLocationAmpLimit, .updateChargeLocationMinimumSoc,
             .setChargeLocationOptimisedCharging, .deleteChargeLocation:
            return .chargeLocations
        }
    }

    func adapted(to profile: VehicleCapabilityProfile) -> RemoteCommand {
        guard case .startClimate(let temperature, let frontLeft, let frontRight,
                                 let rearLeft, let rearRight, let steeringWheel) = self else {
            return self
        }
        guard profile.permits(.climateStartStop) else { return self }
        return .startClimate(
            temperatureCelsius: profile.hasSelectableClimateTemperature ? temperature : 0,
            frontLeftSeat: profile.hasSelectableSeatHeating ? frontLeft : .unspecified,
            frontRightSeat: profile.hasSelectableSeatHeating ? frontRight : .unspecified,
            rearLeftSeat: profile.hasSelectableSeatHeating ? rearLeft : .unspecified,
            rearRightSeat: profile.hasSelectableSeatHeating ? rearRight : .unspecified,
            steeringWheel: profile.hasSelectableSteeringWheelHeating ? steeringWheel : .unspecified
        )
    }

    var risk: RemoteCommandRisk {
        switch self {
        case .unlock, .unlockTrunk, .openTailgate, .openWindows, .startEngine:
            return .securitySensitive
        case .installOTANow, .deleteClimateTimer, .deleteChargeLocation:
            return .destructive
        default:
            return .routine
        }
    }

    /// Past-tense summary of what the command did, for result banners — e.g.
    /// "AC turned on at 22 °C", "Vehicle locked". Distinct from `title`, which is an
    /// imperative ("Lock vehicle") suited to buttons and confirmations.
    var outcomeDescription: String {
        switch self {
        case .startClimate(let temperature, _, _, _, _, _):
            if temperature > 0 {
                let whole = temperature.truncatingRemainder(dividingBy: 1) == 0
                return whole ? L10n.format("AC turned on at %.0f °C", Double(temperature))
                             : L10n.format("AC turned on at %.1f °C", Double(temperature))
            }
            return L10n.text("AC (climate) turned on")
        case .stopClimate: return L10n.text("AC (climate) turned off")
        case .startEngine(let minutes): return L10n.format("Engine started (%d min)", minutes)
        case .stopEngine: return L10n.text("Engine stopped")
        case .startPreCleaning: return L10n.text("Cabin cleaning started")
        case .stopPreCleaning: return L10n.text("Cabin cleaning stopped")
        case .lock, .lockReducedGuard: return L10n.text("Vehicle locked")
        case .unlock: return L10n.text("Vehicle unlocked")
        case .unlockTrunk: return L10n.text("Trunk unlocked")
        case .openTailgate: return L10n.text("Tailgate opened")
        case .closeTailgate: return L10n.text("Tailgate closed")
        case .openWindows: return L10n.text("All windows opened")
        case .closeWindows: return L10n.text("All windows closed")
        case .flashLights: return L10n.text("Lights flashed")
        case .honkAndFlash: return L10n.text("Horn and lights activated")
        case .honkHorn: return L10n.text("Horn honked")
        case .setChargeTarget(let target): return L10n.format("Charge target set to %d%%", target)
        case .setAmpLimit(let amps): return L10n.format("Charging current set to %d A", amps)
        case .startChargingOverride: return L10n.text("Charging started (schedule overridden)")
        case .stopChargingOverride: return L10n.text("Charging schedule resumed")
        case .setGlobalChargeTimer: return L10n.text("Charging schedule saved")
        case .setClimateTimer: return L10n.text("Climate timer saved")
        case .deleteClimateTimer: return L10n.text("Climate timer deleted")
        case .scheduleOTA(let minutes): return L10n.format("Software installation scheduled in %d minutes", minutes)
        case .installOTANow: return L10n.text("Vehicle software installation started")
        case .cancelOTA: return L10n.text("Software installation cancelled")
        case .createChargeLocationAtCar(let alias, _, _, _):
            return L10n.format("Charge location \"%@\" saved", alias)
        case .updateChargeLocationAlias(_, let alias):
            return L10n.format("Charge location renamed to \"%@\"", alias)
        case .updateChargeLocationAmpLimit(_, let amps):
            return L10n.format("Location charging current set to %d A", amps)
        case .updateChargeLocationMinimumSoc(_, let soc):
            return L10n.format("Location minimum charge level set to %d%%", soc)
        case .setChargeLocationOptimisedCharging(_, let enabled):
            return enabled ? L10n.text("Optimised charging enabled at location")
                           : L10n.text("Optimised charging disabled at location")
        case .deleteChargeLocation:
            return L10n.text("Saved charge location deleted")
        }
    }

    var identifier: String {
        switch self {
        case .startClimate: return "start-climate"
        case .stopClimate: return "stop-climate"
        case .startEngine: return "start-engine"
        case .stopEngine: return "stop-engine"
        case .startPreCleaning: return "start-precleaning"
        case .stopPreCleaning: return "stop-precleaning"
        case .lock: return "lock"
        case .lockReducedGuard: return "lock-reduced-guard"
        case .unlock: return "unlock"
        case .unlockTrunk: return "unlock-trunk"
        case .openTailgate: return "open-tailgate"
        case .closeTailgate: return "close-tailgate"
        case .openWindows: return "open-windows"
        case .closeWindows: return "close-windows"
        case .flashLights: return "flash-lights"
        case .honkAndFlash: return "honk-flash"
        case .honkHorn: return "honk-horn"
        case .setChargeTarget: return "set-charge-target"
        case .setAmpLimit: return "set-amp-limit"
        case .startChargingOverride: return "start-charge-override"
        case .stopChargingOverride: return "stop-charge-override"
        case .setGlobalChargeTimer: return "set-charge-timer"
        case .setClimateTimer: return "set-climate-timer"
        case .deleteClimateTimer: return "delete-climate-timer"
        case .scheduleOTA: return "schedule-ota"
        case .installOTANow: return "install-ota"
        case .cancelOTA: return "cancel-ota"
        case .createChargeLocationAtCar: return "create-charge-location"
        case .updateChargeLocationAlias: return "rename-charge-location"
        case .updateChargeLocationAmpLimit: return "set-location-amp-limit"
        case .updateChargeLocationMinimumSoc: return "set-location-min-soc"
        case .setChargeLocationOptimisedCharging: return "set-location-optimised-charging"
        case .deleteChargeLocation: return "delete-charge-location"
        }
    }

    /// Display title honoring the user's temperature unit. The plain `title` stays metric
    /// (Celsius) for tests and metric-default callers; confirmation dialogs pass the
    /// selected unit so a Fahrenheit user never sees a Celsius setpoint.
    func title(temperatureUnit: TemperatureUnit) -> String {
        if case .startClimate(let temperature, _, _, _, _, _) = self, temperature > 0 {
            let whole = temperature.truncatingRemainder(dividingBy: 1) == 0
            let converted = temperatureUnit.convert(celsius: Double(temperature))
            switch temperatureUnit {
            case .celsius:
                return whole ? L10n.format("Start climate at %.0f °C", converted)
                             : L10n.format("Start climate at %.1f °C", converted)
            case .fahrenheit:
                return whole ? L10n.format("Start climate at %.0f °F", converted)
                             : L10n.format("Start climate at %.1f °F", converted)
            }
        }
        return title
    }

    var title: String {
        switch self {
        case .startClimate(let temperature, _, _, _, _, _):
            if temperature > 0 {
                return title(temperatureUnit: .celsius)
            }
            return L10n.text("Start climate (automatic)")
        case .stopClimate: return L10n.text("Stop climate")
        case .startEngine(let minutes): return L10n.format("Start engine (%d min)", minutes)
        case .stopEngine: return L10n.text("Stop engine")
        case .startPreCleaning: return L10n.text("Start cabin cleaning")
        case .stopPreCleaning: return L10n.text("Stop cabin cleaning")
        case .lock: return L10n.text("Lock vehicle")
        case .lockReducedGuard: return L10n.text("Lock with reduced guard")
        case .unlock: return L10n.text("Unlock vehicle")
        case .unlockTrunk: return L10n.text("Unlock trunk")
        case .openTailgate: return L10n.text("Open tailgate")
        case .closeTailgate: return L10n.text("Close tailgate")
        case .openWindows: return L10n.text("Open all windows")
        case .closeWindows: return L10n.text("Close all windows")
        case .flashLights: return L10n.text("Flash lights")
        case .honkAndFlash: return L10n.text("Honk and flash")
        case .honkHorn: return L10n.text("Honk horn")
        case .setChargeTarget(let target): return L10n.format("Set charge target to %d%%", target)
        case .setAmpLimit(let amps): return L10n.format("Set charging current to %d A", amps)
        case .startChargingOverride: return L10n.text("Charge now (override schedule)")
        case .stopChargingOverride: return L10n.text("Resume charging schedule")
        case .setGlobalChargeTimer: return L10n.text("Save charging schedule")
        case .setClimateTimer: return L10n.text("Save climate timer")
        case .deleteClimateTimer: return L10n.text("Delete climate timer")
        case .scheduleOTA(let minutes): return L10n.format("Schedule software installation in %d minutes", minutes)
        case .installOTANow: return L10n.text("Install vehicle software now")
        case .cancelOTA: return L10n.text("Cancel software installation")
        case .createChargeLocationAtCar(let alias, _, _, _):
            return L10n.format("Save charge location \"%@\" at the car's position", alias)
        case .updateChargeLocationAlias(_, let alias):
            return L10n.format("Rename charge location to \"%@\"", alias)
        case .updateChargeLocationAmpLimit(_, let amps):
            return L10n.format("Set location charging current to %d A", amps)
        case .updateChargeLocationMinimumSoc(_, let soc):
            return L10n.format("Set location minimum charge level to %d%%", soc)
        case .setChargeLocationOptimisedCharging(_, let enabled):
            return enabled ? L10n.text("Enable optimised charging at location")
                           : L10n.text("Disable optimised charging at location")
        case .deleteChargeLocation:
            return L10n.text("Delete saved charge location")
        }
    }
}

enum RemoteCommandOutcome: String, Codable, Sendable {
    case accepted
    case delivered
    case completed
}

/// The last remote-command result, surfaced inline in the Controls tab so a success or (more
/// importantly) a failure is visible even when system notifications are muted or denied.
/// `id` changes on every new result so the view can re-trigger its auto-dismiss timer.
struct RemoteCommandFeedback: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let message: String
    let success: Bool
    let issuedAt: Date

    init(id: UUID = UUID(), title: String, message: String, success: Bool, issuedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.message = message
        self.success = success
        self.issuedAt = issuedAt
    }
}

struct RemoteCommandResult: Codable, Equatable, Sendable {
    let outcome: RemoteCommandOutcome
    let message: String?
}

enum RemoteCommandError: Error, LocalizedError, Equatable, Sendable {
    case busy
    case disabled
    case unsupported
    case missingContext
    case rejected(String?)

    var errorDescription: String? {
        switch self {
        case .busy: return L10n.text("Another remote command is already running.")
        case .disabled: return L10n.text("This remote-control feature is disabled in Settings.")
        case .unsupported: return L10n.text("This command is not supported by this vehicle or backend.")
        case .missingContext: return L10n.text("Refresh vehicle data before using this command.")
        case .rejected(let message): return message ?? L10n.text("The vehicle rejected the remote command.")
        }
    }
}

