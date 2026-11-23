import SwiftUI

private struct HistoryWorkspaceKey: EnvironmentKey {
    static let defaultValue: HistoryWorkspace? = nil
}

extension EnvironmentValues {
    /// The panel's history seam, for a surface far from the tabs that still reads recorded trips.
    /// Nil where nothing injected it, such as a preview, and such a surface simply shows less.
    var historyWorkspace: HistoryWorkspace? {
        get { self[HistoryWorkspaceKey.self] }
        set { self[HistoryWorkspaceKey.self] = newValue }
    }
}
