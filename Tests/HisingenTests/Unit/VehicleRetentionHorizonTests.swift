import Foundation
import Testing
@testable import Hisingen

/// A provider that can never serve a domain again (the Developer Portal has no software or
/// connectivity endpoints) must not hold ageing readings up as last-known forever: carried
/// values and retained marks expire at `VehicleState.retainedDataHorizon`, which is what let
/// the "Showing last-known values" banner pin permanently after a consumer-to-portal switch.
@Suite("VehicleRetentionHorizon")
struct VehicleRetentionHorizonTests {
    private let vin = "YSMVSEDE6PL147228"

    /// Consumer-era snapshot: software and connectivity were read an hour ago (or older).
    private func consumerState(readingAge: TimeInterval) -> VehicleState {
        let readingDate = Date().addingTimeInterval(-readingAge)
        var state = VehicleState(
            batteryPercentage: 60, rangeKm: 200, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "Polestar 2", modelYear: "2024", registrationNo: nil,
            vin: vin, ownerFirstName: nil, odometerKm: 12000,
            softwareInfo: VehicleSoftwareInfo(installedVersion: "P2.66"),
            connectivity: VehicleConnectivity(state: .connected),
            imageData: nil, fetchedAt: readingDate, vehicleReportedAt: readingDate,
            dataWarnings: []
        )
        state.freshness.readingDates[.software] = readingDate
        state.freshness.readingDates[.connectivity] = readingDate
        return state
    }

    /// A pure-portal refresh: the telemetry bundle carries no software or connectivity at all.
    private func portalFetch(at fetchedAt: Date) -> VehicleState {
        VehicleState(
            batteryPercentage: 61, rangeKm: 201, chargingState: .idle,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: 80,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .disconnected, availability: .available,
            modelName: "Polestar 2", modelYear: "2024", registrationNo: nil,
            vin: vin, ownerFirstName: nil, odometerKm: 12001,
            imageData: nil, fetchedAt: fetchedAt, vehicleReportedAt: fetchedAt,
            dataWarnings: []
        )
    }

    private func mergePortal(_ previous: VehicleState, at fetchedAt: Date = Date()) -> VehicleState {
        portalFetch(at: fetchedAt).mergingLastKnown(
            from: previous,
            features: FeatureSelection(enabled: [.softwareUpdates, .connectivityDiagnostics, .vehicleHealth]))
    }

    /// A refresh that does not cover the software domain, so the snapshot-level `keep`
    /// carry engages for it — the situation a provider that stopped serving software
    /// produces on every targeted cycle.
    private func mergeTargeted(_ previous: VehicleState) -> VehicleState {
        portalFetch(at: Date()).mergingLastKnown(
            from: previous,
            features: FeatureSelection(enabled: [.softwareUpdates, .vehicleHealth]),
            refreshedFeatures: [.vehicleHealth])
    }

    @Test func agedSoftwareAndConnectivityDropInsteadOfPinningTheBanner() {
        let aged = consumerState(readingAge: VehicleState.retainedDataHorizon + 2 * 24 * 3600)
        let merged = mergePortal(aged)
        #expect(merged.connectivity == nil)
        #expect(merged.freshness.retainedDataCategories.isEmpty)
        #expect(merged.freshness.retainedDataAt == nil)
    }

    @Test func recentReadingsStillCarryAndMarkAsBefore() {
        let recent = consumerState(readingAge: 3600)
        let merged = mergePortal(recent)
        // A full refresh that returns no software drops the carried value after one cycle
        // (keep() requires the refresh not to have covered the domain); connectivity is the
        // domain that carried and re-marked every cycle, which is what pinned the banner.
        #expect(merged.softwareInfo == nil)
        #expect(merged.connectivity != nil)
        #expect(merged.freshness.retainedDataCategories.contains(.connectivityDiagnostics))
        #expect(merged.freshness.retainedDataAt != nil)
    }

    @Test func softwareCarryRespectsTheHorizonOnTargetedRefreshes() {
        #expect(mergeTargeted(consumerState(readingAge: 3600)).softwareInfo?.installedVersion == "P2.66")
        #expect(mergeTargeted(consumerState(
            readingAge: VehicleState.retainedDataHorizon + 2 * 24 * 3600)).softwareInfo == nil)
    }

    @Test func fallbackMarkerSurvivesTheMergeAndLabelsTheAgeLine() {
        var fresh = portalFetch(at: Date())
        fresh.freshness.servedByFallback = true
        let merged = fresh.mergingLastKnown(
            from: consumerState(readingAge: 3600),
            features: FeatureSelection(enabled: [.softwareUpdates, .connectivityDiagnostics]))
        #expect(merged.freshness.servedByFallback == true)
        #expect(merged.freshnessDescription.contains("Polestar ID"))
    }
}
