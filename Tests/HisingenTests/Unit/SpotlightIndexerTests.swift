import Testing
@testable import Hisingen

/// Spotlight never stores a VIN: the index key is a digest. Activation therefore has to be
/// resolved against the vehicles this Mac already knows, which is what these two tests pin.
@MainActor
struct SpotlightIndexerTests {
    @Test
    func anIndexedVehicleResolvesBackToItsVIN() {
        let vin = "YV1ABCDEFGH123456"
        let identifier = SpotlightIndexer.activityIdentifier(for: vin)
        #expect(SpotlightIndexer.vin(forActivityIdentifier: identifier, among: [vin]) == vin)
        // A removal and a write must agree on normalization, so a lowercase key still resolves.
        #expect(SpotlightIndexer.vin(forActivityIdentifier: identifier, among: [vin.lowercased()]) == vin.lowercased())
    }

    @Test
    func anotherCarsIdentifierResolvesToNothing() {
        let identifier = SpotlightIndexer.activityIdentifier(for: "YV1ABCDEFGH123456")
        #expect(SpotlightIndexer.vin(forActivityIdentifier: identifier,
                                     among: ["YV1ZZZZZZZZ999999"]) == nil)
        #expect(SpotlightIndexer.vin(forActivityIdentifier: "not-a-hisingen-key", among: []) == nil)
    }
}
