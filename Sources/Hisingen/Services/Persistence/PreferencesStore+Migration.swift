import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    func migrateLegacyPassword() { guard let legacy = d.string(forKey: "polestar_password"), !legacy.isEmpty else { return }; do { if try Keychain.readPassword() == nil { try Keychain.savePassword(legacy) }; d.removeObject(forKey: "polestar_password") } catch { logger.error("Legacy Polestar password migration to Keychain failed: \(String(describing: error), privacy: .public)") } }

    /// One-time carry-over of stored preferences from a previous bundle identifier.
    /// `UserDefaults.standard` is keyed on `CFBundleIdentifier`, so without this the feature
    /// selection, per-VIN nickname and theme maps, unit choices and notification tuning would
    /// all silently reset on the update that changes the identifier. Keychain credentials and
    /// the SQLite database live outside the defaults domain and are unaffected regardless.
    /// Existing keys are never overwritten, so running this after real use is a no-op.
    func migrateLegacyDefaults(domains: [String] = PreferencesStore.legacyDefaultsDomains) {
        let flagKey = "defaults_domain_migrated_v1"
        guard !d.bool(forKey: flagKey) else { return }
        for domain in domains where domain != Bundle.main.bundleIdentifier {
            guard let legacy = d.persistentDomain(forName: domain), !legacy.isEmpty else { continue }
            var carried = 0
            for (key, value) in legacy where d.object(forKey: key) == nil {
                d.set(value, forKey: key)
                carried += 1
            }
            if carried > 0 {
                logger.notice("Carried \(carried, privacy: .public) preference key(s) forward from \(domain, privacy: .public)")
            }
        }
        d.set(true, forKey: flagKey)
    }
}
