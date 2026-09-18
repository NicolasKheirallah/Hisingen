import Foundation

struct ProviderCommandCatalog: Sendable {
    let brand: VehicleBrand
    let polestarConnectionMode: PolestarConnectionMode

    init(
        brand: VehicleBrand,
        // Fixed default rather than the live preference: parallel test suites constructing a
        // bare catalog must never inherit a `.dataPortal` mode set by another test thread.
        polestarConnectionMode: PolestarConnectionMode = .polestarID
    ) {
        self.brand = brand
        self.polestarConnectionMode = polestarConnectionMode
    }

    func implements(_ command: RemoteCommand) -> Bool {
        switch brand {
        case .polestar:
            return implementsPolestar(command)
        case .volvo:
            return implementsVolvo(command)
        }
    }

    private func implementsPolestar(_ command: RemoteCommand) -> Bool {
        if polestarConnectionMode == .dataPortal {
            switch command {
            case .startClimate, .stopClimate, .startPreCleaning, .stopPreCleaning,
                 .setChargeTarget, .setAmpLimit, .startChargingOverride, .stopChargingOverride,
                 .setGlobalChargeTimer, .setClimateTimer, .deleteClimateTimer,
                 .createChargeLocationAtCar, .updateChargeLocationAlias, .updateChargeLocationAmpLimit,
                 .updateChargeLocationMinimumSoc, .setChargeLocationOptimisedCharging, .deleteChargeLocation:
                return true
            default:
                return false
            }
        }
        switch command {
        case .startEngine, .stopEngine, .lockReducedGuard:
            return false
        default:
            return true
        }
    }

    private func implementsVolvo(_ command: RemoteCommand) -> Bool {
        switch command {
        case .lock, .lockReducedGuard, .unlock, .startClimate, .stopClimate,
             .honkAndFlash, .flashLights, .honkHorn, .startEngine, .stopEngine:
            return true
        default:
            return false
        }
    }
}


protocol RemoteCommandExecuting: Sendable {
    var brand: VehicleBrand { get }
    func executeRemoteCommand(_ command: RemoteCommand, vin: String) async throws -> RemoteCommandResult
}

extension RemoteCommandExecuting {
    var commandCatalog: ProviderCommandCatalog { ProviderCommandCatalog(brand: brand) }
}

extension RemoteCommand {
    func isImplemented(by brand: VehicleBrand) -> Bool {
        ProviderCommandCatalog(brand: brand).implements(self)
    }
}
