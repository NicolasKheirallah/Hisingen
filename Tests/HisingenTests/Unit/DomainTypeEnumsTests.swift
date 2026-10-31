import Foundation
import Testing
@testable import Hisingen

/// Typed accessors over the raw wire strings and codes the domain types keep. The raw fields
/// stay as they were; these pin how each token and code maps onto its enum and onto the
/// behaviour that reads it.
struct DomainTypeEnumsTests {

    // MARK: Ventilation

    @Test
    func ventilationTokensMapToModes() {
        #expect(ClimateVentilation(wireToken: "VENTILATION_COOLING") == .cooling)
        #expect(ClimateVentilation(wireToken: "VENTILATION_HEATING") == .heating)
        #expect(ClimateVentilation(wireToken: "VENTILATION_NEUTRAL") == .neutral)
        #expect(ClimateVentilation(wireToken: "VENTILATION_UNSPECIFIED") == .unspecified)
        #expect(ClimateVentilation(wireToken: "VENTILATION_SOMETHING_NEW") == nil)
        #expect(ClimateVentilation(wireToken: nil) == nil)
    }

    @Test
    func ventilationNameUsesTheModeAndCleansUpUnknownTokens() {
        #expect(climate(ventilation: "VENTILATION_COOLING").ventilationName == "Cooling")
        #expect(climate(ventilation: "VENTILATION_UNSPECIFIED").ventilationName == nil)
        #expect(climate(ventilation: "").ventilationName == nil)
        #expect(climate(ventilation: nil).ventilationName == nil)
        #expect(climate(ventilation: "VENTILATION_DEFROST_BOOST").ventilationName == "Defrost Boost")
        #expect(climate(ventilation: "VENTILATION_HEATING").ventilationMode == .heating)
    }

    // MARK: Schedule sync status

    @Test
    func syncTokensMapToStatus() {
        #expect(ScheduleSyncStatus(wireToken: "SYNCED") == .synced)
        #expect(ScheduleSyncStatus(wireToken: "PENDING") == .pending)
        #expect(ScheduleSyncStatus(wireToken: "UNSPECIFIED") == .unspecified)
        #expect(ScheduleSyncStatus(wireToken: "SYNC_STATUS_UNSPECIFIED") == .unspecified)
        #expect(ScheduleSyncStatus(wireToken: "FAILED") == nil)
        #expect(ScheduleSyncStatus(wireToken: nil) == nil)
    }

    @Test
    func onlyPendingSyncNeedsAttentionAmongKnownTokens() {
        #expect(ScheduleSyncStatus.pending.needsAttention)
        #expect(!ScheduleSyncStatus.synced.needsAttention)
        #expect(!ScheduleSyncStatus.unspecified.needsAttention)
    }

    @Test
    func syncNeedsAttentionFollowsTheTokenNotTheSchedule() {
        #expect(schedule(syncStatus: "PENDING").syncNeedsAttention)
        #expect(!schedule(syncStatus: "SYNCED").syncNeedsAttention)
        #expect(!schedule(syncStatus: "UNSPECIFIED").syncNeedsAttention)
        #expect(!schedule(syncStatus: "").syncNeedsAttention)
        #expect(!schedule(syncStatus: nil).syncNeedsAttention)
        // A token the app does not recognise still surfaces.
        #expect(schedule(syncStatus: "FAILED").syncNeedsAttention)
    }

    // MARK: Charge setting source

    @Test
    func chargeSourceTokensMapToSources() {
        #expect(ChargeSettingSource(wireToken: "RCS") == .remote)
        #expect(ChargeSettingSource(wireToken: "rcs") == .remote)
        #expect(ChargeSettingSource(wireToken: "APP") == .app)
        #expect(ChargeSettingSource(wireToken: "CAR") == nil)
        #expect(ChargeSettingSource(wireToken: nil) == nil)
    }

    // MARK: Optimised charging mode and location kind

    @Test
    func optimisedChargingCodesMapToModes() {
        #expect(OptimisedChargingMode(rawValue: 0) == .unavailable)
        #expect(OptimisedChargingMode(rawValue: 1) == .intelligentTimer)
        #expect(OptimisedChargingMode(rawValue: 2) == .priceOptimised)
        #expect(OptimisedChargingMode(rawValue: 3) == nil)
        #expect(OptimisedChargingMode.unavailable.displayName == nil)
        #expect(OptimisedChargingMode.intelligentTimer.displayName == "Intelligent timer")
        #expect(OptimisedChargingMode.priceOptimised.displayName == "Price-optimised")
    }

    @Test
    func locationKindCodesMapToKinds() {
        #expect(ChargeLocationKind(rawValue: 1) == .recent)
        #expect(ChargeLocationKind(rawValue: 2) == .saved)
        #expect(ChargeLocationKind(rawValue: 3) == .savedThirdParty)
        #expect(ChargeLocationKind(rawValue: 0) == nil)
        #expect(!ChargeLocationKind.recent.isSaved)
        #expect(ChargeLocationKind.saved.isSaved)
        #expect(ChargeLocationKind.savedThirdParty.isSaved)
    }

    @Test
    func isSavedLocationIsTrueOnlyForSavedKinds() {
        #expect(!location(kind: 0).isSavedLocation)
        #expect(!location(kind: 1).isSavedLocation)
        #expect(location(kind: 2).isSavedLocation)
        #expect(location(kind: 3).isSavedLocation)
        #expect(!location(kind: 9).isSavedLocation)
    }

    @Test
    func optimisedChargingModeNameReadsTheTypedMode() {
        #expect(location(mode: 0).optimisedChargingModeName == nil)
        #expect(location(mode: 1).optimisedChargingModeName == "Intelligent timer")
        #expect(location(mode: 2).optimisedChargingModeName == "Price-optimised")
        #expect(location(mode: 7).optimisedChargingKind == nil)
    }

    // MARK: Fixtures

    private func climate(ventilation: String?) -> VehicleClimateStatus {
        VehicleClimateStatus(activity: .active, timeRemainingMinutes: nil, timerTriggered: false, ventilation: ventilation)
    }

    private func schedule(syncStatus: String?) -> VehicleSchedule {
        VehicleSchedule(kind: .departure, startHour: nil, startMinute: nil, endHour: nil, endMinute: nil,
                        isActive: true, syncStatus: syncStatus)
    }

    private func location(kind: Int = 2, mode: Int = 0) -> ChargeLocationSnapshot {
        ChargeLocationSnapshot(
            id: "loc", alias: "Home", latitude: nil, longitude: nil, ampLimit: 16, minimumSoc: 0,
            optimisedChargingEnabled: false, optimisedChargingMode: mode, kind: kind
        )
    }
}
