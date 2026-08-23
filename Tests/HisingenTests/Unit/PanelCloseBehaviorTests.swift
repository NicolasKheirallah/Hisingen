import Foundation
import Testing
@testable import Hisingen

struct PanelCloseBehaviorTests {

    @Test @MainActor
    func defaultsToHistoricalKeepOpenBehavior() {
        let store = PreferencesStore(defaults: UserDefaults(suiteName: "panel-close-behavior-tests")!, keychain: .app)
        defer { UserDefaults(suiteName: "panel-close-behavior-tests")!.removePersistentDomain(forName: "panel-close-behavior-tests") }

        // Upgrades must not change panel behavior for existing installs.
        XCTAssertEqual(store.panelCloseBehavior, .keepOpen)
        XCTAssertEqual(store.panelCloseBehavior.popoverBehavior, .semitransient)
    }

    @Test
    func focusLossOptionMapsToTransientPopoverBehavior() {
        XCTAssertEqual(PanelCloseBehavior.closeOnFocusLoss.popoverBehavior, .transient)
        XCTAssertEqual(PanelCloseBehavior(rawValue: "close-on-focus-loss"), .closeOnFocusLoss)
        XCTAssertEqual(PanelCloseBehavior(rawValue: "keep-open"), .keepOpen)
    }
}
