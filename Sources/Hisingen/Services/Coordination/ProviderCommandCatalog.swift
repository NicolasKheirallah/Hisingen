import Foundation

struct ProviderCommandCatalog: Sendable {
    let brand: VehicleBrand

    func implements(_ command: RemoteCommand) -> Bool {
        switch brand {
        case .polestar:
            switch command {
            case .startEngine, .stopEngine, .lockReducedGuard:
                return false
            default:
                return true
            }
        case .volvo:
            switch command {
            case .lock, .lockReducedGuard, .unlock, .startClimate, .stopClimate,
                 .honkAndFlash, .flashLights, .honkHorn, .startEngine, .stopEngine:
                return true
            default:
                return false
            }
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
