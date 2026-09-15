import Foundation
import Testing
@testable import Hisingen

/// Regression coverage for command-validation and charging-session fixes.
struct CommandBoundsAndSessionEnergyTests {

    // MARK: - Capability-aware charge-target / amp-limit validation

    private func rejectionMessage(of error: Error) -> String? {
        guard case RemoteCommandError.rejected(let message) = error else { return nil }
        return message
    }

    @Test
    func testChargeTargetBelowFallbackMinimumIsRejectedLocally() async {
        let grpc = PolestarGRPC()
        do {
            _ = try await grpc.executeRemoteCommand(.setChargeTarget(30), vin: "VIN", accessToken: "t")
            Issue.record("Expected local rejection")
        } catch {
            #expect(rejectionMessage(of: error) != nil)
        }
    }

    @Test
    func testChargeTargetRespectsVehicleAdvertisedMinimum() async {
        let grpc = PolestarGRPC()
        await grpc.setCapabilityLimitsForTesting(
            vin: "VIN",
            VehicleOTACapabilities(targetChargeLevelPercentageMinLimit: 50)
        )
        do {
            _ = try await grpc.executeRemoteCommand(.setChargeTarget(45), vin: "VIN", accessToken: "t")
            Issue.record("Expected local rejection below advertised minimum")
        } catch {
            let message = rejectionMessage(of: error)
            #expect(message != nil)
            // The rejection must name the vehicle-specific bound, not a generic failure.
            #expect(message?.contains("50") == true)
        }
    }

    @Test
    func testAmpLimitRespectsVehicleAdvertisedRange() async {
        let grpc = PolestarGRPC()
        await grpc.setCapabilityLimitsForTesting(
            vin: "VIN",
            VehicleOTACapabilities(chargeAmperageMinLimit: 6, chargeAmperageMaxLimit: 32)
        )
        for outOfRange in [5, 40] {
            do {
                _ = try await grpc.executeRemoteCommand(.setAmpLimit(outOfRange), vin: "VIN", accessToken: "t")
                Issue.record("Expected local rejection for \(outOfRange) A")
            } catch {
                let message = rejectionMessage(of: error)
                #expect(message != nil)
                #expect(message?.contains("6") == true && message?.contains("32") == true)
            }
        }
    }

    // MARK: - Session energy honours calibrated capacity

    @Test
    func testCompletedSessionUsesSuppliedUsableCapacity() throws {
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        var previous = VehicleState(
            batteryPercentage: 20, rangeKm: nil, chargingState: .charging,
            estimatedChargingTimeToFullMinutes: nil, chargeTargetPercentage: nil,
            chargingPowerWatts: nil, chargingCurrentAmps: nil, chargingVoltageVolts: nil,
            chargingType: .unknown, chargerConnection: .connected,
            availability: .available, modelName: "Polestar 2", modelYear: "2024",
            registrationNo: nil, vin: "CAPTEST", ownerFirstName: nil,
            odometerKm: nil, daysToService: nil, distanceToServiceKm: nil,
            serviceWarning: false, fluidWarnings: [],
            imageData: nil, fetchedAt: start, vehicleReportedAt: nil, dataWarnings: []
        )
        previous.energy.samples = [
            ChargingSample(timestamp: start, batteryPercentage: 20),
            ChargingSample(timestamp: start.addingTimeInterval(600), batteryPercentage: 35),
        ]
        var current = previous
        current.energy.chargingState = .complete
        current.energy.batteryPercentage = 70
        current.freshness.fetchedAt = start.addingTimeInterval(3_600)

        // 50 % gained × 82 kWh override = 41 kWh – not the model-table default.
        let session = try #require(ChargingSession.completed(
            previous: previous, current: current, pricePerKwh: 0,
            usableCapacityKwh: 82
        ))
        #expect(abs(session.kwhDelivered - 41.0) <= 0.001)

        // Without an explicit capacity the nominal table still applies (75 kWh for a 2024
        // Polestar 2 is overridden by the year rule to 79 kWh).
        let fallback = try #require(ChargingSession.completed(
            previous: previous, current: current, pricePerKwh: 0
        ))
        #expect(abs(fallback.kwhDelivered - 39.5) <= 0.001)
    }
}
