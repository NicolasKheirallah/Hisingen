import Foundation
import Testing
@testable import Hisingen

/// The catalog is the agreement between what the UI promises (a capability the car advertises)
/// and what dispatch posts (one endpoint). Drift between them used to be silent.
struct VolvoCommandCatalogTests {
    @Test
    func everyVolvoCommandResolvesToAnEndpoint() {
        let supported: [RemoteCommand] = [
            .lock, .unlock, .lockReducedGuard, .startClimate(temperatureCelsius: 21,
                frontLeftSeat: .off, frontRightSeat: .off, rearLeftSeat: .off,
                rearRightSeat: .off, steeringWheel: .off),
            .stopClimate, .startEngine(runtimeMinutes: 15), .stopEngine,
            .honkAndFlash, .flashLights, .honkHorn,
        ]
        for command in supported {
            #expect(VolvoCommandCatalog.endpoint(for: command) != nil, "\(command)")
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
