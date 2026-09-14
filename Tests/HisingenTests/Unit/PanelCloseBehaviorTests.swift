import Foundation
import Testing
@testable import Hisingen

struct PanelCloseBehaviorTests {

    @Test @MainActor
    func defaultsToHistoricalKeepOpenBehavior() throws {
        // UUID-scoped domain + throwaway keychain service (TESTS-05): leftovers from an
        // earlier run must not be able to flip the default, and the suite must never read
        // the developer's real app keychain.
        let suite = "HisingenTests.panel-close.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        let store = PreferencesStore(defaults: defaults, keychain: keychain)

        // Upgrades must not change panel behavior for existing installs.
        #expect(store.panelCloseBehavior == .keepOpen)
        #expect(store.panelCloseBehavior.popoverBehavior == .semitransient)
    }

    @Test
    func focusLossOptionMapsToTransientPopoverBehavior() {
        #expect(PanelCloseBehavior.closeOnFocusLoss.popoverBehavior == .transient)
        #expect(PanelCloseBehavior(rawValue: "close-on-focus-loss") == .closeOnFocusLoss)
        #expect(PanelCloseBehavior(rawValue: "keep-open") == .keepOpen)
    }
}
