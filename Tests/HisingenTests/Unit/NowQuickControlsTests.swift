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
        #expect(result == [.locks, .climate, .charging, .chargeLimit, .currentLimit])
    }

    @Test func limitCardsNeedTheCarToReportTheMatchingCapability() {
        let result = NowQuickControl.applicable(
            [.chargeLimit, .currentLimit], features: everyFeature, hasElectricRange: true,
            profile: profile([.chargeTarget: false, .chargingCurrentLimit: true]), supportsTrunkControl: false
        )
        #expect(result == [.currentLimit])
    }

    @Test func limitCardsNeedRemoteChargingAndAnElectricRange() {
        let withoutFeature = NowQuickControl.applicable(
            [.chargeLimit, .currentLimit], features: [.remoteLocks], hasElectricRange: true,
            profile: profile(), supportsTrunkControl: false
        )
        let withoutRange = NowQuickControl.applicable(
            [.chargeLimit, .currentLimit], features: everyFeature, hasElectricRange: false,
            profile: profile(), supportsTrunkControl: false
        )
        #expect(withoutFeature.isEmpty)
        #expect(withoutRange.isEmpty)
    }

    @Test func limitCardsSitBesideChargingInTheFixedOrder() {
        let order = NowQuickControl.allCases
        #expect(order.starts(with: [.locks, .climate, .charging, .chargeLimit, .currentLimit]))
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
