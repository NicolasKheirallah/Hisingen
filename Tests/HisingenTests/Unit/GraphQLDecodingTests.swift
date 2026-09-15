import Foundation
import Testing
@testable import Hisingen

struct GraphQLDecodingTests {
    #if SWIFT_PACKAGE
    @Test
    func testSanitizedFixturesDecodeDeterministically() throws {
        for name in ["vehicle-not-charging", "vehicle-charging", "vehicle-complete",
                     "vehicle-fault", "vehicle-partial-response", "graphql-error"] {
            let url = try #require(Bundle.module.url(forResource: name, withExtension: "json"))
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: data)
            #expect(response.data != nil || response.errors?.isEmpty == false)
        }
    }
    #endif

    @Test
    func testFlexibleVehiclePayloadDecoding() throws {
        let json = #"""
        {"data":{"carTelematicsV2":{"battery":[{
          "vin":"YSMTEST","batteryChargeLevelPercentage":"62.5",
          "estimatedDistanceToEmptyKm":321,"chargingStatusV2":"CHARGING_STATUS_IDLE",
          "estimatedChargingTimeToFullMinutes":0,"timestamp":{"seconds":"2000000000"}
        }],"odometer":[{"vin":"YSMTEST","odometerMeters":"12345000"}],"health":[]}}}
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let battery = try #require(response.data?.carTelematicsV2?.battery?.first)
        #expect(battery.batteryChargeLevelPercentage?.value == 62.5)
        #expect(battery.estimatedDistanceToEmptyKm?.value == 321)
        #expect(battery.timestamp?.date == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(response.data?.carTelematicsV2?.odometer?.first?.odometerMeters?.value == 12_345_000)
    }

    @Test
    func testPartialDataPreservesGraphQLErrorsAndPaths() throws {
        let json = #"""
        {"data":{"carTelematicsV2":{"battery":[],"odometer":[],"health":[]}},
         "errors":[{"message":"battery unavailable","path":["carTelematicsV2","battery",0]}]}
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        #expect(response.data != nil)
        #expect(response.errors?.first?.message == "battery unavailable")
        #expect(response.errors?.first?.path == ["carTelematicsV2", "battery", "0"])
    }

    @Test
    func testMissingDataRemainsMissingRatherThanZero() throws {
        let json = #"{"data":{"carTelematicsV2":{"battery":[{"vin":"YSMTEST"}]}}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let battery = response.data?.carTelematicsV2?.battery?.first
        #expect(battery?.batteryChargeLevelPercentage == nil)
        #expect(battery?.estimatedDistanceToEmptyKm == nil)
    }

    @Test
    func testHTTPFailureClassification() {
        #expect(PolestarError.httpFailure(statusCode: 204) == nil)
        if case .authenticationRequired(.expiredSession)? = PolestarError.httpFailure(statusCode: 401) {} else {
            Issue.record("401 should require authentication")
        }
        if case .rateLimited(let delay)? = PolestarError.httpFailure(statusCode: 429, retryAfter: 42) {
            #expect(delay == 42)
        } else {
            Issue.record("429 should be rate limited")
        }
        if case .server(let status)? = PolestarError.httpFailure(statusCode: 500) {
            #expect(status == 500)
        } else {
            Issue.record("500 should be a server error")
        }
        if case .permissionDenied? = PolestarError.httpFailure(statusCode: 403) {} else {
            Issue.record("403 should be a non-retryable permission error")
        }
        if case .client(let status)? = PolestarError.httpFailure(statusCode: 400) {
            #expect(status == 400)
        } else {
            Issue.record("400 should be a non-retryable client error")
        }
    }

    @Test
    func testGraphQLAuthenticationExtensionsAreRecognized() throws {
        let json = #"{"errors":[{"message":"request rejected","extensions":{"code":"UNAUTHENTICATED"}}]}"#
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let errors = try #require(response.errors)
        #expect(errors.first?.code == "UNAUTHENTICATED")
        #expect(PolestarAPI.containsAuthenticationError(errors))
    }

    @Test
    func testTelemetryNeverFallsBackToAnotherVIN() throws {
        let json = #"{"data":{"carTelematicsV2":{"battery":[{"vin":"VIN-A"},{"vin":"VIN-B"}]}}}"#
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let rows = response.data?.carTelematicsV2?.battery
        #expect(PolestarAPI.matchingReading(rows, vin: "VIN-B", vinOf: { $0.vin })?.vin == "VIN-B")
        #expect(PolestarAPI.matchingReading(rows, vin: "VIN-C", vinOf: { $0.vin }) == nil)

        let legacyJSON = #"{"data":{"carTelematicsV2":{"battery":[{}]}}}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: legacyJSON)
        #expect(PolestarAPI.matchingReading(
            legacy.data?.carTelematicsV2?.battery, vin: "VIN-C", vinOf: { $0.vin }
        ) != nil)
    }

    @Test
    func testTokenResponseAcceptsStringExpiration() throws {
        let data = #"{"access_token":"redacted","refresh_token":"redacted","expires_in":"3599"}"#
            .data(using: .utf8)!
        let token = try JSONDecoder().decode(TokenResponseDTO.self, from: data)
        #expect(token.expiresIn == 3_599)
    }

    @Test
    func testConsumerCarsV2DecodesInternalVehicleIdentifier() throws {
        let url = try #require(Bundle.module.url(forResource: "account-cars-multi", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(GraphQLResponse<ConsumerCarsPayloadDTO>.self, from: data)
        let cars = try #require(response.data?.getConsumerCarsV2)
        #expect(cars.count == 2)
        #expect(cars[0].vin == "LP5SVSEDEKML000001")
        #expect(cars[0].internalVehicleIdentifier == "veh-abc-123")
        #expect(cars[0].modelName == "Polestar 4")
        #expect(cars[0].pno34 == "P50543")
        #expect(cars[1].modelName == "Polestar 2")
    }

    @Test
    func testVDMSDiscoveryDecodesModelFromContent() throws {
        let url = try #require(Bundle.module.url(forResource: "vdms-discovery", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(GraphQLResponse<AppBackendCarsPayloadDTO>.self, from: data)
        let vehicles = try #require(response.data?.vdms?.getVehiclesInformation)
        #expect(vehicles.count == 2)
        #expect(vehicles[0].consumerCar.vin == "LP5SVSEDEKML000001")
        #expect(vehicles[0].consumerCar.modelName == "Polestar 4")
        #expect(vehicles[0].consumerCar.internalVehicleIdentifier == "veh-abc-123")
        #expect(vehicles[1].consumerCar.modelName == "Polestar 2")
    }

    @Test
    func testVDMSDiscoveryDecodesSupportedIdentityFields() throws {
        let json = #"""
        {"data":{"vdms":{"getVehiclesInformation":[{
            "vin":"YS3ED400000000001",
            "internalVehicleIdentifier":"IV-9988",
            "registrationNo":"ABC 123",
            "modelYear":"2024",
            "content":{
                "model":{"name":"Polestar 2 Long Range Dual Motor"}
            }
        }]}}}
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<AppBackendCarsPayloadDTO>.self, from: json)
        let vehicle = try #require(response.data?.vdms?.getVehiclesInformation?.first)
        let car = vehicle.consumerCar
        #expect(car.vin == "YS3ED400000000001")
        #expect(car.internalVehicleIdentifier == "IV-9988")
        #expect(car.registrationNo == "ABC 123")
        #expect(car.modelYear?.value == "2024")
        #expect(car.modelName == "Polestar 2 Long Range Dual Motor")
    }

    @Test
    func emptyVDMSDiscoveryPreservesPrimaryVehicles() throws {
        let data = #"""
        {"data":{"getConsumerCarsV2":[{
          "vin":"YS3ED400000000001","internalVehicleIdentifier":"IV-9988",
          "modelName":"Polestar 2","modelYear":"2024","registrationNo":"ABC 123",
          "pno34":"PNO34-XX","structureWeek":"202326"
        }]}}
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<ConsumerCarsPayloadDTO>.self, from: data)
        let primary = try #require(response.data?.getConsumerCarsV2?.first)

        let merged = PolestarAPI.mergeDiscoveryCars(primary: [primary], vdms: [])

        let vehicle = try #require(merged.first)
        #expect(merged.count == 1)
        #expect(vehicle.vin == primary.vin)
        #expect(vehicle.pno34 == primary.pno34)
    }

    @Test
    func vdmsAuthAndClientRejectionsBackOff_transientErrorsDoNot() {
        // "Could not validate the accessToken" – the app-backend won't accept this token; a
        // day-long back-off, not a per-discovery retry.
        let authFail = PolestarError.graphQL([
            GraphQLServiceError(message: "Could not validate the accessToken",
                                path: ["vdms", "getVehiclesInformation"],
                                code: "AuthenticationFailure")
        ], hasPartialData: true)
        #expect(PolestarAPI.vdmsFailureIsPersistent(authFail))

        // 426 Upgrade Required and an API-shape mismatch are also persistent.
        #expect(PolestarAPI.vdmsFailureIsPersistent(PolestarError.client(statusCode: 426)))
        #expect(PolestarAPI.vdmsFailureIsPersistent(PolestarError.incompatibleAPI(operation: "VDMS")))

        // A transient GraphQL error and a network blip must not arm the back-off.
        let transientGraphQL = PolestarError.graphQL([
            GraphQLServiceError(message: "Internal server error", path: ["vdms"], code: "INTERNAL")
        ], hasPartialData: false)
        #expect(!(PolestarAPI.vdmsFailureIsPersistent(transientGraphQL)))
        #expect(!(PolestarAPI.vdmsFailureIsPersistent(PolestarError.server(statusCode: 503))))
    }

    @Test
    func volvoSlowChangingTelemetryUsesLongerTTLs() {
        #expect(VolvoAPI.optionalTelemetryTTL(for: "doors") == 0)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "command-accessibility") == 5 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "warnings") == 5 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "tyres") == 5 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "location") == 15 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "odometer") == 15 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "brakes") == 15 * 60)
        #expect(VolvoAPI.optionalTelemetryTTL(for: "commands") == 60 * 60)
    }
}
