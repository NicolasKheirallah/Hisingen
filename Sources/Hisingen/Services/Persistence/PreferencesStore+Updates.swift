import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    /// Update preferences are intentionally separate from vehicle notifications. The
    /// defaults follow macOS convention: check in the background, but do not download or
    /// install executable updates until the user asks Sparkle to do so.
    var automaticallyChecksForUpdates: Bool { get { boolDefaultTrue("automatically_check_for_updates") } set { d.set(newValue, forKey: "automatically_check_for_updates") } }
    var automaticallyDownloadsUpdates: Bool { get { d.bool(forKey: "automatically_download_updates") } set { d.set(newValue, forKey: "automatically_download_updates") } }
    /// Cadence of the automatic checks. Unknown stored values (a future version's case or
    /// hand-edited defaults) fall back to the historical daily interval instead of failing.
    var updateCheckInterval: UpdateCheckInterval { get { UpdateCheckInterval(rawValue: d.string(forKey: "update_check_interval") ?? "") ?? .daily } set { d.set(newValue.rawValue, forKey: "update_check_interval") } }
}
