import Foundation
import Testing
@testable import Hisingen

struct PolestarConsumerAssemblyTests {
    private func assemble(primaryTime: Int, secondaryTime: Int) throws -> VehicleState {
        let battery = try JSONDecoder().decode(BatteryDTO.self, from: Data("""
        {"vin":"VIN-A","batteryChargeLevelPercentage":50,"estimatedDistanceToEmptyKm":200,"timestamp":{"seconds":"\(primaryTime)"}}
        """.utf8))
        let extras = try PolestarGRPC.parseBattery(
            Protobuf.messageField(1, Protobuf.intField(1, secondaryTime))
                + Protobuf.doubleField(2, 80)
                + Protobuf.intField(4, 350)
        )
        return PolestarConsumerSnapshotAssembler(
            features: .init(enabled: [.chargingDetails]), vin: "VIN-A", carIdentity: .empty,
            ownerFirstName: nil, market: nil, imageData: nil,
            fetchedAt: Date(timeIntervalSince1970: 2_000),
            graphQLStartedAt: Date(timeIntervalSince1970: 1_000),
            servicesStartedAt: Date(timeIntervalSince1970: 1_100),
            targetObservation: nil, hasGraphQLErrors: false,
            battery: battery, odometer: nil, health: nil, extras: extras,
            availabilityReport: .init(availability: .unknown, reportedAt: nil, unknownFields: []),
            chargeTarget: nil, exterior: .unknown, c3Health: .unknown, software: .unknown,
            schedules: .unknown, climate: .unknown, climateTimers: .unknown, trips: .unknown,
            connectivity: .unknown, air: .unknown, weather: .unknown, location: .unknown,
            ampLimit: .unknown, chargeLocations: .unknown, otaCapabilities: .unknown
        ).assemble()
    }

    @Test func newerSecondaryValuesCarrySecondaryProvenance() throws {
        let state = try assemble(primaryTime: 500, secondaryTime: 600)
        #expect(state.energy.batteryPercentage == 80)
        #expect(state.freshness.readingDates[.battery] == Date(timeIntervalSince1970: 600))
        #expect(state.freshness.readingObservations?[.battery]?.source == .polestarGRPC)
        #expect(state.freshness.readingObservations?[.battery]?.fetchedAt == Date(timeIntervalSince1970: 1_100))
    }

    @Test func newerPrimaryValuesCarryPrimaryProvenance() throws {
        let state = try assemble(primaryTime: 600, secondaryTime: 500)
        #expect(state.energy.batteryPercentage == 50)
        #expect(state.freshness.readingDates[.battery] == Date(timeIntervalSince1970: 600))
        #expect(state.freshness.readingObservations?[.battery]?.source == .polestarGraphQL)
        #expect(state.freshness.commandObservations?.isEmpty == true)
    }
}
