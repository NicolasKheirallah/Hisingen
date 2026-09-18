import Foundation
import Testing
@testable import Hisingen

/// Surfacing gates for the raw-output coverage review: pending charge settings, setting
/// source, climate start reason, ventilation, sub-kilometre odometer, per-domain ingest
/// freshness, availability check-in, and the already-shipped arrival/digital-key rows.
/// Every endpoint payload is inline so a fixture edit in the main portal suite cannot
/// silently move these assertions.
@Suite(.serialized)
@MainActor
struct PolestarPortalCoverageSurfacingTests {

    // MARK: - Inline portal payloads

    private func json(_ string: String) -> Data { Data(string.utf8) }

    private func timestamp(_ seconds: Int) -> String {
        """
        {"seconds": "\(seconds)", "nanos": 0}
        """
    }

    private let vin = "YSMVSEDE6PL147228"

    private func endpointPayloads(
        targetSocSource: String = "RCS",
        startReason: String = "START_REASON_REMOTE",
        pendingTarget: Int? = 85,
        pendingAmps: Int? = 20
    ) -> [String: (Int, Data)] {
        var payload: [String: (Int, Data)] = [:]

        payload["/telemetry/battery"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_100)),
         "batteryChargeLevelPercentage": 78.5,
         "chargingStatusV2": "CHARGING_STATUS_V2_CHARGING",
         "estimatedChargingTimeToFullMinutes": 35,
         "metaReceivedAt": "2024-05-21T14:01:40Z"}
        """))

        payload["/telemetry/exterior"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_090)),
         "centralLock": "CENTRAL_LOCK_STATUS_LOCKED",
         "metaReceivedAt": "2024-05-21T14:01:40Z"}
        """))

        payload["/telemetry/health"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_080)),
         "metaReceivedAt": "2024-05-21T14:01:40Z"}
        """))

        payload["/telemetry/availability"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_000)),
         "availabilityStatus": "AVAILABLE", "usageMode": "INACTIVE",
         "metaReceivedAt": "2024-05-21T14:00:30Z"}
        """))

        payload["/telemetry/odometer"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_080)),
         "odometerMeters": 42150800, "tripMeterManualKm": 128.4,
         "metaReceivedAt": "2024-05-21T14:01:20Z"}
        """))

        payload["/telemetry/location"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_299_570)),
         "coordinate": {"latitude": 57.708870, "longitude": 11.938900},
         "metaReceivedAt": "2024-05-21T14:01:20Z"}
        """))

        payload["/telemetry/parking-climatization"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_300_100)),
         "runningStatus": "RUNNING_STATUS_ON",
         "ventilation": "VENTILATION_HEATING",
         "runtimeLeftMinutes": 18,
         "startReason": "\(startReason)",
         "metaReceivedAt": "2024-05-21T14:41:40Z"}
        """))

        payload["/telemetry/pre-cleaning"] = (200, json("""
        {"vin": "\(vin)", "timestamp": \(timestamp(1_716_299_000)),
         "runningStatus": "RUNNING_STATUS_OFF",
         "metaReceivedAt": "2024-05-21T14:01:20Z"}
        """))

        let pendingTargetField = pendingTarget.map {
            """
            , "pendingTargetSoc": {"batteryChargeTargetLevel": \($0), "source": "RCS"}
            """
        } ?? ""
        payload["/charging/target-soc"] = (200, json("""
        {"vin": "\(vin)",
         "targetSoc": {"batteryChargeTargetLevel": 80, "source": "\(targetSocSource)"}\(pendingTargetField),
         "metaReceivedAt": "2024-05-21T14:01:35Z"}
        """))

        let pendingAmpField = pendingAmps.map {
            """
            , "pendingAmpLimit": {"ampLimit": \($0), "source": "RCS"}
            """
        } ?? ""
        payload["/charging/amp-limit"] = (200, json("""
        {"vin": "\(vin)",
         "ampLimit": {"ampLimit": 16, "source": "\(targetSocSource)"}\(pendingAmpField),
         "metaReceivedAt": "2024-05-21T14:01:35Z"}
        """))

        payload["/charging/charge-locations"] = (200, json("""
        {"vin": "\(vin)", "utc0": false,
         "chargeLocations": [{"locationId": "loc-home-01", "locationAlias": "Home Garage",
                              "ampLimit": 16, "minimumSoc": 40,
                              "isOptimizedChargingEnabled": true}]}
        """))

        payload["/charging/is-at-charge-location"] = (200, json("""
        {"vin": "\(vin)", "locationId": "loc-home-01",
         "arrivedAtTimestamp": \(timestamp(1_716_299_100)),
         "metaReceivedAt": "2024-05-21T14:01:35Z"}
        """))

        payload["/charging/global-charge-timer"] = (200, json("""
        {"vin": "\(vin)", "utc0": false}
        """))

        payload["/charging/parking-climate-timer"] = (200, json("""
        {"vin": "\(vin)", "utc0": false, "parkingClimateTimers": []}
        """))

        payload["/charging/charge-now"] = (200, json("""
        {"vin": "\(vin)", "syncedOverrideChargeTimer": {"override": false},
         "metaReceivedAt": "2024-05-21T14:01:35Z"}
        """))

        return payload
    }

    /// Fetches one full portal state against the stubbed transport.
    private func fetchState() async throws -> VehicleState {
        try await fetchState(payloads: endpointPayloads())
    }

    private func fetchState(
        payloads: [String: (Int, Data)]
    ) async throws -> VehicleState {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CoverageSurfacingTransport.self]
        let session = URLSession(configuration: config)

        let api = PolestarDataPortalAPI()
        await api.setSessionForTesting(session)
        await api.setAccessTokenForTesting("test-token")
        await api.configure(clientID: "client-id", clientSecret: "client-secret")

        CoverageSurfacingTransport.requestHandler = { request in
            let path = request.url?.path ?? ""
            for (fragment, response) in payloads where path.contains(fragment) {
                return response
            }
            return (404, Data())
        }

        return try await api.fetchVehicleState(
            vin: vin,
            features: FeatureSelection(enabled: Set(AppFeature.allCases))
        )
    }

    // MARK: - G1 pending charge settings

    @Test
    func pendingChargeSettingsSurfaceAsUnapplied() async throws {
        let state = try await fetchState()
        let diagnostics = try #require(state.energy.diagnostics)
        #expect(diagnostics.pendingTargetPercentage == 85)
        #expect(diagnostics.pendingLimitAmps == 20)
        // Synced values stay untouched by the pending copies.
        #expect(state.energy.targetPercentage == 80)
        #expect(state.energy.currentLimitAmps == 16)
        // Differing pending values read as unapplied.
        #expect(diagnostics.unappliedTargetPercentage(current: state.energy.targetPercentage) == 85)
        #expect(diagnostics.unappliedLimitAmps(current: state.energy.currentLimitAmps) == 20)
        // The wire keeps a pending copy even after the car applies it; equality reads as applied.
        #expect(diagnostics.unappliedTargetPercentage(current: 85) == nil)
        #expect(diagnostics.unappliedLimitAmps(current: 20) == nil)
        #expect(diagnostics.unappliedTargetPercentage(current: Int?.none) == 85)
    }

    // MARK: - G2 setting source

    @Test
    func chargingSettingSourceIsRetainedAndLabelled() async throws {
        let state = try await fetchState()
        let diagnostics = try #require(state.energy.diagnostics)
        #expect(diagnostics.targetSource == "RCS")
        #expect(diagnostics.limitSource == "RCS")

        // Verified vocabulary gets labels; unknown tokens render raw; silence stays silent.
        #expect(VehicleChargingCard.chargingSourceSuffix("RCS") == L10n.text("Set remotely"))
        #expect(VehicleChargingCard.chargingSourceSuffix("app") == L10n.text("Set from app"))
        #expect(VehicleChargingCard.chargingSourceSuffix("FUTURE_SOURCE") == "FUTURE_SOURCE")
        #expect(VehicleChargingCard.chargingSourceSuffix(nil) == nil)

        let carSource = try await fetchState(payloads: endpointPayloads(targetSocSource: "APP"))
        #expect(carSource.energy.diagnostics?.targetSource == "APP")
    }

    // MARK: - G3 climate start reason

    @Test
    func climateStartReasonUsesTheSharedStartVocabulary() async throws {
        let state = try await fetchState()
        #expect(state.climateStatus?.startReason == .remote)
        #expect(state.climateStatus?.timerTriggered == false)

        // The wire vocabulary is shared with pre-cleaning; every token maps, unknown and
        // unspecified stay nil so "the car did not say" remains distinguishable.
        #expect(VehicleStartReason(wireToken: "START_REASON_TIMER") == .timer)
        #expect(VehicleStartReason(wireToken: "START_REASON_MANUALLY_FROM_CAR") == .manuallyFromCar)
        #expect(VehicleStartReason(wireToken: "START_REASON_KEEP_CLIMATE") == .keepClimate)
        #expect(VehicleStartReason(wireToken: "START_REASON_UNSPECIFIED") == nil)
        #expect(VehicleStartReason(wireToken: "START_REASON_SOMETHING_NEW") == nil)
        #expect(VehicleStartReason(wireToken: nil) == nil)

        let timerStarted = try await fetchState(payloads: endpointPayloads(startReason: "START_REASON_TIMER"))
        #expect(timerStarted.climateStatus?.startReason == .timer)
        #expect(timerStarted.climateStatus?.timerTriggered == true)
        #expect(timerStarted.climateStatus?.startReason?.displayName == L10n.text("Departure timer"))
    }

    // MARK: - G4 ventilation

    @Test
    func ventilationModeRendersFromTheSpecVocabulary() async throws {
        let state = try await fetchState()
        #expect(state.climateStatus?.ventilation == "VENTILATION_HEATING")
        #expect(state.climateStatus?.ventilationName == L10n.text("Heating"))

        func name(for token: String?) -> String? {
            VehicleClimateStatus(
                activity: .active, timeRemainingMinutes: nil, timerTriggered: false, ventilation: token
            ).ventilationName
        }
        #expect(name(for: "VENTILATION_COOLING") == L10n.text("Cooling"))
        #expect(name(for: "VENTILATION_NEUTRAL") == L10n.text("Neutral"))
        #expect(name(for: "VENTILATION_UNSPECIFIED") == nil)
        #expect(name(for: nil) == nil)
        // A token outside the known set renders cleaned-up, never as a guessed mode.
        #expect(name(for: "VENTILATION_FUTURE_MODE") == "Future Mode")
    }

    // MARK: - G5 odometer precision

    @Test
    func odometerMetresPreserveSubKilometrePrecision() async throws {
        let state = try await fetchState()
        // 42,150,800 m is 42,150.8 km; the rounded integer keeps its own slot.
        #expect(state.maintenance.odometerKm == 42151)
        #expect(state.maintenance.odometerKmPrecise == 42150.8)
        #expect(Format.distance(km: 42150.8, decimals: 1, unit: .kilometers) == "42150.8 km")
    }

    // MARK: - G6 freshness + availability check-in

    @Test
    func perDomainFreshnessAndAvailabilityCheckInReachTheCards() async throws {
        let state = try await fetchState()
        // The availability frame carries its own reading row with the check-in time.
        #expect(state.freshness.readingDates[.availability] == Date(timeIntervalSince1970: 1_716_300_000))
        #expect(state.identity.availabilityReportedAt == Date(timeIntervalSince1970: 1_716_300_000))
        #expect(state.reportedDate(for: .availability) == state.identity.availabilityReportedAt)

        // Portal ingest times are retained per domain.
        let received = try #require(state.freshness.metaReceivedDates)
        #expect(received[.battery] == Date(timeIntervalSince1970: 1_716_300_100))
        #expect(received[.availability] == Date(timeIntervalSince1970: 1_716_300_030))

        // Sub-minute jitter stays hidden; a queued pipeline gap is named in whole minutes.
        #expect(InfoTabView.portalIngestLagMinutes(receivedAt: nil, reportedAt: Date()) == nil)
        #expect(InfoTabView.portalIngestLagMinutes(
            receivedAt: Date(timeIntervalSince1970: 1_716_300_090),
            reportedAt: Date(timeIntervalSince1970: 1_716_300_000)) == 1)
        #expect(InfoTabView.portalIngestLagMinutes(
            receivedAt: Date(timeIntervalSince1970: 1_716_300_050),
            reportedAt: Date(timeIntervalSince1970: 1_716_300_000)) == nil)
        #expect(InfoTabView.portalIngestLagMinutes(
            receivedAt: Date(timeIntervalSince1970: 1_716_300_100),
            reportedAt: Date(timeIntervalSince1970: 1_716_297_700)) == 40)
    }

    // MARK: - G7 digital key / NFC rows

    @Test
    func digitalKeyAndNfcStayNamedSpecRows() {
        let equipment = VehicleEquipment(
            digitalKey: "Polestar 2",
            nfcReader: "Door handle",
            compatiblePhones: ["iPhone 15"]
        )
        let titles = equipment.details.map(\.title)
        #expect(titles.contains("Digital Key Type"))
        #expect(titles.contains("NFC Reader Location"))
        #expect(titles.contains("Compatible Phones"))
        #expect(equipment.details.first { $0.title == "Digital Key Type" }?.value == "Polestar 2")
    }

    // MARK: - G8 charge-location arrival

    @Test
    func chargeLocationArrivalReachesTheChargingCard() async throws {
        let state = try await fetchState()
        #expect(state.energy.isAtChargeLocation == true)
        // The is-at read's bare locationId joins against the charge-locations list.
        #expect(state.energy.currentChargeLocationName == "Home Garage")
        #expect(state.energy.arrivedAtLocationDate == Date(timeIntervalSince1970: 1_716_299_100))
    }
}

private final class CoverageSurfacingTransport: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://polestar.com")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
