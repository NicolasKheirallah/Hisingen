import Testing
@testable import Hisingen

/// The declared rule, in one place: a catalogued card draws only when the reader has switched its
/// data on. Nothing here is about whether data has arrived yet — that stays with the cards.
@MainActor
struct CardAvailabilityTests {
    @Test func aCardDrawsWhenItsFeatureIsOn() {
        #expect(CardAvailability.of(.vehicleHero, enabledFeatures: [.vehicleImage]) == .drawable)
    }

    @Test func aCardDoesNotDrawWhenItsFeatureIsOff() {
        #expect(CardAvailability.of(.vehicleHero, enabledFeatures: []) == .switchedOff)
        #expect(CardAvailability.of(.vehicleHero, enabledFeatures: [.smartChargingPlanner]) == .switchedOff)
    }

    /// The live bug: a reader may place the planner on a tab of their own, and with the feature off
    /// the card was still built — so its `.task` still fetched spot prices for a feature that was
    /// switched off.
    @Test func theChargingPlannerIsNotDrawableWithItsFeatureOff() {
        #expect(CardAvailability.of(.vehicleChargingPlanner, enabledFeatures: []) == .switchedOff)
        #expect(CardAvailability.of(.vehicleChargingPlanner, enabledFeatures: [.vehicleImage]) == .switchedOff)
        #expect(CardAvailability.of(.vehicleChargingPlanner,
                                    enabledFeatures: [.smartChargingPlanner]) == .drawable)
    }

    /// An item with no declared feature draws on data the app always fetches, so there is nothing
    /// for the reader to have switched off.
    @Test func anItemWithNoDeclaredFeatureAlwaysDraws() {
        #expect(CardAvailability.of(.vehicleReceipts, enabledFeatures: []) == .drawable)
        #expect(CardAvailability.of(.vehicleReceipts, enabledFeatures: [.smartChargingPlanner]) == .drawable)
    }

    /// Every reusable card is catalogued, so every one of them gets a real answer rather than
    /// silently defaulting — the planner bug was a card that no gate ever looked at.
    @Test func everyReusableCardIsCatalogued() {
        for item in ComposableCards.reusable {
            #expect(TabItemCatalog.item(item) != nil, "\(item) is reusable but not catalogued")
        }
    }
}
