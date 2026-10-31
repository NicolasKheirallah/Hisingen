import Foundation
import Testing
@testable import Hisingen

@MainActor
struct PreferencesStoreJSONEntryTests {

    private static let receiptsKey = "command_receipts_v1"
    private static let erasedVIN = "JSONENTRY-ERASED"
    private static let keptVIN = "JSONENTRY-KEPT"

    @Test
    func erasingOneVehicleKeepsTheOthersInAValidJSONCatalog() throws {
        let scoped = ScopedPreferences(label: "JSONEntryValid")
        let catalog = [
            Self.erasedVIN: StoredCommandReceipts(records: []),
            Self.keptVIN: StoredCommandReceipts(records: [])
        ]
        scoped.defaults.set(try JSONEncoder().encode(catalog), forKey: Self.receiptsKey)

        scoped.store.clearLocalVehicleDefaults(for: Self.erasedVIN)

        let remaining = try #require(scoped.defaults.data(forKey: Self.receiptsKey))
        let decoded = try JSONDecoder().decode([String: StoredCommandReceipts].self, from: remaining)
        #expect(Set(decoded.keys) == [Self.keptVIN])
    }

    @Test
    func anUndecodableCatalogIsLeftInPlaceWhenOneVehicleIsErased() {
        let scoped = ScopedPreferences(label: "JSONEntryCorrupt")
        let corrupt = Data("not a json catalog".utf8)
        scoped.defaults.set(corrupt, forKey: Self.receiptsKey)

        scoped.store.clearLocalVehicleDefaults(for: Self.erasedVIN)

        // Removing the key would erase every vehicle's entries, not only the one being erased.
        #expect(scoped.defaults.data(forKey: Self.receiptsKey) == corrupt)
    }
}
