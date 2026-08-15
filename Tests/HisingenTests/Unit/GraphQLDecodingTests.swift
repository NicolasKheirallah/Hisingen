import Foundation
import Testing
@testable import Hisingen

struct GraphQLDecodingTests {
    #if SWIFT_PACKAGE
    @Test
    func testSanitizedFixturesDecodeDeterministically() throws {
        for name in ["vehicle-not-charging", "vehicle-charging", "vehicle-complete",
                     "vehicle-fault", "vehicle-partial-response", "graphql-error"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
            let data = try Data(contentsOf: url)
            let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: data)
            XCTAssertTrue(response.data != nil || response.errors?.isEmpty == false)
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
        let battery = try XCTUnwrap(response.data?.carTelematicsV2?.battery?.first)
        XCTAssertEqual(battery.batteryChargeLevelPercentage?.value, 62.5)
        XCTAssertEqual(battery.estimatedDistanceToEmptyKm?.value, 321)
        XCTAssertEqual(battery.timestamp?.date, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(response.data?.carTelematicsV2?.odometer?.first?.odometerMeters?.value, 12_345_000)
    }

    @Test
    func testPartialDataPreservesGraphQLErrorsAndPaths() throws {
        let json = #"""
        {"data":{"carTelematicsV2":{"battery":[],"odometer":[],"health":[]}},
         "errors":[{"message":"battery unavailable","path":["carTelematicsV2","battery",0]}]}
        """#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        XCTAssertNotNil(response.data)
        XCTAssertEqual(response.errors?.first?.message, "battery unavailable")
        XCTAssertEqual(response.errors?.first?.path, ["carTelematicsV2", "battery", "0"])
    }

    @Test
    func testMissingDataRemainsMissingRatherThanZero() throws {
        let json = #"{"data":{"carTelematicsV2":{"battery":[{"vin":"YSMTEST"}]}}}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let battery = response.data?.carTelematicsV2?.battery?.first
        XCTAssertNil(battery?.batteryChargeLevelPercentage)
        XCTAssertNil(battery?.estimatedDistanceToEmptyKm)
    }

    @Test
    func testHTTPFailureClassification() {
        XCTAssertNil(PolestarError.httpFailure(statusCode: 204))
        if case .authenticationRequired(.expiredSession)? = PolestarError.httpFailure(statusCode: 401) {} else {
            XCTFail("401 should require authentication")
        }
        if case .rateLimited(let delay)? = PolestarError.httpFailure(statusCode: 429, retryAfter: 42) {
            XCTAssertEqual(delay, 42)
        } else {
            XCTFail("429 should be rate limited")
        }
        if case .server(let status)? = PolestarError.httpFailure(statusCode: 500) {
            XCTAssertEqual(status, 500)
        } else {
            XCTFail("500 should be a server error")
        }
        if case .permissionDenied? = PolestarError.httpFailure(statusCode: 403) {} else {
            XCTFail("403 should be a non-retryable permission error")
        }
        if case .client(let status)? = PolestarError.httpFailure(statusCode: 400) {
            XCTAssertEqual(status, 400)
        } else {
            XCTFail("400 should be a non-retryable client error")
        }
    }

    @Test
    func testGraphQLAuthenticationExtensionsAreRecognized() throws {
        let json = #"{"errors":[{"message":"request rejected","extensions":{"code":"UNAUTHENTICATED"}}]}"#
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let errors = try XCTUnwrap(response.errors)
        XCTAssertEqual(errors.first?.code, "UNAUTHENTICATED")
        XCTAssertTrue(PolestarAPI.containsAuthenticationError(errors))
    }

    @Test
    func testTelemetryNeverFallsBackToAnotherVIN() throws {
        let json = #"{"data":{"carTelematicsV2":{"battery":[{"vin":"VIN-A"},{"vin":"VIN-B"}]}}}"#
            .data(using: .utf8)!
        let response = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: json)
        let rows = response.data?.carTelematicsV2?.battery
        XCTAssertEqual(PolestarAPI.matchingReading(rows, vin: "VIN-B", vinOf: { $0.vin })?.vin, "VIN-B")
        XCTAssertNil(PolestarAPI.matchingReading(rows, vin: "VIN-C", vinOf: { $0.vin }))

        let legacyJSON = #"{"data":{"carTelematicsV2":{"battery":[{}]}}}"#.data(using: .utf8)!
        let legacy = try JSONDecoder().decode(GraphQLResponse<TelematicsPayloadDTO>.self, from: legacyJSON)
        XCTAssertNotNil(PolestarAPI.matchingReading(
            legacy.data?.carTelematicsV2?.battery, vin: "VIN-C", vinOf: { $0.vin }
        ))
    }

    @Test
    func testTokenResponseAcceptsStringExpiration() throws {
        let data = #"{"access_token":"redacted","refresh_token":"redacted","expires_in":"3599"}"#
            .data(using: .utf8)!
        let token = try JSONDecoder().decode(TokenResponseDTO.self, from: data)
        XCTAssertEqual(token.expiresIn, 3_599)
    }

    @Test
    func testConsumerCarsV2DecodesInternalVehicleIdentifier() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "account-cars-multi", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(GraphQLResponse<ConsumerCarsPayloadDTO>.self, from: data)
        let cars = try XCTUnwrap(response.data?.getConsumerCarsV2)
        XCTAssertEqual(cars.count, 2)
        XCTAssertEqual(cars[0].vin, "LP5SVSEDEKML000001")
        XCTAssertEqual(cars[0].internalVehicleIdentifier, "veh-abc-123")
        XCTAssertEqual(cars[0].modelName, "Polestar 4")
        XCTAssertEqual(cars[0].pno34, "P50543")
        XCTAssertEqual(cars[1].modelName, "Polestar 2")
    }

    @Test
    func testVDMSDiscoveryDecodesModelFromContent() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "vdms-discovery", withExtension: "json"))
        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(GraphQLResponse<AppBackendCarsPayloadDTO>.self, from: data)
        let vehicles = try XCTUnwrap(response.data?.vdms?.getVehiclesInformation)
        XCTAssertEqual(vehicles.count, 2)
        XCTAssertEqual(vehicles[0].consumerCar.vin, "LP5SVSEDEKML000001")
        XCTAssertEqual(vehicles[0].consumerCar.modelName, "Polestar 4")
        XCTAssertEqual(vehicles[0].consumerCar.internalVehicleIdentifier, "veh-abc-123")
        XCTAssertEqual(vehicles[1].consumerCar.modelName, "Polestar 2")
    }
}


