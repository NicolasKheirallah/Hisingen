import Observation
import SwiftUI

/// Per-frame drag and scroll state for the panel's pull-to-refresh and tab swipe.
///
/// Held by ``HisingenContentView`` through `@State`, but kept out of the shell's own stored
/// properties: scroll geometry and the drag coordinator write these values every frame, and as
/// `@State` on the shell each write re-ran the whole panel body. Observation only re-evaluates
/// the views that read a property, so the readers are the two small views below.
@MainActor
@Observable
final class PanelGestureState {
    /// Distance from the scroll content's top; `<= 0.5` means the reader is at the top and a
    /// downward drag is a pull-to-refresh rather than a scroll.
    var scrollOffsetFromTop: CGFloat = 0
    /// Rubber-banded pull distance feeding ``PullToRefreshOverlay``.
    var pullDistance: CGFloat = 0
    /// Whether the current pull has crossed the commit threshold. The arm tick fires on the
    /// crossing and re-arms only below a hysteresis band, so a pull hovering at the line
    /// cannot stutter the haptic.
    var pullArmed = false
    /// Horizontal translation while a tab swipe is in progress; `nil` when the active gesture
    /// is not a swipe. Release animates the value back to `nil` rather than clearing it, so
    /// the page settles from wherever the drag left it.
    var swipeTranslation: CGFloat?
    /// The axis the active drag committed to, latched on the first dominant movement so a
    /// wobbly diagonal cannot flip between pull and swipe mid-gesture.
    var dragAxis: Axis?

    func pullDistanceAtRelease(translation: CGFloat) -> CGFloat {
        guard scrollOffsetFromTop <= 0.5, translation > 0 else { return 0 }
        return InstrumentMath.rubberBandDisplacement(overshoot: translation, dimension: 300)
    }

    func acceptsPull(translation: CGFloat) -> Bool {
        guard scrollOffsetFromTop <= 0.5, translation > 0 else {
            pullDistance = 0
            pullArmed = false
            return false
        }
        return true
    }
}

/// Carries the tab-swipe drag offset for the shared scroller. Reads only `swipeTranslation`,
/// so a drag repaints this wrapper and not the panel.
struct PanelSwipeOffset<Content: View>: View {
    let gesture: PanelGestureState
    @ViewBuilder let content: Content

    var body: some View {
        // A swipe drags the page with the pointer (at a dampened ratio so it tracks without
        // pretending to be a full page), released into the flick spring that carries the real
        // velocity.
        content
            .offset(x: gesture.swipeTranslation.map { $0 * 0.22 } ?? 0)
    }
}

/// The pull-to-refresh indicator. Reads only `pullDistance`, so a pull repaints this view.
struct PanelPullReadout: View {
    let gesture: PanelGestureState
    let threshold: CGFloat

    var body: some View {
        PullToRefreshOverlay(pullDistance: gesture.pullDistance, threshold: threshold)
    }
}
