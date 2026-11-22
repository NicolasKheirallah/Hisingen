import Foundation
import Testing
@testable import Hisingen

/// The catalog is the agreement between what the UI promises (a capability the car advertises)
/// and what dispatch posts (one endpoint). Drift between them used to be silent.
struct VolvoCommandCatalogTests {
    /// The commands Volvo's public v2 surface can run, with the arguments the app sends.
    private static let supportedCommands: [RemoteCommand] = [
        .lock, .unlock, .lockReducedGuard, .startClimate(temperatureCelsius: 21,
            frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off,
            rearRightSeat: .off, steeringWheel: .off),
        .stopClimate, .startEngine(runtimeMinutes: 15), .stopEngine,
        .honkAndFlash, .flashLights, .honkHorn,
    ]

    @Test
    func everyVolvoCommandResolvesToAnEndpoint() {
        for command in Self.supportedCommands {
            #expect(VolvoCommandCatalog.endpoint(for: command) != nil, "\(command)")
        }
    }

    @Test
    func theProbeAndDispatchReadOneCatalog() {
        // The name the car's list has to report for a control is the endpoint dispatch posts to,
        // so a list the probe accepts is a command the app can actually send.
        for kind in VolvoCommandCatalog.Kind.allCases {
            let entry = VolvoCommandCatalog.entry(for: kind)
            #expect(entry.advertisedNames.contains(entry.endpoint), "\(kind)")
            #expect(VolvoCommandCatalog.isAdvertised(kind, in: [entry.endpoint]), "\(kind)")
        }
        // And the provider catalog that dispatch and the availability gate ask is the same table,
        // not a second hand-written list that could drift from it.
        for command in Self.supportedCommands {
            guard let kind = VolvoCommandCatalog.kind(for: command),
                  let endpoint = VolvoCommandCatalog.endpoint(for: command) else {
                Issue.record("\(command) has no catalog entry")
                continue
            }
            #expect(VolvoCommandCatalog.isAdvertised(kind, in: [endpoint]), "\(command)")
            #expect(ProviderCommandCatalog(brand: .volvo).implements(command), "\(command)")
        }
    }

    @Test
    func commandsVolvoCannotRunHaveNoEndpoint() {
        // Charging writes and body controls are not in Volvo's public v2 command surface, so the
        // app must not invent a path for them.
        for command: RemoteCommand in [.openTailgate, .closeTailgate, .openWindows, .closeWindows,
                                       .setChargeTarget(80), .startChargingOverride, .installOTANow] {
            #expect(VolvoCommandCatalog.endpoint(for: command) == nil, "\(command)")
        }
    }

    @Test
    func anAdvertisedNameEnablesItsCapability() {
        let names: Set<String> = ["HONK_AND_FLASH", "honk-flash", "lock", "engine-start"]
        #expect(VolvoCommandCatalog.isAdvertised(.honkAndFlash, in: names))
        #expect(VolvoCommandCatalog.isAdvertised(.lock, in: names))
        #expect(VolvoCommandCatalog.isAdvertised(.engineStart, in: names))
        // Advertised names are normalized to the href tail, so a display spelling alone is not
        // enough unless the catalog lists it.
        #expect(!VolvoCommandCatalog.isAdvertised(.climateStart, in: names))
        #expect(!VolvoCommandCatalog.isAdvertised(.unlock, in: names))
    }

    @Test
    func everyKindKeepsABothSpellingForHonkAndFlash() {
        // The live list reports HONK_AND_FLASH with an href ending /honk-flash; older payloads
        // spell the name out. Losing either would hide the control on some cars.
        let entry = VolvoCommandCatalog.entry(for: .honkAndFlash)
        #expect(entry.advertisedNames.contains("honk-flash"))
        #expect(entry.advertisedNames.contains("honk-and-flash"))
    }

    @Test
    func allKindsHaveDistinctEndpoints() {
        let endpoints = VolvoCommandCatalog.Kind.allCases.map { VolvoCommandCatalog.entry(for: $0).endpoint }
        #expect(Set(endpoints).count == endpoints.count)
    }
}
