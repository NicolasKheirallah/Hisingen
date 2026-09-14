import Foundation
import Testing
@testable import Hisingen

struct VehicleServiceErrorTests {

    @Test
    func testPolestarErrorMapsWithPolestarBrand() {
        let mapped = PolestarError.authenticationRequired(.invalidCredentials).asVehicleServiceError
        guard case .authenticationRequired(let provider, let reason) = mapped else {
            Issue.record("Expected authenticationRequired")
            return
        }
        #expect(provider == .polestar)
        #expect(reason == .invalidCredentials)
        #expect(mapped.requiresAuthentication)
    }

    @Test
    func testVolvoErrorMapsWithVolvoBrand() {
        let mapped = VolvoError.authenticationRequired(.expiredSession).asVehicleServiceError
        guard case .authenticationRequired(let provider, let reason) = mapped else {
            Issue.record("Expected authenticationRequired")
            return
        }
        #expect(provider == .volvo)
        #expect(reason == .expiredSession)
    }

    @Test
    func testVolvoAppNotConfiguredMapsToNotConfigured() {


        #expect(VolvoError.appNotConfigured.asVehicleServiceError.errorDescription == VehicleServiceError.notConfigured.errorDescription)
        #expect(VolvoError.appNotConfigured.requiresAuthentication)
    }

    @Test
    func testMapPassesThroughAnAlreadySharedError() {
        let original = VehicleServiceError.rateLimited(retryAfter: 30)
        let mapped = VehicleServiceError.map(original, provider: .polestar)
        guard case .rateLimited(let retryAfter) = mapped else { Issue.record("Expected rateLimited"); return }
        #expect(retryAfter == 30)
    }

    @Test
    func testMapWrapsPlainURLErrorUsingCallerProvider() {
        let mapped = VehicleServiceError.map(URLError(.notConnectedToInternet), provider: .volvo)
        guard case .network(let error) = mapped else { Issue.record("Expected network error"); return }
        #expect(error.code == .notConnectedToInternet)
    }

    @Test
    func testMapNeverMislabelsATypedErrorsBrand() {


        let mapped = VehicleServiceError.map(PolestarError.notConfigured, provider: .volvo)
        #expect(mapped.errorDescription == VehicleServiceError.notConfigured.errorDescription)
    }

    @Test
    func testTransientVsPermanentClassification() {
        #expect(VehicleServiceError.network(URLError(.timedOut)).isTransient)
        #expect(VehicleServiceError.rateLimited(retryAfter: nil).isTransient)
        #expect(VehicleServiceError.temporarilyUnavailable(provider: .volvo, service: "x").isTransient)
        #expect(!(VehicleServiceError.unsupported(provider: .volvo, service: "x").isTransient))
        #expect(!(VehicleServiceError.notConfigured.isTransient))
    }
}


