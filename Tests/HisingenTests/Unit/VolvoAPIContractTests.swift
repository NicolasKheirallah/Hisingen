import Foundation
import Testing
@testable import Hisingen

/// Contract checks against Volvo's published specifications, added with the fixes that came out of
/// reading them: command statuses that used to fall through to "accepted", the subscription
/// resource the app never asked for, an availability frame too old to describe the car, and the
/// trace headers both API families declare on every operation.
struct VolvoAPIContractTests {

    private func command(_ status: String) throws -> VolvoCommandResponseDTO {
        let json = #"{"data":{"vin":"YV1CONTRACT000001","invokeStatus":"\#(status)","message":"m"}}"#
        let envelope = try JSONDecoder.volvo.decode(
            VolvoEnvelope<VolvoCommandResponseDTO>.self, from: Data(json.utf8)
        )
        return try #require(envelope.data)
    }

    /// These six are documented `Invoke.invokeStatus` values that used to produce neither an
    /// outcome nor a reason, so `dispatchCommand`'s fallback reported the command as accepted.
    @Test(
        "A documented failure status carries a reason instead of reading as accepted",
        arguments: [
            "NOT_SUPPORTED", "EXPIRED", "CAR_IN_SLEEP_MODE",
            "DELIVERY_TIMEOUT", "CAR_TIMEOUT", "INVOCATION_SPECIFIC_ERROR"
        ]
    )
    func documentedFailuresCarryAReason(status: String) throws {
        let payload = try command(status)
        #expect(payload.isFailure, "\(status) must not read as a success")
        #expect(payload.failureReason?.isEmpty == false)
        #expect(payload.outcome == nil, "\(status) is a failure, not an outcome")
    }

    @Test("The two sleep statuses share one explanation")
    func bothSleepStatusesExplainThemselves() throws {
        let vehicle = try command("VEHICLE_IN_SLEEP")
        let car = try command("CAR_IN_SLEEP_MODE")
        #expect(vehicle.failureReason == car.failureReason)
    }

    @Test("A sent command is in progress, not unknown")
    func sentIsAccepted() throws {
        #expect(try command("SENT").outcome == .accepted)
    }

    @Test("The subscription resource decodes without the Connected Vehicle data envelope")
    func subscriptionDecodes() throws {
        let json = #"{"vocSubscription":{"hasPremiumSubscription":false}}"#
        let dto = try JSONDecoder.volvo.decode(VolvoVOCSubscriptionDTO.self, from: Data(json.utf8))
        #expect(dto.hasPremiumSubscription == false)
    }

    @Test("An absent subscription body is an unknown, not a lapse")
    func missingSubscriptionIsUnknown() throws {
        let dto = try JSONDecoder.volvo.decode(VolvoVOCSubscriptionDTO.self, from: Data("{}".utf8))
        #expect(dto.hasPremiumSubscription == nil)
    }

    @Test("A stale availability frame stretches the cadence to the asleep interval")
    func staleAvailabilitySlowsPolling() {
        let fresh = RefreshPolicy.interval(
            isCharging: false, isClimateActive: false,
            isVehicleAvailable: true, availabilityAge: 60
        )
        let stale = RefreshPolicy.interval(
            isCharging: false, isClimateActive: false,
            isVehicleAvailable: true,
            availabilityAge: RefreshPolicy.availabilityStaleAfter + 60
        )
        #expect(fresh == RefreshPolicy.regularInterval(isCharging: false))
        #expect(stale == RefreshPolicy.vehicleAsleepInterval)
    }

    @Test("A charging or climatising car keeps its cadence despite a stale frame")
    func activityBeatsStaleAvailability() {
        let charging = RefreshPolicy.interval(
            isCharging: true, isClimateActive: false,
            isVehicleAvailable: true, availabilityAge: 400_000
        )
        let climatising = RefreshPolicy.interval(
            isCharging: false, isClimateActive: true,
            isVehicleAvailable: true, availabilityAge: 400_000
        )
        #expect(charging == RefreshPolicy.regularInterval(isCharging: true))
        #expect(climatising == RefreshPolicy.regularInterval(isCharging: false, isClimateActive: true))
    }

    @Test("An unknown availability age leaves the cadence alone")
    func unknownAgeIsUnchanged() {
        let interval = RefreshPolicy.interval(
            isCharging: false, isClimateActive: false,
            isVehicleAvailable: true, availabilityAge: nil
        )
        #expect(interval == RefreshPolicy.regularInterval(isCharging: false))
    }

    @Test("An unavailable vehicle still reaches the asleep interval")
    func unavailableStaysAsleep() {
        let interval = RefreshPolicy.interval(
            isCharging: false, isClimateActive: false,
            isVehicleAvailable: false, availabilityAge: 5
        )
        #expect(interval == RefreshPolicy.vehicleAsleepInterval)
    }

    @Test("The trace headers use the W3C shape and one shared id")
    func traceContextShape() {
        let trace = VolvoTraceContext()
        let parts = trace.traceparent.split(separator: "-")
        #expect(parts.count == 4)
        #expect(parts[0] == "00")
        #expect(parts[1].count == 32)
        #expect(parts[2].count == 16)
        #expect(parts[3] == "01")
        let compactID = trace.operationID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        #expect(parts[1] == compactID[...])
    }
}
