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
        #expect(ControlsTabView.renderedItems == TabItemCatalog.defaultItems(for: .controls))
    }

    @Test
    func planKeepsReceiptsInTheConfiguredOrderAndCanHideThem() {
        var composition = TabComposition()
        let controls: Set<TabItemID> = [.controlsClimate, .controlsRoutines]
        composition.setItems([.controlsClimate, .vehicleReceipts, .controlsRoutines], for: .controls)
        let layout = TabLayout.resolve(composition, for: .controls)
        #expect(ControlsTabView.orderedCardItems(layout: layout, controls: controls, hasReceipts: true)
                == [.controlsClimate, .vehicleReceipts, .controlsRoutines])
        #expect(ControlsTabView.orderedCardItems(layout: layout, controls: controls, hasReceipts: false)
                == [.controlsClimate, .controlsRoutines])

        composition.setItem(.vehicleReceipts, shown: false, on: .controls)
        let hidden = TabLayout.resolve(composition, for: .controls)
        #expect(ControlsTabView.orderedCardItems(layout: hidden, controls: controls, hasReceipts: true)
                == [.controlsClimate, .controlsRoutines])
    }

    @Test(arguments: [false, true])
    func nowShowsTyresOnlyWhenExplicitlyPlaced(twoColumns: Bool) {
        let features = FeatureSelection(enabled: [.exteriorStatus, .tyreAndWarnings, .vehicleLocation])
        var composition = TabComposition()
        let defaultRows = VehicleTabView.cardRows(layout: .resolve(composition, for: .vehicle),
                                                 features: features, twoColumns: twoColumns)
        #expect(!defaultRows.flatMap { $0 }.contains(.vehicleTyres))

        composition.addItem(.vehicleTyres, to: .vehicle)
        let rows = VehicleTabView.cardRows(layout: .resolve(composition, for: .vehicle),
                                           features: features, twoColumns: twoColumns)
        let expected: [[TabItemID]] = twoColumns
            ? [[.vehicleOpenings], [.vehicleLocation, .vehicleTyres]]
            : [[.vehicleOpenings], [.vehicleLocation], [.vehicleTyres]]
        #expect(Array(rows.suffix(expected.count)) == expected)
    }

    @Test
    func nowPreservesTheConfiguredOrderAndHidesOnlyTheSelectedCard() {
        let features = FeatureSelection(enabled: [.exteriorStatus, .tyreAndWarnings, .vehicleLocation])
        var composition = TabComposition()
        composition.setItems([.vehicleLocation, .vehicleOpenings, .vehicleTyres], for: .vehicle)
        let ordered = VehicleTabView.cardRows(layout: .resolve(composition, for: .vehicle),
                                             features: features, twoColumns: true)
        #expect(ordered == [[.vehicleLocation], [.vehicleOpenings], [.vehicleTyres]])

        composition.setItem(.vehicleTyres, shown: false, on: .vehicle)
        let hidden = VehicleTabView.cardRows(layout: .resolve(composition, for: .vehicle),
                                            features: features, twoColumns: true)
        #expect(hidden == [[.vehicleLocation], [.vehicleOpenings]])

        composition.setItem(.vehicleTyres, shown: true, on: .vehicle)
        composition.setItems([.vehicleLocation, .vehicleTyres, .vehicleOpenings], for: .vehicle)
        let reversedPair = VehicleTabView.cardRows(layout: .resolve(composition, for: .vehicle),
                                                   features: features, twoColumns: true)
        #expect(reversedPair == [[.vehicleLocation, .vehicleTyres], [.vehicleOpenings]])
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

    // MARK: - Home charger

    @Test
    func theHomeChargerIsACardOfItsOwnOnNowAndPlan() {
        let item = TabItemCatalog.item(.vehicleHomeCharger)
        #expect(item?.isCard == true)
        #expect(TabItemCatalog.isStandalone(.vehicleHomeCharger))
        #expect(TabItemCatalog.portableCards.contains(.vehicleHomeCharger))
        let now = TabItemCatalog.defaultItems(for: .vehicle)
        #expect(now.firstIndex(of: .vehicleHomeCharger) == now.firstIndex(of: .vehicleCharging).map { $0 + 1 })
        let plan = TabItemCatalog.defaultItems(for: .controls)
        #expect(plan.firstIndex(of: .vehicleHomeCharger) == plan.firstIndex(of: .controlsCharging).map { $0 + 1 })
        #expect(TabItemCatalog.canRender(.vehicleHomeCharger, on: .info))
        #expect(TabItemCatalog.canRender(.vehicleHomeCharger, on: .custom("mine")))
    }

    @Test
    func theHomeChargerIsOnlyAvailableWithALogin() {
        #expect(TabItemAvailability.of(
            .vehicleHomeCharger, state: vehicle(), enabledFeatures: [], plannerAvailable: true
        ) == .notSignedIn)
        #expect(TabItemAvailability.of(
            .vehicleHomeCharger, state: nil, enabledFeatures: [], plannerAvailable: true
        ) == .notSignedIn)
        #expect(TabItemAvailability.of(
            .vehicleHomeCharger, state: vehicle(), enabledFeatures: [], plannerAvailable: true,
            homeChargerSignedIn: true
        ) == .drawable)
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
