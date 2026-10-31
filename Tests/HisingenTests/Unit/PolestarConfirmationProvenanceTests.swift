import Foundation
import Testing
@testable import Hisingen

struct PolestarConfirmationProvenanceTests {
    private let issued = Date(timeIntervalSince1970: 1_800_000_000)

    private func state() -> VehicleState {
        VehicleState(
            energy: .init(targetPercentage: 80, currentLimitAmps: 16),
            identity: .init(availability: .unknown, vin: "VIN-A"),
            freshness: .init(fetchedAt: issued.addingTimeInterval(10), readingObservations: [:], commandObservations: [:])
        )
    }

    private func receipt(_ command: RemoteCommand) -> CommandReceipt {
        .init(commandIdentifier: command.identifier, issuedAt: issued, command: command, providerBrand: .polestar)
    }

    @Test func unrelatedFreshChargingEndpointCannotConfirmTarget() {
        var value = state()
        value.freshness.readingObservations?[.charging] = .init(fetchedAt: issued.addingTimeInterval(1), source: .polestarPortal)
        value.freshness.commandObservations?[.chargingCurrentLimit] = .init(fetchedAt: issued.addingTimeInterval(1), source: .polestarPortal)
        #expect(receipt(.setChargeTarget(80)).updatingConfirmation(from: value, now: value.freshness.fetchedAt).status.isAwaiting)
    }

    @Test func exactPostCommandObservationConfirmsWithoutOtherEndpoints() {
        var value = state()
        value.freshness.commandObservations?[.chargeTarget] = .init(fetchedAt: issued.addingTimeInterval(1), source: .polestarPortal)
        #expect(receipt(.setChargeTarget(80)).updatingConfirmation(from: value, now: value.freshness.fetchedAt).status.isConfirmed)
        #expect(receipt(.setAmpLimit(16)).updatingConfirmation(from: value, now: value.freshness.fetchedAt).status.isAwaiting)
    }

    @Test func cachedOrPreCommandObservationsCannotConfirm() {
        for observation in [
            VehicleReadingObservation(fetchedAt: issued.addingTimeInterval(-1), source: .polestarGRPC),
            VehicleReadingObservation(fetchedAt: issued.addingTimeInterval(1), source: .polestarGRPC, isCached: true)
        ] {
            var value = state()
            value.freshness.commandObservations?[.chargeTarget] = observation
            #expect(receipt(.setChargeTarget(80)).updatingConfirmation(from: value, now: value.freshness.fetchedAt).status.isAwaiting)
        }
    }

    @Test func mergePreservesStrictMissingEvidenceInsteadOfLegacyFallback() {
        var previous = state()
        previous.freshness.commandObservations?[.chargeTarget] = .init(fetchedAt: issued.addingTimeInterval(1), source: .polestarGRPC)
        let fresh = state().freshness.merging(previous: previous.freshness, unavailableFeatures: [])
        #expect(fresh.commandObservations?.isEmpty == true)
        #expect(fresh.readingObservations?.isEmpty == true)
    }

    @Test func persistedSnapshotCannotConfirmEvenWithPostCommandEvidence() {
        var value = state()
        value.freshness.commandObservations?[.chargeTarget] = .init(fetchedAt: issued.addingTimeInterval(1), source: .polestarGRPC)
        value.freshness.isCached = true
        #expect(receipt(.setChargeTarget(80)).updatingConfirmation(from: value, now: value.freshness.fetchedAt).status.isAwaiting)
    }

    @Test func unknownDeliveryNeverOffersPhysicalActionRetry() {
        let error = PolestarError.commandOutcomeUnknown(operation: "Lock")
        #expect(!RemoteCommandFollowUp.permitsRetry(after: error))
        #expect(!VehicleServiceError.map(error, provider: .polestar).allowsAutomaticRetry)
    }
}
