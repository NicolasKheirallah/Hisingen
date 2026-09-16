import Foundation

/// Which tab a panel draws, given the reader's composition and what they selected.
///
/// This is a module rather than a private computed property on the view because it is the one
/// rule that decides whether Settings is on screen, and nothing could test it where it lived.
/// Settings is deliberately not part of the reader's composition — `visibleTabs()` excludes it,
/// and `BuiltInTab.isHideable` refuses to hide it — so a resolver that consults only the visible
/// tabs has no answer for `.settings` and returns the first ordinary tab instead.
enum TabRouting {
    /// The tab to draw. A selected tab the reader can actually see is honoured; anything else
    /// falls back to the first visible tab, or the dashboard when there is nothing to show.
    ///
    /// Settings is answered before that check, because the check cannot see it: it is not part of
    /// the reader's composition, so `visibleTabs()` never lists it, and it is not hideable, so a
    /// selection of it is always drawable. Asking the visible tabs about `.settings` discarded
    /// the selection and drew an ordinary tab — the panel stayed where it was, and the gear that
    /// had just selected Settings read as doing nothing.
    static func resolve(composition: TabComposition, selected: TabRef) -> TabRef {
        if selected == .settings { return .settings }
        let visible = composition.visibleTabs()
        if visible.contains(selected) { return selected }
        return visible.first ?? .vehicle
    }

    /// Whether Settings draws as one tab among the others — the panel's tab bar above it and the
    /// same header navigation as every other tab — rather than filling the panel with a header of
    /// its own.
    ///
    /// It is a tab only once there is a bar to draw and somewhere to go: after sign-in, with a
    /// snapshot in hand, and past the setup pass. Before that Settings is the one surface that can
    /// carry the account form, so it fills the panel. The rule lives here for the same reason
    /// `resolve` does: as a private property on the view, `showsSettings` alone came to mean "only
    /// Settings", the branch below it never ran, and the tab bar every other tab draws silently
    /// stopped rendering on Settings.
    static func settingsDrawsAsTab(authenticated: Bool, hasSnapshot: Bool, setupMode: Bool) -> Bool {
        authenticated && hasSnapshot && !setupMode
    }
}
