import Foundation
import Testing
@testable import Hisingen

/// Pins the rule that decides whether Settings reaches the screen.
///
/// Settings is not a member of `visibleTabs()` — it is not a tab the reader composed, and
/// `BuiltInTab.isHideable` refuses to hide it either — so a resolver that consults only the
/// visible tabs cannot answer for it. That is how the footer gear came to do nothing: it selected
/// `.settings`, the resolver discarded the selection, and the panel drew the first ordinary tab.
@Suite("Tab routing")
struct TabRoutingTests {
    @Test func selectingSettingsDrawsSettings() {
        let composition = TabComposition.default
        #expect(TabRouting.resolve(composition: composition, selected: .settings) == .settings)
    }

    @Test func selectingASettingsTabIsNotDiscardedWhenTabsAreHidden() {
        var composition = TabComposition.default
        composition.hiddenTabs = [.vehicle, .info]
        #expect(TabRouting.resolve(composition: composition, selected: .settings) == .settings)
    }

    @Test func aVisibleSelectionIsHonoured() {
        let composition = TabComposition.default
        #expect(TabRouting.resolve(composition: composition, selected: .history) == .history)
    }

    @Test func aHiddenTabFallsBackToTheFirstVisibleOne() {
        var composition = TabComposition.default
        composition.hiddenTabs = [.vehicle]
        #expect(TabRouting.resolve(composition: composition, selected: .vehicle) == .info)
    }

    @Test func settingsIsNotListedAmongTheVisibleTabs() {
        // The premise the bug rests on. If this ever changes, the resolver can be simplified —
        // and this test is what will say so.
        #expect(!TabComposition.default.visibleTabs().contains(.settings))
    }

    @Test func settingsDrawsAsATabOnceThereIsABarToShow() {
        #expect(TabRouting.settingsDrawsAsTab(authenticated: true, hasSnapshot: true, setupMode: false))
    }

    @Test func settingsFillsThePanelBeforeThereIsATabBarOrSomewhereToGo() {
        // Signed out: the account form is the only way forward, and no bar exists to leave by.
        #expect(!TabRouting.settingsDrawsAsTab(authenticated: false, hasSnapshot: true, setupMode: false))
        // Signed in but with no snapshot yet.
        #expect(!TabRouting.settingsDrawsAsTab(authenticated: true, hasSnapshot: false, setupMode: false))
        // Mid setup pass: the pass owns the panel, not Settings.
        #expect(!TabRouting.settingsDrawsAsTab(authenticated: true, hasSnapshot: true, setupMode: true))
    }
}
