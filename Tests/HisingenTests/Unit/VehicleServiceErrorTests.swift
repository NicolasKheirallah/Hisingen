import Foundation
import Testing
@testable import Hisingen

struct VehicleServiceErrorTests {

    @Test
    func testPolestarErrorMapsWithPolestarBrand() {
        let mapped = PolestarError.authenticationRequired(.invalidCredentials).asVehicleServiceError
        guard case .authenticationRequired(let provider, let reason) = mapped else {
            return XCTFail("Expected authenticationRequired")
        }
        XCTAssertEqual(provider, .polestar)
        XCTAssertEqual(reason, .invalidCredentials)
        XCTAssertTrue(mapped.requiresAuthentication)
    }

    @Test
    func testVolvoErrorMapsWithVolvoBrand() {
        let mapped = VolvoError.authenticationRequired(.expiredSession).asVehicleServiceError
        guard case .authenticationRequired(let provider, let reason) = mapped else {
            return XCTFail("Expected authenticationRequired")
        }
        XCTAssertEqual(provider, .volvo)
        XCTAssertEqual(reason, .expiredSession)
    }

    @Test
    func testVolvoAppNotConfiguredMapsToNotConfigured() {


        XCTAssertEqual(VolvoError.appNotConfigured.asVehicleServiceError.errorDescription,
                       VehicleServiceError.notConfigured.errorDescription)
        XCTAssertTrue(VolvoError.appNotConfigured.requiresAuthentication)
    }

    @Test
    func testMapPassesThroughAnAlreadySharedError() {
        let original = VehicleServiceError.rateLimited(retryAfter: 30)
        let mapped = VehicleServiceError.map(original, provider: .polestar)
        guard case .rateLimited(let retryAfter) = mapped else { return XCTFail("Expected rateLimited") }
        XCTAssertEqual(retryAfter, 30)
    }

    @Test
    func testMapWrapsPlainURLErrorUsingCallerProvider() {
        let mapped = VehicleServiceError.map(URLError(.notConnectedToInternet), provider: .volvo)
        guard case .network(let error) = mapped else { return XCTFail("Expected network error") }
        XCTAssertEqual(error.code, .notConnectedToInternet)
    }

    @Test
    func testMapNeverMislabelsATypedErrorsBrand() {


        let mapped = VehicleServiceError.map(PolestarError.notConfigured, provider: .volvo)
        XCTAssertEqual(mapped.errorDescription, VehicleServiceError.notConfigured.errorDescription)
    }

    @Test
    func testTransientVsPermanentClassification() {
        XCTAssertTrue(VehicleServiceError.network(URLError(.timedOut)).isTransient)
        XCTAssertTrue(VehicleServiceError.rateLimited(retryAfter: nil).isTransient)
        XCTAssertTrue(VehicleServiceError.temporarilyUnavailable(provider: .volvo, service: "x").isTransient)
        XCTAssertFalse(VehicleServiceError.unsupported(provider: .volvo, service: "x").isTransient)
        XCTAssertFalse(VehicleServiceError.notConfigured.isTransient)
    }
}

