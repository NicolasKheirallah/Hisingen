import Foundation
import Testing
@testable import Hisingen

@Suite("VehicleState Snapshot Codability")
struct VehicleStateCodableTests {
    /// Fully-populated state used to prove no field is silently dropped by the encoder.
    private func fullyPopulated() -> VehicleState {
        var state = VehicleState(
            batteryPercentage: 71.5, rangeKm: 302, chargingState: .charging,
            estimatedChargingTimeToFullMinutes: 42, chargeTargetPercentage: 90,
            chargingPowerWatts: 11_000, chargingCurrentAmps: 16, chargingVoltageVolts: 230,
            chargingType: .ac, chargerConnection: .connected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: "ABC 123", vin: "YSMTEST0000000001", ownerFirstName: "Test",
            odometerKm: 12_345, daysToService: 30, distanceToServiceKm: 2_000,
            serviceWarning: false, fluidWarnings: [], imageData: nil,
            fetchedAt: Date(timeIntervalSince1970: 1_750_000_000),
            vehicleReportedAt: Date(timeIntervalSince1970: 1_749_999_900),
            dataWarnings: []
        )
        state.fuelSystem = FuelSystemSnapshot(
            levelPercent: 55, rangeKm: 90, amountLiters: 12.5,
            averageConsumptionLPer100Km: 6.4, isEngineRunning: false, type: "DIESEL"
        )
        state.identity.externalColour = "Midnight"
        state.energy.currentLimitAmps = 20
        return state
    }

    @Test("Round trip through the clustered snapshot encoding preserves every field")
    func testClusteredRoundTrip() throws {
        let original = fullyPopulated()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(VehicleState.self, from: data)
        #expect(decoded == original)

        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for key in ["energy", "identity", "maintenance", "freshness", "commandState"] {
            #expect(object[key] != nil)
        }
        for key in ["batteryPercentage", "vin", "odometerKm", "fetchedAt", "pendingCommand"] {
            #expect(object[key] == nil)
        }
    }

    @Test("Service and trip-computer clusters survive a round trip")
    func testServiceAndTripClustersRoundTrip() throws {
        var state = fullyPopulated()
        state.maintenance.service = ServiceSnapshot(
            daysToService: 21, distanceToServiceKm: 1_400, serviceWarning: true,
            fluidWarnings: ["Brake fluid"], engineHoursToService: 512,
            trigger: "MILEAGE", preferredWorkshopID: "VSC-042", preferredWorkshopName: "Gothenburg")
        state.tripComputer = TripComputerSnapshot(
            manualTripKm: 120.5, automaticTripKm: 310.2, averageSpeedKmH: 62.0,
            electricRangeKm: 41, electricDistanceKm: 88.4,
            fuelDistanceKm: 210.0, regeneratedEnergyKwh: 3.7)

        let roundTripped = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(state))
        #expect(roundTripped == state)
    }

    @Test("Command receipt survives Codable round-trip but is absent when unset")
    func commandReceiptCodableRoundTrip() throws {
        var state = fullyPopulated()
        state.commandState.receipts = [
            CommandReceipt(
                commandIdentifier: "lock",
                issuedAt: Date(timeIntervalSince1970: 1_750_000_100),
                status: .confirmed(at: Date(timeIntervalSince1970: 1_750_000_110))
            ),
            CommandReceipt(
                commandIdentifier: "start-climate",
                issuedAt: Date(timeIntervalSince1970: 1_750_000_120)
            )
        ]
        let decoded = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(state))
        #expect(decoded.commandState.receipts == state.commandState.receipts)
        #expect(decoded.commandState.receipt == state.commandState.receipts.last)

        let bare = try JSONDecoder().decode(
            VehicleState.self, from: JSONEncoder().encode(fullyPopulated()))
        #expect(bare.commandState.receipt == nil)
    }

    @Test("Legacy confirmedAt receipts migrate to the unified terminal status")
    func legacyConfirmedAtStatusMigration() throws {
        struct LegacyReceipt: Encodable {
            let commandIdentifier: String
            let issuedAt: Date
            let command: RemoteCommand
            let confirmedAt: Date
        }
        let confirmedAt = Date(timeIntervalSince1970: 1_750_000_200)
        let data = try JSONEncoder().encode(LegacyReceipt(
            commandIdentifier: "lock",
            issuedAt: Date(timeIntervalSince1970: 1_750_000_100),
            command: .lock,
            confirmedAt: confirmedAt
        ))

        let decoded = try JSONDecoder().decode(CommandReceipt.self, from: data)
        #expect(decoded.status == .confirmed(at: confirmedAt))
    }

    @Test("A payload missing a cluster is never rescued by flat keys")
    func testMissingClusterIsNotRescuedByFlatKeys() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(fullyPopulated())) as? [String: Any])
        // The flat keys are present, but the clusters are the state: a missing one is a corrupt
        // snapshot, and it must fail loudly instead of decoding into a half-empty vehicle.
        let energy = try #require(object.removeValue(forKey: "energy") as? [String: Any])
        object["batteryPercentage"] = energy["batteryPercentage"]
        object["rangeKm"] = energy["rangeKm"]

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                VehicleState.self, from: JSONSerialization.data(withJSONObject: object))
        }
    }
}
