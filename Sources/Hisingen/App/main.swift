import AppKit

@MainActor
private func activateExistingInstanceIfNeeded() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let applications = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
        .filter { !$0.isTerminated }
    guard let owner = applications.min(by: { lhs, rhs in
        if let lhsDate = lhs.launchDate, let rhsDate = rhs.launchDate, lhsDate != rhsDate {
            return lhsDate < rhsDate
        }
        // A launch date can briefly be absent while LaunchServices registers a process.
        // PID ordering remains stable in every process's view of that same candidate set.
        return lhs.processIdentifier < rhs.processIdentifier
    }), owner.processIdentifier != currentPID else { return false }
    owner.activate()
    return true
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // Decide ownership before constructing AppDelegate: its stored properties open the local
    // SQLite database, so doing this in applicationDidFinishLaunching was too late to prevent
    // two nearly-simultaneous launches from touching shared state. Oldest launch wins; PID is
    // the deterministic tie-breaker, preventing both processes from yielding to each other.
    guard !activateExistingInstanceIfNeeded() else { return }
    let delegate = AppDelegate()
    app.delegate = delegate

    app.setActivationPolicy(.accessory)
    app.run()
}
