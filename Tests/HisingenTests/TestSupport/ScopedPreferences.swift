import Foundation
@testable import Hisingen

/// TESTS-06 discipline: every test that needs a `PreferencesStore` takes one backed by a
/// UUID-scoped UserDefaults domain that is removed when this holder deallocates, and a
/// throwaway KeychainStore service so no test ever reads (or migrates from) the real app
/// keychain. Keeping the domain cleanup inside `deinit` means no test can forget it.
@MainActor
final class ScopedPreferences {
    let store: PreferencesStore
    // `removePersistentDomain` is thread-safe; nonisolated(unsafe) exists only so `deinit`
    // (which cannot be isolated) can perform the guaranteed cleanup.
    nonisolated(unsafe) let defaults: UserDefaults
    private let suiteName: String

    init(label: String) {
        suiteName = "HisingenTests.\(label).\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        let keychain = KeychainStore(service: "io.kheirallah.hisingen.tests.\(UUID().uuidString)")
        store = PreferencesStore(defaults: defaults, keychain: keychain)
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }
}
