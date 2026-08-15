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
    case unlock
    case unlockTrunk
    case openWindows
    case closeWindows
    case flashLights
    case honkAndFlash
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

    var feature: AppFeature {
        switch self {
        case .startClimate, .stopClimate: return .remoteClimate
        case .startPreCleaning, .stopPreCleaning: return .remotePreCleaning
        case .lock, .unlock, .unlockTrunk: return .remoteLocks
        case .openWindows, .closeWindows: return .remoteWindows
        case .flashLights, .honkAndFlash: return .remoteHonkFlash
        case .setChargeTarget, .setAmpLimit, .startChargingOverride, .stopChargingOverride:
            return .remoteCharging
        case .setGlobalChargeTimer, .setClimateTimer, .deleteClimateTimer:
            return .remoteSchedules
        case .scheduleOTA, .installOTANow, .cancelOTA: return .remoteOTA
        }
    }

    var requiredCapability: VehicleCapability {
        switch self {
        case .startClimate, .stopClimate: return .climateStartStop
        case .startPreCleaning, .stopPreCleaning: return .preCleaning
        case .lock, .unlock: return .locks
        case .unlockTrunk: return .trunk
        case .openWindows, .closeWindows: return .windows
        case .flashLights, .honkAndFlash: return .honkAndFlash
        case .setChargeTarget: return .chargeTarget
        case .setAmpLimit: return .chargingCurrentLimit
        case .startChargingOverride, .stopChargingOverride: return .chargingScheduleOverride
        case .setGlobalChargeTimer: return .chargingSchedule
        case .setClimateTimer, .deleteClimateTimer: return .climateTimers
        case .scheduleOTA, .installOTANow, .cancelOTA: return .softwareInstallControl
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
        case .unlock, .unlockTrunk, .openWindows:
            return .securitySensitive
        case .installOTANow, .deleteClimateTimer:
            return .destructive
        default:
            return .routine
        }
    }

    var identifier: String {
        switch self {
        case .startClimate: return "start-climate"
        case .stopClimate: return "stop-climate"
        case .startPreCleaning: return "start-precleaning"
        case .stopPreCleaning: return "stop-precleaning"
        case .lock: return "lock"
        case .unlock: return "unlock"
        case .unlockTrunk: return "unlock-trunk"
        case .openWindows: return "open-windows"
        case .closeWindows: return "close-windows"
        case .flashLights: return "flash-lights"
        case .honkAndFlash: return "honk-flash"
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
        }
    }

    var title: String {
        switch self {
        case .startClimate(let temperature, _, _, _, _, _):
            if temperature > 0 {
                return temperature.truncatingRemainder(dividingBy: 1) == 0
                    ? L10n.format("Start climate at %.0f °C", temperature)
                    : L10n.format("Start climate at %.1f °C", temperature)
            }
            return L10n.text("Start climate (automatic)")
        case .stopClimate: return L10n.text("Stop climate")
        case .startPreCleaning: return L10n.text("Start cabin cleaning")
        case .stopPreCleaning: return L10n.text("Stop cabin cleaning")
        case .lock: return L10n.text("Lock vehicle")
        case .unlock: return L10n.text("Unlock vehicle")
        case .unlockTrunk: return L10n.text("Unlock trunk")
        case .openWindows: return L10n.text("Open all windows")
        case .closeWindows: return L10n.text("Close all windows")
        case .flashLights: return L10n.text("Flash lights")
        case .honkAndFlash: return L10n.text("Honk and flash")
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
        }
    }
}

enum RemoteCommandOutcome: String, Codable, Sendable {
    case accepted
    case delivered
    case completed
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


