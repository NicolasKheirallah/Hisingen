import Foundation
import Testing
@testable import Hisingen

@MainActor
struct CarProfileTests {

    @Test
    func testSilhouetteKeyedOnModelAndBrandNotTheme() {
        let polestarModel = VehicleModel(modelName: "Polestar 2", vin: "YSMV12345")
        let volvoModel = VehicleModel(modelName: "XC40", vin: "YV1A12345")

        // Polestar model yields polestar profile
        let polestarProfile = CarProfile.profile(for: polestarModel)
        #expect(polestarProfile.roofFront == CarProfile.polestar.roofFront)

        // Volvo model yields volvo profile
        let volvoProfile = CarProfile.profile(for: volvoModel)
        #expect(volvoProfile.roofFront == CarProfile.volvo.roofFront)

        // Direct brand yields respective profile
        #expect(CarProfile.profile(for: nil, brand: .polestar).roofFront == CarProfile.polestar.roofFront)
        #expect(CarProfile.profile(for: nil, brand: .volvo).roofFront == CarProfile.volvo.roofFront)
    }
}
