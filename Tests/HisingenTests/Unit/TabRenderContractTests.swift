import Foundation
import Testing
@testable import Hisingen

/// The renderer contract: every tab view's list and the catalogue are the same inventory.
/// These are the tests that would have caught the pane and the panel drifting apart.
@MainActor
struct TabRenderContractTests {
    @Test
    func everyInfoSectionMapsToACardOnCar() {
        let cards = Set(TabItemCatalog.items(in: .info).map(\.id)).subtracting([.infoNavBar])
        let sections = Set(InfoTabView.InfoSection.allCases.map(InfoTabView.item(for:)))
        #expect(sections == cards)
    }

    @Test
    func planRenderedItemsMatchItsShippedLayout() {
        #expect(Set(ControlsTabView.renderedItems) == Set(TabItemCatalog.defaultItems(for: .controls)))
    }

    @Test
    func everyHistorySectionMapsToACardOnLog() {
        let scoped = ScopedPreferences(label: "tab-render-contract")
        let view = HistoryDashboardView(
            state: vehicle(),
            history: HistoryWorkspace(database: .inMemory(), preferences: scoped.store),
            initialSection: nil
        )
        let mapped = Set(view.historySections.compactMap(\.item))
        let cards = Set(TabItemCatalog.defaultItems(for: .history)).subtracting([.historyPeriodPicker])
        #expect(mapped == cards)
    }

    // MARK: - Availability

    @Test
    func aSwitchedOffReadingSaysSo() {
        #expect(TabItemAvailability.of(
            .vehicleWeather, state: vehicle(), enabledFeatures: [], plannerAvailable: true
        ) == .switchedOff)
    }

    @Test
    func aPlannerOnACarWithoutElectricRangeIsNotSupported() {
        let state = vehicle(powertrain: .ice)
        #expect(TabItemAvailability.of(
            .vehicleChargingPlanner, state: state,
            enabledFeatures: [.smartChargingPlanner], plannerAvailable: true
        ) == .notSupported)
    }

    @Test
    func aReadingTheCarHasNotSentIsNotReported() {
        let state = vehicle(weather: nil)
        #expect(TabItemAvailability.of(
            .vehicleWeather, state: state,
            enabledFeatures: [.vehicleWeather], plannerAvailable: true
        ) == .notReported)
    }

    @Test
    func aReadingTheCarHasSentIsDrawable() {
        let weather = VehicleWeather(temperatureCelsius: 3, condition: "Clear")
        let state = vehicle(weather: weather)
        #expect(TabItemAvailability.of(
            .vehicleWeather, state: state,
            enabledFeatures: [.vehicleWeather], plannerAvailable: true
        ) == .drawable)
    }

    @Test
    func receiptsAreNotReportedUntilThereAreAny() {
        #expect(TabItemAvailability.of(
            .vehicleReceipts, state: vehicle(), enabledFeatures: [], plannerAvailable: true
        ) == .notReported)
        // With no snapshot there is nothing to judge.
        #expect(TabItemAvailability.of(
            .vehicleReceipts, state: nil, enabledFeatures: [], plannerAvailable: true
        ) == .drawable)
    }

    @Test
    func anEngineCardOnAnElectricCarIsNotSupported() {
        #expect(TabItemAvailability.of(
            .controlsEngine, state: vehicle(powertrain: .bev),
            enabledFeatures: [.remoteClimate], plannerAvailable: true
        ) == .notSupported)
    }
}
