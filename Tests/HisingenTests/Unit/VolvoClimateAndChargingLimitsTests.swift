import Foundation
import Testing
@testable import Hisingen

/// Two behaviours that only show up on a provider with a thinner API than Polestar's:
/// climate activity when the car reports no climate status, and charging settings when the
/// vehicle service can read a value but has no write for it.
struct VolvoClimateAndChargingLimitsTests {

    private func stateWithReceipts(_ receipts: [CommandReceipt]) -> VehicleState {
        var state = vehicle(brand: .volvo, climateStatus: nil)
        state.commandState.receipts = receipts
        return state
    }

    private func receipt(_ identifier: String, minutesAgo: Double,
                         status: CommandConfirmationStatus) -> CommandReceipt {
        CommandReceipt(
            commandIdentifier: identifier,
            issuedAt: Date().addingTimeInterval(-minutesAgo * 60),
            status: status
        )
    }

    @Test("No climate status and no receipt is not an active climate")
    func nothingKnownIsNotActive() {
        #expect(stateWithReceipts([]).isClimateActive == false)
    }

    /// The reason this exists: Volvo reports no climate status, so before the receipt fallback the
    /// app offered Start Climate forever and could never send Stop.
    @Test("A recent acknowledged start reads as running")
    func acknowledgedStartIsActive() {
        let state = stateWithReceipts([
            receipt("start-climate", minutesAgo: 2, status: .acknowledged(at: Date()))
        ])
        #expect(state.isClimateActive)
        #expect(state.receiptClimateIsRunning)
    }

    @Test("A later stop ends it")
    func laterStopWins() {
        let state = stateWithReceipts([
            receipt("stop-climate", minutesAgo: 1, status: .acknowledged(at: Date())),
            receipt("start-climate", minutesAgo: 5, status: .acknowledged(at: Date()))
        ])
        #expect(state.isClimateActive == false)
    }

    @Test("A timed-out start is not running")
    func timedOutStartIsNotActive() {
        let state = stateWithReceipts([
            receipt("start-climate", minutesAgo: 2, status: .timedOut(at: Date()))
        ])
        #expect(state.isClimateActive == false)
    }

    @Test("A start past the session window falls back to not running")
    func expiredWindowIsNotActive() {
        let past = VehicleState.unobservableClimateSessionLimit / 60 + 1
        let state = stateWithReceipts([
            receipt("start-climate", minutesAgo: past, status: .acknowledged(at: Date()))
        ])
        #expect(state.isClimateActive == false)
    }

    /// Volvo's public API has no write for either setting, so the card must not offer a control.
    @Test("Volvo cannot change the charge target or the current limit")
    func volvoHasNoChargingWrite() {
        let catalog = ProviderCommandCatalog(brand: .volvo)
        #expect(catalog.implements(.setChargeTarget(80)) == false)
        #expect(catalog.implements(.setAmpLimit(16)) == false)
        // The reads it does implement stay available.
        #expect(catalog.implements(.stopClimate))
        #expect(catalog.implements(.lock))
    }

    @Test("Polestar keeps its charging writes")
    func polestarKeepsChargingWrites() {
        let catalog = ProviderCommandCatalog(brand: .polestar)
        #expect(catalog.implements(.setChargeTarget(80)))
        #expect(catalog.implements(.setAmpLimit(16)))
    }
}
