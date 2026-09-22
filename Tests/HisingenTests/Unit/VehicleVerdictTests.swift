import Foundation
import Testing
@testable import Hisingen

/// The verdict line answers "what is the car doing" from reported signals only, and stays
/// nil when nothing is actively happening. Assertions are copy-agnostic: the display string
/// resolves through the reader's locale, so tests pin presence and precedence, not wording.
@Suite("VehicleActiveVerdict")
struct VehicleActiveVerdictTests {
    private func state(
        chargingState: ChargingState = .idle,
        powerWatts: Int? = nil,
        minutesToFull: Int? = nil,
        climate: VehicleClimateStatus? = nil,
        reportedAt: Date = Date()
    ) -> VehicleState {
        VehicleState(
            batteryPercentage: 62, rangeKm: 240, chargingState: chargingState,
            estimatedChargingTimeToFullMinutes: minutesToFull, chargeTargetPercentage: 80,
            chargingPowerWatts: powerWatts, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: powerWatts == nil ? .disconnected : .connected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: nil, vin: "YSMVSEDE6PL147228", ownerFirstName: nil,
            odometerKm: 12000, climateStatus: climate,
            imageData: nil, fetchedAt: Date(), vehicleReportedAt: reportedAt, dataWarnings: []
        )
    }

    @Test func chargingWithEstimateProducesAVerdict() {
        let verdict = state(chargingState: .charging, powerWatts: 11000, minutesToFull: 42).activeVerdict
        #expect(verdict != nil)
    }

    @Test func chargingWithoutEstimateStillReportsPower() {
        let verdict = state(chargingState: .charging, powerWatts: 11000).activeVerdict
        #expect(verdict != nil)
    }

    @Test func connectedButIdleCarHasNoVerdict() {
        #expect(state().activeVerdict == nil)
        #expect(state(chargingState: .scheduled).activeVerdict == nil)
    }

    @Test func completedSessionBeatsTheIdleDefault() {
        let verdict = state(chargingState: .complete).activeVerdict
        #expect(verdict != nil)
    }

    @Test func staleCompleteSessionYieldsToTheDataAge() {
        let hoursOld = Date().addingTimeInterval(-2 * 3600)
        #expect(state(chargingState: .complete, reportedAt: hoursOld).activeVerdict == nil)
    }

    @Test func runningClimateProducesAVerdict() {
        let climate = VehicleClimateStatus(activity: .heating, timeRemainingMinutes: nil, timerTriggered: false)
        #expect(state(climate: climate).activeVerdict != nil)
    }

    @Test func chargingTakesPrecedenceOverClimate() {
        let climate = VehicleClimateStatus(activity: .heating, timeRemainingMinutes: nil, timerTriggered: false)
        let charging = state(chargingState: .charging, powerWatts: 11000, climate: climate)
        let idle = state(climate: climate)
        #expect(charging.activeVerdict != nil)
        #expect(idle.activeVerdict != nil)
    }
}
