import Foundation

/// The one authority for "which adapter backs this brand", and for the facts about that adapter a
/// caller cannot ask `VehicleProviding` for.
///
/// The brand ternary was written four times and two callers reached the concrete adapters by
/// downcast, so a third provider would touch six-plus sites — undercutting ADR-0003's promise that
/// adding one means implementing `VehicleProviding` once. `GarageScanner`'s
/// `(VehicleBrand) -> any VehicleProviding` closure was already the right shape; this is that shape
/// with a name, built once in the composition root and threaded down.
@MainActor
final class ProviderRegistry {
    private let polestar: any VehicleProviding
    private let polestarDataPortal: (any VehicleProviding)?
    private let polestarAugmented: (any VehicleProviding)?
    /// Developer Portal mode with the Polestar ID session as its fallback. `.dataPortal` used to
    /// get the bare portal adapter, so a revoked grant or a spent quota silenced the whole app.
    private let polestarPortalFallback: (any VehicleProviding)?
    private let volvo: any VehicleProviding
    private let preferences: PreferencesStore

    init(
        polestar: any VehicleProviding,
        polestarDataPortal: (any VehicleProviding)? = nil,
        volvo: any VehicleProviding,
        preferences: PreferencesStore = .shared
    ) {
        self.polestar = polestar
        self.polestarDataPortal = polestarDataPortal
        if let polestarDataPortal {
            self.polestarAugmented = PolestarAugmentedProvider(
                telemetryProvider: polestarDataPortal,
                commandProvider: polestar
            )
            self.polestarPortalFallback = PortalFallbackProvider(
                portal: polestarDataPortal,
                consumer: polestar
            )
        } else {
            self.polestarAugmented = nil
            self.polestarPortalFallback = nil
        }
        self.volvo = volvo
        self.preferences = preferences
    }

    func provider(for brand: VehicleBrand) -> any VehicleProviding {
        switch brand {
        case .polestar:
            switch preferences.polestarConnectionMode {
            case .dataPortal:
                if let polestarPortalFallback { return polestarPortalFallback }
                if let polestarDataPortal { return polestarDataPortal }
            case .augmented:
                if let polestarAugmented { return polestarAugmented }
            case .polestarID:
                break
            }
            return polestar
        case .volvo:
            return volvo
        }
    }

    /// The live-streaming view of a brand's adapter, or nil when that adapter has no live stream.
    /// The conformance test lives here so no caller writes `as? any VehicleLiveStreaming`, and so a
    /// second streaming provider is one registration rather than a search across the app.
    func streaming(for brand: VehicleBrand) -> (any VehicleLiveStreaming)? {
        let active = provider(for: brand)
        return active as? any VehicleLiveStreaming
    }
}
