import Foundation
import OSLog
import SwiftUI

extension PreferencesStore {
    /// Set once the first successful sign-in's setup pass is finished (or skipped). The key
    /// deliberately stays out of the transferable settings set: an imported archive on a new
    /// Mac is a first run there and should see the pass.
    var hasCompletedSetupPass: Bool { get { d.bool(forKey: "setup_pass_completed") } set { d.set(newValue, forKey: "setup_pass_completed") } }

    /// Set once the first-launch "lives in your menu bar" card has had its moment – the user
    /// dismissed it or the first panel session ended. Also stays out of settings transfer.
    var hasSeenFirstLaunchWelcome: Bool { get { d.bool(forKey: "first_launch_welcome_seen") } set { d.set(newValue, forKey: "first_launch_welcome_seen") } }

    func markFirstLaunchWelcomeSeen() {
        guard !hasSeenFirstLaunchWelcome else { return }
        hasSeenFirstLaunchWelcome = true
    }

    /// An install that upgrades with session material already on the Keychain has been used
    /// before, so it counts as past the setup pass even though the flag was only introduced
    /// after that install's first sign-in. A fresh install has no session material and keeps
    /// the flag unset until its first sign-in's pass completes. The detection closure is
    /// injectable because the presence bits it reads by default are process-global, which
    /// makes the default untestable under Swift Testing's parallel execution.
    func seedSetupPassForExistingInstall(hasSessionMaterial: ((VehicleBrand) -> Bool)? = nil) {
        guard d.object(forKey: "setup_pass_completed") == nil else { return }
        let detect = hasSessionMaterial ?? { [self] in hasResumableSession(for: $0) }
        if VehicleBrand.allCases.contains(where: detect) {
            hasCompletedSetupPass = true
        }
    }
}
