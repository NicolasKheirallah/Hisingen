import SwiftUI

extension View {
    /// Suppresses the AppKit focus ring for controls that provide their own
    /// selection affordance.
    func withoutFocusRing() -> some View {
        self.focusable(false).focusEffectDisabled()
    }
}
