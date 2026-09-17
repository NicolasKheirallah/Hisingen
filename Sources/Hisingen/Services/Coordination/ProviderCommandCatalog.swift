import Foundation

struct ProviderCommandCatalog: Sendable {
    let brand: VehicleBrand
    let polestarConnectionMode: PolestarConnectionMode

    init(
        brand: VehicleBrand,
        polestarConnectionMode: PolestarConnectionMode = PreferencesStore.currentPolestarConnectionMode
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
        guard polestarConnectionMode != .dataPortal else { return false }
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
