import SwiftUI

/// A selectable chip's resting fill, one step louder under the pointer.
///
/// Selection stays the call site's business (the accent wash, the sliding capsule), so
/// this draws only the unselected state: `resting` while idle, ``HisingenTheme/chipHoverFill``
/// while the pointer is over it, crossfading on ``Motion/interaction``. Under Reduce Motion
/// the change still crossfades, via `hisAnimation`, because an opacity lift is a notice,
/// not movement.
struct HoverChipFill<S: Shape>: View {
    let shape: S
    /// The chip's resting opacity. Chips sit at 4–6 % today; pass what the site already drew.
    var resting: Double = 0.05

    @State private var hovered = false

    var body: some View {
        shape
            .fill(Color.primary.opacity(hovered ? HisingenTheme.chipHoverFill : resting))
            .hisAnimation(Motion.interaction, value: hovered)
            .onHover { hovered = $0 }
    }
}
