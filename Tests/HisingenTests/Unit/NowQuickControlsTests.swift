import Testing
@testable import Hisingen

struct NowQuickControlsTests {
    private func profile(_ advertised: [VehicleCapability: Bool] = [:]) -> VehicleCapabilityProfile {
        VehicleCapabilityProfile(modelName: "Polestar 2", vin: nil, advertised: advertised)
    }

    private let everyFeature: Set<AppFeature> = [
        .remoteLocks, .remoteClimate, .remoteCharging, .remotePreCleaning, .remoteWindows, .remoteHonkFlash
    ]

    @Test func remoteFeaturesOffStillShowTheCarState() {
        let result = NowQuickControl.applicable(
            NowQuickControl.allCases, features: [], hasElectricRange: true,
            profile: profile(), supportsTrunkControl: true
        )
        #expect(result == [.locks, .climate, .charging])
    }

    @Test func chargingStateNeedsElectricRangeWhenRemoteFeaturesAreOff() {
        let result = NowQuickControl.applicable(
            NowQuickControl.allCases, features: [], hasElectricRange: false,
            profile: profile(), supportsTrunkControl: true
        )
        #expect(result == [.locks, .climate])
    }

    @Test func aCommandDrawsOnlyWhenItsOwnFeatureIsOn() {
        let result = NowQuickControl.applicable(
            NowQuickControl.allCases, features: [.remoteWindows], hasElectricRange: true,
            profile: profile([.windows: true]), supportsTrunkControl: true
        )
        #expect(result == [.locks, .climate, .charging, .windows])
    }

    @Test func commandsTheCarDoesNotReportAreDropped() {
        let result = NowQuickControl.applicable(
            NowQuickControl.allCases, features: everyFeature, hasElectricRange: true,
            profile: profile([.preCleaning: false, .windows: false, .honkAndFlash: false]),
            supportsTrunkControl: false
        )
        #expect(result == [.locks, .climate, .charging])
    }

    @Test func theReadersOrderIsKept() {
        let result = NowQuickControl.applicable(
            [.tailgate, .locks, .windows], features: everyFeature, hasElectricRange: true,
            profile: profile([.windows: true]), supportsTrunkControl: true
        )
        #expect(result == [.tailgate, .locks, .windows])
    }

    @Test func anEmptySelectionDrawsNothing() {
        let result = NowQuickControl.applicable(
            [], features: everyFeature, hasElectricRange: true,
            profile: profile([.windows: true]), supportsTrunkControl: true
        )
        #expect(result.isEmpty)
    }
}
