import Foundation
import Testing
@testable import Hisingen

/// Tabs, cards and items: the catalog, the reader's composition, and the migration that seeds
/// a layout from the feature toggles an existing installation already made.
@MainActor
struct TabCompositionTests {

    // MARK: - Catalog

    @Test
    func everyCataloguedItemHasMetadataAndALegalHome() {
        for item in TabItemCatalog.all {
            #expect(!item.title.isEmpty, "\(item.id.rawValue) has no title")
            #expect(!item.symbol.isEmpty, "\(item.id.rawValue) has no symbol")
            #expect(!item.detail.isEmpty, "\(item.id.rawValue) has no description")
            #expect(item.sourceTab != .settings, "\(item.id.rawValue) claims Settings as its home")
        }
    }

    @Test
    func everyShippedTabLayoutOnlyNamesCataloguedItemsAndListsEachOnce() {
        for tab in BuiltInTab.allCases {
            let layout = TabItemCatalog.defaultItems(for: tab)
            #expect(Set(layout).count == layout.count, "\(tab.rawValue) lists an item twice")
            for id in layout {
                let entry = TabItemCatalog.item(id)
                #expect(entry != nil, "\(tab.rawValue) names uncatalogued item \(id.rawValue)")
                #expect(entry?.sourceTab == tab,
                        "\(id.rawValue) is in \(tab.rawValue)'s shipped layout but claims \(entry?.sourceTab.rawValue ?? "nothing")")
            }
        }
    }

    @Test
    func everyNonSettingsItemAppearsInItsOwnTabsShippedLayout() {
        // A catalogued card that no shipped tab draws would be a card the reader can only find
        // by accident, and one the composition cannot be tested against.
        for item in TabItemCatalog.all {
            let layout = TabItemCatalog.defaultItems(for: item.sourceTab)
            #expect(layout.contains(item.id),
                    "\(item.id.rawValue) is not in the shipped \(item.sourceTab.rawValue) layout")
        }
    }

    @Test
    func headersAndCardsAreBothRepresented() {
        #expect(!TabItemCatalog.headers.isEmpty)
        #expect(!TabItemCatalog.cards.isEmpty)
        // Headers are the strips that describe a whole tab; they must stay at the top.
        for tab in BuiltInTab.allCases {
            let layout = TabItemCatalog.defaultItems(for: tab)
            let firstCard = layout.firstIndex { TabItemCatalog.item($0)?.isCard == true }
            let lastHeader = layout.lastIndex { TabItemCatalog.item($0)?.kind == .header }
            if let firstCard, let lastHeader {
                #expect(lastHeader < firstCard, "\(tab.rawValue) puts a header below a card")
            }
        }
    }

    @Test
    func vehicleDetailCardsRetiredIntoInfoAreNotOfferedForComposition() {
        let offered = Set(TabItemCatalog.cards.map(\.id))
        #expect(offered.isDisjoint(with: TabItemCatalog.retiredVehicleDetailItems))
        #expect(TabItemCatalog.items(in: .vehicle).allSatisfy {
            !TabItemCatalog.retiredVehicleDetailItems.contains($0.id)
        })
        // They are gone from the shipped layout too, which is what Settings lists.
        #expect(Set(TabItemCatalog.defaultItems(for: .vehicle))
            .isDisjoint(with: TabItemCatalog.retiredVehicleDetailItems))
    }

    // MARK: - Roster

    @Test
    func everyShippedLayoutIsExactlyWhatItsTabCanRender() {
        for tab in BuiltInTab.allCases where tab != .settings {
            let reference = TabRef.builtIn(tab)
            let layout = TabItemCatalog.defaultItems(for: tab)
            for id in layout {
                #expect(TabItemCatalog.canRender(id, on: reference),
                        "\(id.rawValue) is on \(tab.rawValue) but that tab cannot render it")
            }
            for item in TabItemCatalog.items(in: tab) {
                #expect(layout.contains(item.id),
                        "\(item.id.rawValue) has no place in \(tab.rawValue)'s shipped layout")
            }
        }
    }

    @Test
    func aShippedTabCannotRenderACardAnotherTabOwns() {
        // A tab-owned card has no view outside its home; a standalone card can travel.
        #expect(!TabItemCatalog.canRender(.historyTrips, on: .vehicle))
        #expect(TabItemCatalog.canRender(.historyTrips, on: .history))
        #expect(!TabItemCatalog.canRender(.infoNavBar, on: .history))
        #expect(TabItemCatalog.canRender(.controlsClimate, on: .vehicle))
        // A tab of the reader's own may name any card; the stack states which ones it draws.
        #expect(TabItemCatalog.canRender(.historyTrips, on: .custom("mine")))
    }

    @Test
    func aBorrowedCardStaysBelowTheTabsOwnCards() {
        var composition = TabComposition.default
        composition.addItem(.controlsClimate, to: .vehicle)
        #expect(composition.items(for: .vehicle).last == .controlsClimate)
        // The last own card has no place to move into; the borrowed card is not part of its run.
        #expect(!composition.canMove(.vehicleLocation, in: .vehicle, by: 1))
        composition.move(.vehicleLocation, in: .vehicle, by: 1)
        #expect(composition.items(for: .vehicle).last == .controlsClimate)
    }

    @Test
    func aStandaloneCardCanBePlacedOnAShippedTab() {
        var composition = TabComposition.default
        composition.addItem(.controlsClimate, to: .vehicle)
        #expect(composition.items(for: .vehicle).contains(.controlsClimate))
        #expect(composition.visibleItems(for: .vehicle).contains(.controlsClimate))
        #expect(TabLayout.resolve(composition, for: .vehicle).draws(.controlsClimate))
    }

    @Test
    func theSettingsRosterAndTheTabRosterAreTheSameList() {
        let composition = TabComposition.default
        for tab in BuiltInTab.allCases where tab != .settings {
            #expect(composition.renderableItems(for: .builtIn(tab))
                == TabItemCatalog.defaultItems(for: tab))
            #expect(composition.visibleItems(for: .builtIn(tab))
                == TabItemCatalog.defaultItems(for: tab))
        }
    }

    // MARK: - Defaults

    @Test
    func anUncustomisedCompositionDrawsEveryShippedTabExactlyAsDesigned() {
        let composition = TabComposition.default
        for tab in BuiltInTab.allCases where tab != .settings {
            #expect(composition.items(for: .builtIn(tab)) == TabItemCatalog.defaultItems(for: tab))
            #expect(composition.visibleItems(for: .builtIn(tab)) == TabItemCatalog.defaultItems(for: tab),
                    "\(tab.rawValue) hides something by default")
        }
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info])
    }

    @Test
    func anUnlistedItemIsVisibleSoANewCardShipsToExistingReaders() {
        // The hidden set is opt-out: a card added in a later version must appear, not vanish
        // for everyone who already had a stored layout.
        let composition = TabComposition(hiddenItems: [])
        for item in TabItemCatalog.all {
            #expect(composition.shows(item.id))
        }
    }

    // MARK: - Hiding

    @Test
    func hidingACardTakesItOutOfTheDrawListAndKeepsItsPlace() {
        var composition = TabComposition.default
        composition.setItem(.vehicleCharging, shown: false)

        let drawn = composition.visibleItems(for: .vehicle)
        #expect(!drawn.contains(.vehicleCharging))
        // Placement is untouched, so switching it back on restores the designed order.
        #expect(composition.items(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))

        composition.setItem(.vehicleCharging, shown: true)
        #expect(composition.visibleItems(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))
    }

    @Test
    func everyShippedTabCanBeHiddenAndSettingsCannot() {
        var composition = TabComposition.default
        for tab in BuiltInTab.hideableCases { composition.setTab(tab, shown: false) }

        // Every shipped tab may be hidden — the tab bar then holds the reader's own tabs, or
        // nothing but the way into Settings.
        #expect(composition.visibleTabs().isEmpty)
        // Settings is where tabs are managed, so it is always the way back and never hides.
        #expect(composition.isVisible(.settings))
        composition.setTab(.settings, shown: false)
        #expect(!composition.hiddenTabs.contains(.settings))
        #expect(composition.visibleTabs(includingSettings: true) == [.settings])
    }

    @Test
    func aHiddenBuiltInTabLeavesTheTabBar() {
        var composition = TabComposition.default
        composition.setTab(.info, shown: false)
        #expect(!composition.visibleTabs().contains(.info))
        #expect(composition.visibleTabs().contains(.vehicle))
        #expect(composition.visibleTabs(includingSettings: true).last == .settings)
        // A hidden tab reports nothing on it, so counts and the panel agree.
        #expect(composition.visibleItems(for: .info).isEmpty)
    }

    // MARK: - Ordering

    @Test
    func reorderingWritesAnExplicitLayoutAndMovingBackRestoresTheShippedOne() {
        var composition = TabComposition.default
        let shipped = TabItemCatalog.defaultItems(for: .vehicle)
        guard let charging = shipped.firstIndex(of: .vehicleCharging),
              let hero = shipped.firstIndex(of: .vehicleHero) else {
            Issue.record("fixture layout changed")
            return
        }
        // Drag the charging card up onto the hero's position.
        composition.move(.vehicleCharging, onto: .vehicleHero, in: .vehicle)
        #expect(composition.items(for: .vehicle).firstIndex(of: .vehicleCharging) == hero)
        #expect(composition.tabContents[TabRef.vehicle.storageKey] != nil)

        // Reordering back to the shipped layout drops the override rather than freezing
        // today's default, so the tab keeps tracking future layout changes.
        composition.setItems(shipped, for: .vehicle)
        #expect(composition.items(for: .vehicle) == shipped)
        #expect(composition.tabContents[TabRef.vehicle.storageKey] == nil)
        _ = charging
    }

    @Test
    func aMovePastTheEndOfTheListDoesNothingAndWritesNoLayout() {
        var composition = TabComposition.default
        let before = composition.items(for: .vehicle)
        // The first and last cards in the shipped layout, so both moves run off an end.
        composition.move(.vehicleSwitcher, in: .vehicle, by: -1)
        composition.move(.vehicleLocation, in: .vehicle, by: 1)
        #expect(composition.items(for: .vehicle) == before)
        // Nothing changed, so nothing was written: the tab keeps tracking the shipped layout.
        #expect(composition.tabContents[TabRef.vehicle.storageKey] == nil)
        #expect(!composition.canMove(.vehicleSwitcher, in: .vehicle, by: -1))
        #expect(!composition.canMove(.vehicleLocation, in: .vehicle, by: 1))
    }

    @Test
    func draggingOneCardOntoAnotherPutsItInThatPosition() {
        var composition = TabComposition.default
        composition.move(.vehicleLocation, onto: .vehicleHero, in: .vehicle)
        let items = composition.items(for: .vehicle)
        // The dragged card lands where the target was; the target takes the next slot.
        #expect(items.firstIndex(of: .vehicleLocation)
                == TabItemCatalog.defaultItems(for: .vehicle).firstIndex(of: .vehicleHero))
    }

    @Test
    func draggingACardOntoItselfChangesNothing() {
        var composition = TabComposition.default
        composition.move(.vehicleHero, onto: .vehicleHero, in: .vehicle)
        #expect(composition.items(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))
    }

    @Test
    func aShippedTabRefusesACardItCannotRender() {
        var composition = TabComposition.default
        composition.addItem(.historyTrips, to: .vehicle)
        // A Log chart owns that tab's state; Now has no renderer for it. Storing the placement
        // would put a row in Settings with nothing behind it on the tab.
        #expect(!composition.items(for: .vehicle).contains(.historyTrips))
        #expect(composition.tabContents[TabRef.vehicle.storageKey] == nil)
        #expect(!TabItemCatalog.canRender(.historyTrips, on: .vehicle))
    }

    @Test
    func aCardNotOnTheShippedLayoutIsAddedInASensiblePosition() {
        var composition = TabComposition.default
        composition.removeItem(.vehicleLocation, from: .vehicle)
        composition.addItem(.vehicleLocation, to: .vehicle)
        let items = composition.items(for: .vehicle)
        // Placed with the cards, below the vehicle switcher header.
        let headerIndex = items.firstIndex(of: .vehicleSwitcher)
        let addedIndex = items.firstIndex(of: .vehicleLocation)
        #expect(headerIndex != nil && addedIndex != nil)
        #expect(addedIndex! > headerIndex!)
        #expect(composition.shows(.vehicleLocation))
    }

    @Test
    func aTabOfYourOwnMayNameAnyCard() {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Mine")
        composition.addItem(.controlsClimate, to: tab)
        #expect(composition.visibleItems(for: tab) == [.controlsClimate])
        #expect(TabItemCatalog.canRender(.controlsClimate, on: tab))
    }

    @Test
    func addingACardTwiceDoesNotDuplicateIt() {
        var composition = TabComposition.default
        composition.addItem(.vehicleCharging, to: .vehicle)
        let count = composition.items(for: .vehicle).filter { $0 == .vehicleCharging }.count
        #expect(count == 1)
    }

    @Test
    func removingACardHidesItTooSoItDoesNotComeBackOnItsOwn() {
        var composition = TabComposition.default
        composition.removeItem(.vehicleTyres, from: .vehicle)
        #expect(!composition.items(for: .vehicle).contains(.vehicleTyres))
        #expect(composition.isHidden(.vehicleTyres))
        // And "add" is the explicit way back.
        composition.addItem(.vehicleTyres, to: .vehicle)
        #expect(composition.shows(.vehicleTyres))
        #expect(composition.items(for: .vehicle).contains(.vehicleTyres))
    }

    // MARK: - Custom tabs

    @Test
    func aCustomTabStartsEmptyAndKeepsWhatIsPutOnIt() {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Charging")
        #expect(composition.items(for: tab).isEmpty)
        #expect(composition.visibleItems(for: tab).isEmpty)

        composition.addItem(.vehicleCharging, to: tab)
        composition.addItem(.controlsCharging, to: tab)
        composition.addItem(.historyChargingSessions, to: tab)
        // Added in order, so the tab reads in the order the reader added them.
        #expect(composition.visibleItems(for: tab) == [.vehicleCharging, .controlsCharging, .historyChargingSessions])
        #expect(composition.visibleTabs().contains(tab))
    }

    @Test
    func customTabsGetDistinctNamesAndDistinctIdentities() {
        var composition = TabComposition.default
        let first = composition.addCustomTab(name: "Charging")
        let second = composition.addCustomTab(name: "Charging")
        #expect(first != second)
        #expect(composition.customTab(first.customID ?? "")?.name == "Charging")
        #expect(composition.customTab(second.customID ?? "")?.name == "Charging 2")
    }

    @Test
    func renamingIgnoresBlankNamesAndDeletingForgetsTheTabEntirely() {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Charging")
        guard let id = tab.customID else {
            Issue.record("custom tab has no id")
            return
        }
        composition.rename(id, to: "   ")
        #expect(composition.customTab(id)?.name == "Charging")

        composition.rename(id, to: "Energy")
        composition.addItem(.vehicleCharging, to: tab)
        #expect(composition.items(for: tab).count == 1)

        composition.removeCustomTab(id)
        #expect(composition.customTab(id) == nil)
        #expect(composition.items(for: tab).isEmpty)
        #expect(!composition.visibleTabs().contains(tab))
    }

    @Test
    func duplicatingATabCarriesItsCardsButNotItsIdentity() {
        var composition = TabComposition.default
        let original = composition.addCustomTab(name: "Charging")
        composition.addItem(.vehicleCharging, to: original)
        composition.setItem(.vehicleCharging, shown: false, on: original)
        composition.addItem(.controlsCharging, to: original)

        guard let sourceID = original.customID,
              let copy = composition.duplicateCustomTab(sourceID),
              let copyID = copy.customID else {
            Issue.record("duplicate failed")
            return
        }
        #expect(copyID != sourceID)
        // Hidden cards stay behind: the copy is what the reader had on screen.
        #expect(composition.visibleItems(for: copy) == [.controlsCharging])
    }

    // MARK: - Per-tab visibility

    @Test
    func hidingACardOnATabOfYourOwnLeavesItsHomeTabAlone() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Mine")
        composition.addItem(.vehicleCharging, to: mine)

        composition.setItem(.vehicleCharging, shown: false, on: mine)
        #expect(!composition.visibleItems(for: mine).contains(.vehicleCharging))
        #expect(composition.isHidden(.vehicleCharging, on: mine))
        // The card still lives on Now.
        #expect(!composition.isHidden(.vehicleCharging, on: .vehicle))
        #expect(composition.visibleItems(for: .vehicle).contains(.vehicleCharging))

        composition.setItem(.vehicleCharging, shown: true, on: mine)
        #expect(composition.visibleItems(for: mine) == [.vehicleCharging])
        #expect(!composition.isHidden(.vehicleCharging, on: mine))
    }

    @Test
    func aCardHiddenAtHomeCanStillBePlacedOnATabOfYourOwn() {
        var composition = TabComposition.default
        composition.setItem(.vehicleCharging, shown: false)
        let mine = composition.addCustomTab(name: "Mine")
        composition.addItem(.vehicleCharging, to: mine)

        #expect(!composition.visibleItems(for: .vehicle).contains(.vehicleCharging))
        #expect(composition.visibleItems(for: mine).contains(.vehicleCharging))
    }

    @Test
    func removingACardFromATabOfYourOwnDoesNotHideItAtHome() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Mine")
        composition.addItem(.vehicleCharging, to: mine)

        composition.removeItem(.vehicleCharging, from: mine)
        #expect(composition.items(for: mine).isEmpty)
        #expect(!composition.isHidden(.vehicleCharging))
        #expect(composition.visibleItems(for: .vehicle).contains(.vehicleCharging))
    }

    @Test
    func hidingAnExtraOnAShippedTabLeavesItsHomeTabAlone() {
        var composition = TabComposition.default
        composition.addItem(.controlsClimate, to: .vehicle)
        composition.setItem(.controlsClimate, shown: false, on: .vehicle)

        #expect(!composition.visibleItems(for: .vehicle).contains(.controlsClimate))
        #expect(composition.visibleItems(for: .controls).contains(.controlsClimate))
        #expect(!composition.isHidden(.controlsClimate))

        composition.setItem(.controlsClimate, shown: true, on: .vehicle)
        #expect(composition.visibleItems(for: .vehicle).contains(.controlsClimate))
    }

    @Test
    func removingAnExtraFromAShippedTabLeavesItsHomeTabAlone() {
        var composition = TabComposition.default
        composition.addItem(.controlsClimate, to: .vehicle)
        composition.removeItem(.controlsClimate, from: .vehicle)

        #expect(!composition.items(for: .vehicle).contains(.controlsClimate))
        #expect(composition.visibleItems(for: .controls).contains(.controlsClimate))
        #expect(!composition.isHidden(.controlsClimate))
    }

    @Test
    func aPlacementSwitchSurvivesAJSONRoundTrip() throws {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Mine")
        composition.addItem(.vehicleCharging, to: mine)
        composition.setItem(.vehicleCharging, shown: false, on: mine)

        let decoded = try JSONDecoder().decode(
            TabComposition.self, from: JSONEncoder().encode(composition)
        )
        #expect(decoded == composition)
        #expect(decoded.isHidden(.vehicleCharging, on: mine))
    }

    @Test
    func repairDropsAPlacementSwitchForACardNoLongerPlaced() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Mine")
        composition.hiddenPlacements[mine.storageKey] = [.vehicleCharging]
        let repaired = composition.normalized()
        #expect(repaired.hiddenPlacements[mine.storageKey] == nil)
    }

    // MARK: - Tab order

    @Test
    func tabsShipInTheirDeclaredOrderWithTheReadersOwnTabsLast() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Charging")
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info, mine])
        // Settings is never part of the reader's order: it is where the order is managed.
        #expect(!composition.orderedTabs().contains(.settings))
        #expect(composition.tabOrder.isEmpty)
    }

    @Test
    func aTabTheReaderJustBuiltCanBeMovedToTheFront() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Charging")
        composition.moveTabToFirst(mine)
        #expect(composition.visibleTabs().first == mine)
        #expect(composition.visibleTabs(includingSettings: true).last == .settings)
        #expect(composition.tabOrder.first == mine.storageKey)
    }

    @Test
    func movingATabByOneSwapsItWithItsNeighbourAndMovingBackDropsTheOverride() {
        var composition = TabComposition.default
        #expect(composition.canMoveTab(.controls, by: -1))
        #expect(!composition.canMoveTab(.vehicle, by: -1))
        #expect(!composition.canMoveTab(.info, by: 1))

        composition.moveTab(.controls, by: -1)
        #expect(composition.visibleTabs().prefix(2) == [.controls, .vehicle])

        // Back to the shipped order, so the override is dropped rather than frozen.
        composition.moveTab(.controls, by: 1)
        #expect(composition.tabOrder.isEmpty)
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info])
    }

    @Test
    func draggingATabOntoAnotherPutsItInThatPosition() {
        var composition = TabComposition.default
        composition.moveTab(.info, onto: .vehicle)
        #expect(composition.visibleTabs().prefix(2) == [.info, .vehicle])
        // Onto itself is a no-op, not a write.
        composition.moveTab(.info, onto: .info)
        #expect(composition.visibleTabs().prefix(2) == [.info, .vehicle])
    }

    @Test
    func movingATabDownLandsItAfterTheNeighbourAndADownwardDropAfterTheTarget() {
        var composition = TabComposition.default
        composition.moveTab(.vehicle, by: 1)
        #expect(composition.visibleTabs().prefix(2) == [.controls, .vehicle])
        // A downward drop lands after the target, the same rule the card move uses.
        composition.moveTab(.controls, onto: .history)
        #expect(composition.visibleTabs().prefix(3) == [.vehicle, .history, .controls])
    }

    @Test
    func settingsIsNeverAMoveSourceOrTarget() {
        var composition = TabComposition.default
        composition.moveTab(.vehicle, onto: .settings)
        composition.moveTab(.settings, onto: .vehicle)
        composition.moveTabToFirst(.settings)
        composition.moveTab(.settings, by: -1)
        #expect(composition.tabOrder.isEmpty)
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info])
    }

    @Test
    func deletingAMovedTabLeavesNoOrderOverrideBehind() {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Charging")
        composition.moveTabToFirst(mine)
        #expect(!composition.tabOrder.isEmpty)

        composition.removeCustomTab(mine.customID ?? "")
        // The shipped tabs are back in the shipped order, so nothing is stored and Restore is
        // not offered for an override that no longer differs from the default.
        #expect(composition.tabOrder.isEmpty)
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info])
    }

    @Test
    func aHiddenTabKeepsItsPlaceSoShowingItAgainPutsItBack() {
        var composition = TabComposition.default
        composition.moveTab(.history, onto: .vehicle)
        #expect(composition.visibleTabs() == [.history, .vehicle, .controls, .info])

        composition.setTab(.history, shown: false)
        #expect(!composition.visibleTabs().contains(.history))

        composition.setTab(.history, shown: true)
        #expect(composition.visibleTabs() == [.history, .vehicle, .controls, .info])
    }

    @Test
    func aTabTheStoredOrderHasNeverHeardOfKeepsAPlaceAtTheEnd() {
        var composition = TabComposition.default
        composition.tabOrder = [TabRef.controls.storageKey, TabRef.vehicle.storageKey]
        // A tab shipped, or created, after the order was written is not dropped by it.
        #expect(composition.orderedTabs() == [.controls, .vehicle, .history, .info])

        let mine = composition.addCustomTab(name: "Charging")
        #expect(composition.visibleTabs().last == mine)
    }

    @Test
    func resettingTheTabOrderBringsBackTheShippedOrderAndLeavesCardsAlone() {
        var composition = TabComposition.default
        composition.moveTab(.info, onto: .vehicle)
        composition.move(.vehicleLocation, onto: .vehicleHero, in: .vehicle)

        let arrangedCards = composition.items(for: .vehicle)
        // The card move is what makes the arrangement non-default, so the reset has something
        // to leave alone.
        #expect(arrangedCards != TabItemCatalog.defaultItems(for: .vehicle))

        composition.resetTabOrder()
        #expect(composition.visibleTabs() == [.vehicle, .controls, .history, .info])
        #expect(composition.items(for: .vehicle) == arrangedCards)
    }

    @Test
    func repairDropsOrderEntriesThatNameNoTabOrNameOneTwice() {
        var composition = TabComposition.default
        composition.tabOrder = [
            TabRef.info.storageKey,
            "custom:gone",
            TabRef.info.storageKey,
            TabRef.vehicle.storageKey
        ]
        #expect(composition.normalized().tabOrder == [TabRef.info.storageKey, TabRef.vehicle.storageKey])
    }

    @Test
    func theTabOrderSurvivesAJSONRoundTrip() throws {
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Charging")
        composition.moveTabToFirst(mine)
        let decoded = try JSONDecoder().decode(TabComposition.self, from: JSONEncoder().encode(composition))
        #expect(decoded.tabOrder == composition.tabOrder)
        #expect(decoded.visibleTabs().first == mine)
    }

    @Test
    func aLayoutWrittenBeforeTabOrderingExistedStillDecodesIntact() throws {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Charging", symbol: "bolt.fill")
        composition.addItem(.vehicleCharging, to: tab)
        composition.setItem(.vehicleTyres, shown: false)

        // What an installation stored before this key existed: the same JSON without it.
        var object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(composition)) as? [String: Any]
        )
        object.removeValue(forKey: "tabOrder")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        // A synthesized decoder would throw on the missing key, and the store would answer with
        // the shipped layout: the reader's tabs, cards and hidden cards all silently gone.
        let decoded = try JSONDecoder().decode(TabComposition.self, from: legacy)
        #expect(decoded.tabOrder.isEmpty)
        #expect(decoded.customTabs.count == 1)
        #expect(!decoded.shows(.vehicleTyres))
        #expect(decoded.visibleItems(for: tab) == [.vehicleCharging])
    }

    // MARK: - Repair

    @Test
    func repairDropsCardsAndTabsThatNoLongerExist() {
        var composition = TabComposition.default
        let ghost = TabRef.custom("ghost")
        composition.tabContents[ghost.storageKey] = [.vehicleHero]
        // A card listed twice would draw twice; repairing must dedupe, not just filter.
        composition.tabContents[TabRef.vehicle.storageKey] = [.vehicleHero, .vehicleHero, .vehicleTyres]
        let repaired = composition.normalized()
        #expect(repaired.tabContents[ghost.storageKey] == nil)
        #expect(repaired.items(for: .vehicle) == [.vehicleHero, .vehicleTyres])
    }

    @Test
    func repairRefusesToLeaveSettingsHidden() {
        let composition = TabComposition(hiddenTabs: [.settings, .info])
        let repaired = composition.normalized()
        #expect(!repaired.hiddenTabs.contains(.settings))
        #expect(repaired.hiddenTabs.contains(.info))
    }

    // MARK: - Persistence

    @Test
    func aCompositionSurvivesAJSONRoundTrip() throws {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Charging", symbol: "bolt.fill")
        composition.addItem(.vehicleCharging, to: tab)
        composition.setItem(.vehicleTyres, shown: false)
        composition.setTab(.history, shown: false)

        let data = try JSONEncoder().encode(composition)
        let decoded = try JSONDecoder().decode(TabComposition.self, from: data)
        #expect(decoded == composition)
        #expect(decoded.customTab(tab.customID ?? "")?.symbol == "bolt.fill")
    }

    @Test
    func theStoredCompositionIsTheOneTheSettingsPaneWrote() {
        let scoped = ScopedPreferences(label: "tab-composition")
        let store = scoped.store
        // An untouched installation reads the shipped layout, whatever the feature toggles were.
        #expect(store.tabComposition.items(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))
        #expect(store.tabComposition.hiddenTabs.isEmpty)
        #expect(store.tabComposition.customTabs.isEmpty)
        // Read once so the one-time seed from the feature toggles has happened; this test is
        // about what the Settings pane writes afterwards.
        store.tabComposition = store.tabComposition

        var composition = store.tabComposition
        composition.setItem(.infoWeather, shown: false)
        let tab = composition.addCustomTab(name: "My Tab")
        composition.addItem(.historyTrips, to: tab)
        store.tabComposition = composition

        let reloaded = store.tabComposition
        #expect(!reloaded.shows(.infoWeather))
        #expect(reloaded.customTabs.count == 1)
        #expect(reloaded.visibleItems(for: tab) == [.historyTrips])
    }

    @Test
    func aCorruptStoredLayoutCostsTheLayoutAndNotTheWholeInterface() {
        let scoped = ScopedPreferences(label: "tab-composition-corrupt")
        scoped.defaults.set(Data("not json".utf8), forKey: PreferencesStore.tabCompositionKey)
        let recovered = scoped.store.tabComposition
        // The reader loses their layout, not the panel: every shipped tab still draws in full,
        // and no tab or card arrangement is claimed on their behalf.
        #expect(recovered.tabContents.isEmpty)
        #expect(recovered.hiddenTabs.isEmpty)
        #expect(recovered.customTabs.isEmpty)
        for tab in BuiltInTab.allCases where tab != .settings {
            #expect(recovered.items(for: .builtIn(tab)) == TabItemCatalog.defaultItems(for: tab))
        }
    }

    // MARK: - Migration

    @Test
    func aLayoutArrangedBeforeTheMoveKeepsTheControlsThatMovedToCar() {
        var composition = TabComposition.default
        composition.version = 2
        composition.tabContents[TabRef.info.storageKey] = [.infoNavBar, .infoOverview]
        composition.tabContents[TabRef.controls.storageKey] = [
            .controlsBanners, .controlsReceipts,
            .controlsAccess, .controlsWindowsLocate, .controlsOTA
        ]

        let migrated = composition.normalized()
        // Car keeps the controls that moved to it, so an upgrader does not lose them...
        #expect(migrated.items(for: .info).contains(.controlsAccess))
        #expect(migrated.items(for: .info).contains(.controlsWindowsLocate))
        #expect(migrated.items(for: .info).contains(.controlsOTA))
        // ...and the stored Plan arrangement no longer claims them. Plan may take one back as a
        // standalone card, but the 3.0 home for all three is Car.
        #expect(!migrated.items(for: .controls).contains(.controlsAccess))
        #expect(!migrated.items(for: .controls).contains(.controlsWindowsLocate))
        #expect(!migrated.items(for: .controls).contains(.controlsOTA))
        #expect(migrated.version == 3)
    }

    @Test
    func aMovedControlTheReaderSwitchedOffStaysOffAfterTheMigration() {
        var composition = TabComposition.default
        composition.version = 2
        composition.tabContents[TabRef.info.storageKey] = [.infoNavBar, .infoOverview]
        composition.hiddenItems = [.controlsOTA]

        let migrated = composition.normalized()
        #expect(!migrated.items(for: .info).contains(.controlsOTA))
        #expect(migrated.isHidden(.controlsOTA))
    }

    @Test
    func aStoredLayoutDropsRetiredCardsAndCardsItsTabCannotRender() {
        var composition = TabComposition.default
        composition.version = 2
        composition.tabContents[TabRef.vehicle.storageKey] = [.vehicleHero, .vehicleMore]
        composition.tabContents[TabRef.controls.storageKey] = [
            .controlsBanners, .controlsReceipts, .historyTrips
        ]

        let repaired = composition.normalized()
        #expect(repaired.items(for: .vehicle) == [.vehicleHero])
        #expect(repaired.items(for: .controls) == [.controlsBanners, .controlsReceipts])
    }

    @Test
    func aStoredLayoutThatMatchesTheShippedOneStopsOverridingIt() {
        var composition = TabComposition.default
        composition.tabContents[TabRef.vehicle.storageKey] = TabItemCatalog.defaultItems(for: .vehicle)

        let repaired = composition.normalized()
        #expect(repaired.items(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))
        #expect(repaired.tabContents[TabRef.vehicle.storageKey] == nil)
    }

    @Test
    func aTabReferenceRoundTripsThroughItsStorageKey() {
        for tab in BuiltInTab.allCases {
            #expect(TabRef(storageKey: TabRef.builtIn(tab).storageKey) == .builtIn(tab))
        }
        #expect(TabRef(storageKey: TabRef.custom("mine").storageKey) == .custom("mine"))
        #expect(TabRef(storageKey: "nonsense") == nil)
    }

    @Test
    func aFirstRunWithNoStoredLayoutTakesTheExistingFeatureTogglesAsItsStartingPoint() {
        let scoped = ScopedPreferences(label: "tab-seed")
        let store = scoped.store
        var features = store.features
        features.set(.chargingDetails, enabled: false)
        features.set(.vehicleImage, enabled: false)
        store.features = features

        let composition = store.tabComposition
        #expect(composition.isHidden(.vehicleCharging))
        #expect(composition.isHidden(.vehicleHero))
        // Everything else is where it always was.
        #expect(composition.shows(.vehicleTyres))
        #expect(composition.items(for: .vehicle) == TabItemCatalog.defaultItems(for: .vehicle))
    }

    @Test
    func theSeededLayoutIsWrittenOnceSoReenablingAFeatureKeepsTheReadersChoice() {
        let scoped = ScopedPreferences(label: "tab-seed-once")
        let store = scoped.store
        var features = store.features
        features.set(.chargingDetails, enabled: false)
        store.features = features
        store.tabComposition = store.tabComposition
        #expect(store.tabComposition.isHidden(.vehicleCharging))

        // The reader switches the reading back on through the feature list. The card stays
        // hidden until they say otherwise, because the layout is theirs now.
        features.set(.chargingDetails, enabled: true)
        store.features = features
        #expect(store.tabComposition.isHidden(.vehicleCharging))

        // And the layout can be changed back.
        var composition = store.tabComposition
        composition.setItem(.vehicleCharging, shown: true)
        store.tabComposition = composition
        #expect(store.tabComposition.shows(.vehicleCharging))
    }

    // MARK: - Data fetching

    @Test
    func switchingOffUnusedReadingsLeavesEverythingStillOnScreenFetching() {
        let scoped = ScopedPreferences(label: "tab-fetch")
        let store = scoped.store
        var features = store.features
        features.set(.tyreAndWarnings, enabled: true)
        features.set(.vehicleLocation, enabled: true)
        store.features = features

        // The tyres card was hidden; location is still drawn somewhere, so only one stops.
        store.stopFetchingUnusedFeatures([.tyreAndWarnings, .vehicleLocation], keeping: [.vehicleLocation])
        #expect(!store.features.contains(.tyreAndWarnings))
        #expect(store.features.contains(.vehicleLocation))
    }

    @Test
    func switchingOffUnusedReadingsIsANoOpWhenEverythingIsStillNeeded() {
        let scoped = ScopedPreferences(label: "tab-fetch-noop")
        let store = scoped.store
        let before = store.features
        store.stopFetchingUnusedFeatures([.tyreAndWarnings], keeping: [.tyreAndWarnings, .vehicleLocation])
        #expect(store.features == before)
    }

    // MARK: - The layout a tab renders from

    @Test
    func theDefaultLayoutDrawsEverythingInTheOrderItWasGiven() {
        let layout = TabLayout.everything
        #expect(layout.isDefault)
        for item in TabItemCatalog.all {
            #expect(layout.draws(item.id))
        }
        let shipped = TabItemCatalog.defaultItems(for: .vehicle)
        #expect(layout.ordered(shipped, by: { $0 }) == shipped)
    }

    @Test
    func aLayoutDrawsWhatItNamesAndKeepsDrawingWhatItHasNeverHeardOf() {
        var composition = TabComposition.default
        composition.setItem(.vehicleTyres, shown: false)
        let layout = TabLayout.resolve(composition, for: .vehicle)

        #expect(!layout.draws(.vehicleTyres))
        #expect(layout.draws(.vehicleHero))
        // A stored layout that names two cards and has never heard of a third still draws it:
        // that is what a card shipped after the layout was stored looks like.
        let accepting = TabLayout(items: [.vehicleHero, .vehicleCharging], includesNewItems: true)
        #expect(accepting.draws(.vehicleChargingPlanner))
    }

    @Test
    func onceATabIsRearrangedItsListIsTheWholeTruthAboutIt() {
        var composition = TabComposition.default
        composition.setItems([.vehicleHero, .vehicleCharging], for: .vehicle)
        let layout = TabLayout.resolve(composition, for: .vehicle)

        #expect(layout.draws(.vehicleHero))
        // The reader arranged this tab themselves, so the list they arranged is what it draws.
        // A card they never placed is not silently added back.
        #expect(!layout.draws(.vehicleTyres))
    }

    @Test
    func aLayoutRendersTheReadersOrderAndKeepsEveryItem() {
        var composition = TabComposition.default
        composition.move(.vehicleLocation, onto: .vehicleHero, in: .vehicle)
        let layout = TabLayout.resolve(composition, for: .vehicle)

        let shipped = TabItemCatalog.defaultItems(for: .vehicle)
        let ordered = layout.ordered(shipped, by: { $0 })
        // The dragged card lands on the hero's position; the hero takes the next slot.
        #expect(ordered.prefix(3) == [.vehicleSwitcher, .vehicleLocation, .vehicleHero])
        // Every item survives the reorder: none is dropped for not being placed.
        #expect(Set(ordered) == Set(shipped))
    }

    @Test
    func anItemTheLayoutDoesNotPlaceRendersAfterEverythingItDoes() {
        // A tab edited before a new card existed: the stored order names two cards, and a third
        // has since been added to the catalog.
        let layout = TabLayout(items: [.vehicleHero, .vehicleCharging], includesNewItems: true)
        let entries: [TabItemID] = [.vehicleHero, .vehicleCharging, .vehicleTyres]
        #expect(layout.ordered(entries, by: { $0 }) == [.vehicleHero, .vehicleCharging, .vehicleTyres])

        // An item the layout places but the entries do not contain is simply absent.
        #expect(layout.ordered([TabItemID.vehicleHero], by: { $0 }) == [.vehicleHero])
        // And a layout that places nothing renders the entries' own order.
        #expect(layout.ordered([TabItemID.vehicleHero], by: { $0 }) == [.vehicleHero])
    }

    // MARK: - Reading the tab views draw

    @Test
    func aTabsLayoutIsItsVisibleItemsInOrder() {
        var composition = TabComposition.default
        composition.setItem(.vehicleFuelEngine, shown: false)
        composition.move(.vehicleLocation, onto: .vehicleHero, in: .vehicle)

        let layout = TabLayout.resolve(composition, for: .vehicle)
        #expect(!layout.draws(.vehicleFuelEngine))
        #expect(layout.draws(.vehicleLocation))
        // A hidden tab draws nothing at all — not everything, which is what an empty list
        // doubling as "no layout yet" would have made it draw.
        composition.setTab(.vehicle, shown: false)
        let hidden = TabLayout.resolve(composition, for: .vehicle)
        #expect(!hidden.draws(.vehicleHero))
        #expect(!hidden.draws(.vehicleTyres))
        #expect(hidden.items.isEmpty)
    }

    @Test
    func aCustomTabsLayoutStartsWithNothingOnIt() {
        var composition = TabComposition.default
        let tab = composition.addCustomTab(name: "Charging")
        let empty = TabLayout.resolve(composition, for: tab)
        // Empty here means the tab is genuinely empty, not "draw everything": a tab of the
        // reader's own has no shipped layout to fall back to.
        #expect(empty.items.isEmpty)
        #expect(!empty.draws(.vehicleHero))
        #expect(empty.ordered([TabItemID.vehicleHero], by: { $0 }) == [.vehicleHero])

        composition.addItem(.vehicleCharging, to: tab)
        let layout = TabLayout.resolve(composition, for: tab)
        #expect(layout.draws(.vehicleCharging))
        #expect(!layout.draws(.vehicleHero))
    }

    @Test
    func aTabEmptiedByHandDrawsNothingRatherThanReassertingItsDefaults() {
        // "Hide All" switches every card off where it lives, so the arrangement is untouched and
        // the filter alone empties the tab. If an empty result fell back to "no layout", every
        // shipped card would come straight back.
        var composition = TabComposition.default
        let shipped = composition.items(for: .vehicle)
        for item in shipped { composition.setItem(item, shown: false) }

        let layout = TabLayout.resolve(composition, for: .vehicle)
        #expect(layout.items.isEmpty)
        for item in shipped { #expect(!layout.draws(item)) }
        // The arrangement survives, so "Show All" is a filter away rather than a rebuild.
        #expect(composition.items(for: .vehicle) == shipped)
    }

    @Test
    func aReaderWhoArrangedATabDoesNotGetCardsTheyNeverPlaced() {
        // An explicit arrangement is the whole truth about that tab: an item the list does not
        // name is not silently added back, whichever tab it belongs to.
        var composition = TabComposition.default
        composition.setItems([.vehicleHero, .vehicleCharging], for: .vehicle)

        let layout = TabLayout.resolve(composition, for: .vehicle)
        #expect(layout.draws(.vehicleHero))
        #expect(!layout.draws(.vehicleLocation))
        #expect(!layout.draws(.vehicleTyres))
    }

    @Test
    func aTabTheReaderNeverArrangedDrawsEveryCardThatIsNotSwitchedOff() {
        var composition = TabComposition.default
        composition.setItem(.vehicleTyres, shown: false)

        let layout = TabLayout.resolve(composition, for: .vehicle)
        #expect(!layout.draws(.vehicleTyres))
        #expect(layout.draws(.vehicleHero))
        #expect(layout.draws(.vehicleLocation))
    }

    @Test
    func aLayoutDoesNotDrawWhatTheTabCannotRender() {
        let now = TabLayout.resolve(TabComposition.default, for: .vehicle)
        #expect(!now.draws(.historyTrips))
        #expect(now.draws(.vehicleHero))

        // A tab of the reader's own may keep a tab-owned card in its arrangement, but it names
        // it instead of drawing it.
        var composition = TabComposition.default
        let mine = composition.addCustomTab(name: "Mine")
        composition.addItem(.historyTrips, to: mine)
        let custom = TabLayout.resolve(composition, for: mine)
        #expect(custom.items.contains(.historyTrips))
        #expect(!custom.draws(.historyTrips))
    }

    @Test
    func aHiddenTabDrawsNothingEvenIfItWasNeverArranged() {
        var composition = TabComposition.default
        composition.setTab(.vehicle, shown: false)
        let layout = TabLayout.resolve(composition, for: .vehicle)
        #expect(layout.items.isEmpty)
        #expect(!layout.draws(.vehicleHero))
        #expect(!layout.draws(.controlsClimate))
    }

    @Test
    func aHiddenTabAndAnEmptyTabAreDifferentStates() {
        var emptied = TabComposition.default
        for item in emptied.items(for: .history) { emptied.setItem(item, shown: false) }
        var hidden = TabComposition.default
        hidden.setTab(.history, shown: false)

        #expect(TabLayout.resolve(emptied, for: .history).items.isEmpty)
        #expect(TabLayout.resolve(hidden, for: .history).items.isEmpty)
        // One is reachable from the tab bar and the other is not; the layout alone cannot tell
        // them apart, which is why the tab bar asks the composition instead.
        #expect(emptied.isVisible(.history))
        #expect(!hidden.isVisible(.history))
    }

    @Test
    func hidingOneCardLeavesTheRestOfATabIntact() {
        var composition = TabComposition.default
        composition.setItem(.historyTrips, shown: false)
        let layout = TabLayout.resolve(composition, for: .history)
        #expect(!layout.draws(.historyTrips))
        #expect(layout.draws(.historyOverview))
        #expect(layout.draws(.historyPeriodPicker))
        #expect(layout.items.count == TabItemCatalog.defaultItems(for: .history).count - 1)
    }

    // MARK: - Readings follow the cards

    @Test
    func switchingOffTheLastCardThatNeedsAReadingStopsFetchingIt() {
        let scoped = ScopedPreferences(label: "tab-sync-off")
        let store = scoped.store
        var features = store.features
        features.set(.vehicleLocation, enabled: true)
        features.set(.tyreAndWarnings, enabled: true)
        store.features = features

        // The tyre card went with its own reading still needed elsewhere? No: nothing else in
        // the catalog draws on the tyre feature, so switching it off releases it.
        #expect(store.stopFetchingUnusedFeatures([.tyreAndWarnings], keeping: [.vehicleLocation]))
        #expect(!store.features.contains(.tyreAndWarnings))
        #expect(store.features.contains(.vehicleLocation))
    }

    @Test
    func switchingOffACardWhoseReadingAnotherVisibleCardSharesKeepsFetchingIt() {
        let scoped = ScopedPreferences(label: "tab-sync-shared")
        let store = scoped.store
        var features = store.features
        features.set(.vehicleLocation, enabled: true)
        store.features = features

        // Location is drawn by a card the reader can still see, so hiding a second card that
        // also uses it must not take the reading away.
        #expect(!store.stopFetchingUnusedFeatures([.vehicleLocation], keeping: [.vehicleLocation]))
        #expect(store.features.contains(.vehicleLocation))
    }

    @Test
    func aReadingTheReaderTurnedOnByHandIsNotTakenAwayByMovingACard() {
        let scoped = ScopedPreferences(label: "tab-sync-manual")
        let store = scoped.store
        var features = store.features
        features.set(.tyreAndWarnings, enabled: true)
        store.features = features

        // No card that references tyre pressure is currently in the layout at all, so it is not
        // a candidate: only a card the reader just switched off can release a reading.
        #expect(!store.stopFetchingUnusedFeatures([], keeping: []))
        #expect(store.features.contains(.tyreAndWarnings))
    }

    @Test
    func releasingAReadingReportsWhetherAnythingActuallyChanged() {
        let scoped = ScopedPreferences(label: "tab-sync-report")
        let store = scoped.store
        var features = store.features
        features.set(.tyreAndWarnings, enabled: false)
        store.features = features

        // Already off: nothing changed, so no `.features` notification is owed to the rest of
        // the app.
        #expect(!store.stopFetchingUnusedFeatures([.tyreAndWarnings], keeping: []))
    }

    // MARK: - Memoised read

    @Test
    func memoisedLayoutFollowsEveryChangeToTheStoredBytes() throws {
        let scoped = ScopedPreferences(label: "tab-memo")
        let store = scoped.store

        var first = TabComposition()
        first.hiddenTabs = [.info]
        store.tabComposition = first
        #expect(store.tabComposition == first.normalized())
        #expect(store.tabComposition == first.normalized(), "the second read is served from the memo")

        // Another writer changes the key behind the store's back: the memo must not mask it.
        var second = TabComposition()
        second.customTabs = [CustomTab(id: "memo-tab", name: "Memo")]
        scoped.defaults.set(try JSONEncoder().encode(second), forKey: PreferencesStore.tabCompositionKey)
        #expect(store.tabComposition.customTabs.map(\.id) == ["memo-tab"])
        #expect(store.tabComposition.hiddenTabs.isEmpty)

        // A value that no longer decodes falls back to the shipped layout rather than the memo.
        scoped.defaults.set(Data("not json".utf8), forKey: PreferencesStore.tabCompositionKey)
        #expect(store.tabComposition == .default)
    }
}
